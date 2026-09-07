#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# test_index_deferral.sh -- deferred index rebuild.
#
# Exercises scripts/drop-secondary-indexes.sh and the rebuild contract against
# any plain PostgreSQL database. Asserts that:
#   - only secondary and unique indexes are dropped; primary keys are kept
#   - foreign keys depending on a dropped unique are recorded and dropped first
#   - drops never CASCADE, and every drop has a recorded rebuild recipe
#   - replaying the registry restores an identical set of indexes and constraints
#   - the drop step is idempotent
#   - one failing index does not stop the others
#
# Usage:
#   bash tests/test_index_deferral.sh "postgresql://user:pass@host:port/dbname"
#   TARGET_URL=... bash tests/test_index_deferral.sh
#
# WARNING: operates on the 'public' schema of the given database. Use a
# throwaway database.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DROP_SCRIPT="$PROJECT_DIR/scripts/drop-secondary-indexes.sh"

URL="${1:-${TARGET_URL:-}}"
if [ -z "$URL" ]; then
  echo "Usage: bash tests/test_index_deferral.sh \"postgresql://...target...\"" >&2
  exit 2
fi

PASS=0
FAIL=0
log()  { printf "\033[1;34m[IDX]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }

# Run SQL against the target, tuples-only, unaligned. Returns trimmed output.
q() { psql "$URL" -X -A -t -c "$1" 2>/dev/null; }
# Run SQL and surface errors (for assertions that expect failure/success).
qe() { psql "$URL" -X -v ON_ERROR_STOP=1 -c "$1" 2>&1; }

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1 (= $2)"; else fail "$1 -- expected [$2], got [$3]"; fi
}
assert_contains_index() { # indexname (should exist)
  local n; n=$(q "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='$1'")
  if [ "$n" = "1" ]; then pass "index $1 present"; else fail "index $1 MISSING (expected present)"; fi
}
assert_no_index() { # indexname (should be gone)
  local n; n=$(q "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='$1'")
  if [ "$n" = "0" ]; then pass "index $1 dropped"; else fail "index $1 STILL PRESENT (expected dropped)"; fi
}
assert_no_constraint() { # conname
  local n; n=$(q "SELECT count(*) FROM pg_constraint WHERE conname='$1' AND connamespace='public'::regnamespace")
  if [ "$n" = "0" ]; then pass "constraint $1 dropped"; else fail "constraint $1 STILL PRESENT"; fi
}
assert_has_constraint() { # conname
  local n; n=$(q "SELECT count(*) FROM pg_constraint WHERE conname='$1' AND connamespace='public'::regnamespace")
  if [ "$n" = "1" ]; then pass "constraint $1 present"; else fail "constraint $1 MISSING"; fi
}

# Canonical, order-stable snapshot of all public indexes + constraints.
snapshot() {
  q "SELECT 'IDX '||indexname||' :: '||indexdef FROM pg_indexes WHERE schemaname='public'
     UNION ALL
     SELECT 'CON '||conname||' :: '||pg_get_constraintdef(oid) FROM pg_constraint WHERE connamespace='public'::regnamespace
     ORDER BY 1"
}

reset_schema() {
  qe "DROP SCHEMA IF EXISTS _ps_migrator CASCADE;
      DROP TABLE IF EXISTS child CASCADE;
      DROP TABLE IF EXISTS parent CASCADE;" >/dev/null
}

seed_schema() {
  qe "
    CREATE TABLE parent (
      id    int PRIMARY KEY,
      email text NOT NULL,
      code  text NOT NULL,
      name  text
    );
    ALTER TABLE parent ADD CONSTRAINT parent_email_key UNIQUE (email);   -- unique constraint (FK target)
    CREATE UNIQUE INDEX parent_code_uidx ON parent (code);               -- standalone unique index
    CREATE INDEX parent_name_idx ON parent (name);                       -- secondary
    CREATE INDEX parent_name_lower_idx ON parent (lower(name));          -- expression index

    CREATE TABLE child (
      id           int PRIMARY KEY,
      parent_email text,
      note         text
    );
    ALTER TABLE child ADD CONSTRAINT child_parent_fk
      FOREIGN KEY (parent_email) REFERENCES parent (email);              -- FK -> parent unique
    CREATE INDEX child_note_idx ON child (note);                         -- secondary

    INSERT INTO parent (id, email, code, name) VALUES
      (1,'a@x.com','C1','Alice'), (2,'b@x.com','C2','Bob'), (3,'c@x.com','C3','Carol');
    INSERT INTO child (id, parent_email, note) VALUES
      (1,'a@x.com','n1'), (2,'b@x.com','n2');
  " >/dev/null
}

# Simulate the server.rb orchestrator: replay rebuild_sql per pass, mark each
# row done/failed, never abort on a single failure.
run_rebuild() {
  for pass in 1 2; do
    local ids; ids=$(q "SELECT id FROM _ps_migrator.dropped_indexes WHERE pass=$pass AND status IN ('pending','failed') ORDER BY id")
    for id in $ids; do
      [ -z "$id" ] && continue
      local sql; sql=$(q "SELECT rebuild_sql FROM _ps_migrator.dropped_indexes WHERE id=$id")
      local tmp; tmp=$(mktemp)
      printf '%s;\n' "$sql" > "$tmp"
      if psql "$URL" -X -v ON_ERROR_STOP=1 -f "$tmp" >/dev/null 2>&1; then
        q "UPDATE _ps_migrator.dropped_indexes SET status='done', finished_at=now(), error=NULL WHERE id=$id" >/dev/null
      else
        q "UPDATE _ps_migrator.dropped_indexes SET status='failed', finished_at=now() WHERE id=$id" >/dev/null
      fi
      rm -f "$tmp"
    done
  done
}

# === TEST 1: drop + rebuild round-trip ======================================
log "Connecting to target: ${URL%%\?*}"
if ! q "SELECT 1" | grep -q 1; then echo "Cannot connect to target DB" >&2; exit 1; fi

log "TEST 1: drop + rebuild restores an identical schema"
reset_schema
seed_schema
BEFORE="$(snapshot)"

sh "$DROP_SCRIPT" --replica "$URL" >/tmp/idx_drop.log 2>&1 || { fail "drop script exited non-zero"; cat /tmp/idx_drop.log; }

# --- after drop ---
assert_contains_index "parent_pkey"          # PK kept
assert_contains_index "child_pkey"           # PK kept
assert_no_index "parent_name_idx"            # secondary dropped
assert_no_index "parent_name_lower_idx"      # expression secondary dropped
assert_no_index "child_note_idx"             # secondary dropped
assert_no_index "parent_code_uidx"           # standalone unique dropped
assert_no_constraint "parent_email_key"      # unique constraint dropped
assert_no_constraint "child_parent_fk"       # dependent FK dropped first

reg_total=$(q "SELECT count(*) FROM _ps_migrator.dropped_indexes")
reg_fk=$(q "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE kind='fkey' AND pass=2")
reg_unique=$(q "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE kind='unique'")
reg_index=$(q "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE kind='index'")
assert_eq "registry total rows" "6" "$reg_total"          # 3 secondary + 2 unique + 1 fk
assert_eq "registry FK rows (pass 2)" "1" "$reg_fk"
assert_eq "registry unique rows" "2" "$reg_unique"
assert_eq "registry secondary index rows" "3" "$reg_index"

# verify no CASCADE in the script
if grep -qi "cascade" "$DROP_SCRIPT"; then
  # the only allowed mention is in comments; ensure no DROP ... CASCADE statement
  if grep -iE "drop[^;]*cascade" "$DROP_SCRIPT" | grep -vq "^[[:space:]]*#"; then
    fail "drop script contains a DROP ... CASCADE statement"
  else
    pass "no DROP ... CASCADE statements (RESTRICT only)"
  fi
else
  pass "no CASCADE anywhere in drop script"
fi

# --- rebuild ---
run_rebuild
AFTER="$(snapshot)"

if [ "$BEFORE" = "$AFTER" ]; then
  pass "post-rebuild schema is byte-identical to original"
else
  fail "schema differs after rebuild:"; diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") || true
fi

done_rows=$(q "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE status='done'")
assert_eq "all registry rows rebuilt (done)" "6" "$done_rows"

# constraints actually enforced again
assert_has_constraint "parent_email_key"
assert_has_constraint "child_parent_fk"
dup=$(qe "INSERT INTO parent (id,email,code,name) VALUES (9,'a@x.com','C9','dup')" 2>&1 || true)
echo "$dup" | grep -qi "duplicate key\|unique" && pass "unique constraint enforced after rebuild" || fail "unique not enforced: $dup"
bad_fk=$(qe "INSERT INTO child (id,parent_email,note) VALUES (9,'nope@x.com','x')" 2>&1 || true)
echo "$bad_fk" | grep -qi "foreign key\|violates" && pass "FK enforced after rebuild" || fail "FK not enforced: $bad_fk"

# === TEST 2: idempotent drop ================================================
log "TEST 2: re-running the drop script is a no-op (registry already populated)"
idx_before_redrop=$(q "SELECT count(*) FROM pg_indexes WHERE schemaname='public'")
sh "$DROP_SCRIPT" --replica "$URL" >/tmp/idx_drop2.log 2>&1 || true
idx_after_redrop=$(q "SELECT count(*) FROM pg_indexes WHERE schemaname='public'")
assert_eq "indexes unchanged after re-running drop script" "$idx_before_redrop" "$idx_after_redrop"
if grep -qi "already populated" /tmp/idx_drop2.log; then pass "drop script reported registry already populated"; else fail "drop script did not detect populated registry"; fi

# === TEST 3: fault tolerance (one bad index does not stop the rest) =========
log "TEST 3: a single failing rebuild does not block the others"
reset_schema
seed_schema
sh "$DROP_SCRIPT" --replica "$URL" >/tmp/idx_drop3.log 2>&1 || true
# Corrupt one secondary index's rebuild recipe so it will fail.
q "UPDATE _ps_migrator.dropped_indexes SET rebuild_sql='CREATE INDEX parent_name_idx ON parent (no_such_column)' WHERE objectname='parent_name_idx'" >/dev/null
run_rebuild
failed_rows=$(q "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE status='failed'")
done_rows=$(q "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE status='done'")
assert_eq "exactly one index failed" "1" "$failed_rows"
assert_eq "the other five rebuilt successfully" "5" "$done_rows"
assert_contains_index "child_note_idx"   # an unrelated index still built
assert_has_constraint "child_parent_fk"  # FK still rebuilt despite the failure
assert_no_index "parent_name_idx"        # the failed one is absent (as expected)

# === cleanup ================================================================
reset_schema

echo ""
echo "========================================"
printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ]
