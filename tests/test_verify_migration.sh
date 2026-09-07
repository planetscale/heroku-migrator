#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# test_verify_migration.sh -- scripts/verify-migration.sh.
#
# Builds source and target pairs with deliberately injected differences and
# asserts what the script reports. The failure mode that matters is a false
# pass: verification that cannot see a problem is worse than none, because it
# is what decides whether a cutover is safe.
#
# Runs against any plain PostgreSQL server.
#
# Usage:
#   bash tests/test_verify_migration.sh "<ADMIN_URL>"
#   ADMIN_URL=postgresql://user:pw@127.0.0.1:5432/postgres bash tests/...
#
# WARNING: drops and recreates databases named vm_src and vm_tgt on that server.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY="$PROJECT_DIR/scripts/verify-migration.sh"

ADMIN="${1:-${ADMIN_URL:-}}"
if [ -z "$ADMIN" ]; then
  echo "Usage: bash tests/test_verify_migration.sh \"<ADMIN_URL>\"" >&2
  exit 2
fi
BASE="${ADMIN%/*}"
SRC_URL="$BASE/vm_src"
TGT_URL="$BASE/vm_tgt"

PASS=0; FAIL=0
log()  { printf "\033[1;34m[VERIFY]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }

adm() { psql "$ADMIN" -X -q -c "$1" >/dev/null 2>&1; }
s()   { psql "$SRC_URL" -X -q -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }
t()   { psql "$TGT_URL" -X -q -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }

OUT=""; RC=0
run_verify() { # optional extra source URL override
  OUT="$(HEROKU_URL="${1:-$SRC_URL}" PLANETSCALE_URL="$TGT_URL" bash "$VERIFY" 2>&1)"
  RC=$?
}
has()    { printf '%s\n' "$OUT" | grep -qi -- "$1"; }
result() { printf '%s\n' "$OUT" | grep -oE 'RESULT: [A-Z ]+' | head -1; }
counts() { printf '%s\n' "$OUT" | grep -oE '(PASSED|WARNINGS|FAILED): +[0-9]+' | tr -s ' ' | tr '\n' ' '; }

reset_dbs() {
  adm "DROP DATABASE IF EXISTS vm_src"; adm "DROP DATABASE IF EXISTS vm_tgt"
  adm "CREATE DATABASE vm_src";        adm "CREATE DATABASE vm_tgt"
}

# A matching pair: same tables, same rows, sequence at the same value.
build_matching() {
  reset_dbs
  for db in s t; do
    $db "CREATE TABLE plain (id bigint PRIMARY KEY, name text)"
    $db "INSERT INTO plain SELECT g,'n'||g FROM generate_series(1,1000) g"
    $db "CREATE TABLE \"MixedCase\" (id bigint PRIMARY KEY, v text)"
    $db "INSERT INTO \"MixedCase\" SELECT g,'x' FROM generate_series(1,500) g"
    $db "CREATE TABLE \"order items\" (id bigint PRIMARY KEY, v text)"
    $db "INSERT INTO \"order items\" SELECT g,'y' FROM generate_series(1,300) g"
    $db "CREATE SEQUENCE order_seq"
    $db "SELECT setval('order_seq', 987654)"
  done
}

echo ""
log "verify-migration.sh under test: $VERIFY"

# === Baseline: a genuinely matching pair must pass cleanly =================
log "Baseline: matching source and target"
build_matching
run_verify
if [ "$RC" -eq 0 ]; then pass "matching pair exits 0"; else fail "matching pair exited $RC ($(result))"; fi
has "ALL CHECKS PASSED" && pass "reports ALL CHECKS PASSED" || fail "did not report ALL CHECKS PASSED: $(result)"
has "FAILED: *0" && pass "zero failures" || fail "unexpected failures: $(counts)"

# === Fix 5: tables whose names need quoting are actually counted ===========
log "Fix 5: quoted/spaced identifiers are counted, not skipped"
has "count timed out" && fail "still reports bogus count timeouts" || pass "no bogus 'count timed out' warnings"
has '"MixedCase" *500 = 500' && pass "mixed-case table counted (500 = 500)" \
  || fail "mixed-case table not counted: $(printf '%s\n' "$OUT" | grep -i mixedcase)"
has '"order items" *300 = 300' && pass "spaced table counted as one table (300 = 300)" \
  || fail "spaced table not counted correctly: $(printf '%s\n' "$OUT" | grep -i 'order')"
# The old word-splitting bug produced a bogus row for the "items" fragment.
printf '%s\n' "$OUT" | grep -qE '^\s+\[(PASS|FAIL|WARN)\]\s+items' \
  && fail "table name still split on whitespace" || pass "no split-name artifact rows"

# Row-count differences in these tables must actually be detected now.
t "DELETE FROM \"order items\" WHERE id <= 7"
run_verify
has "order items.*src=300 tgt=293" && pass "detects a row-count diff in a spaced-name table" \
  || fail "missed row-count diff in spaced-name table"
[ "$RC" -eq 2 ] && pass "row-count diff exits 2" || fail "row-count diff exited $RC"

# === Constraints check actually runs ======================================
# It used to error out on every run ("operator is not unique: text || char"),
# which q() swallowed into a PASS, so it had never detected anything.
log "Constraints: check runs and detects a missing constraint"
build_matching
s "ALTER TABLE plain ADD CONSTRAINT plain_name_uq UNIQUE (name)"
run_verify
has "Constraints missing/changed in target" && pass "detects a constraint missing in target" \
  || fail "missed a missing constraint: $(counts)"
has "plain_name_uq" && pass "names the missing constraint" || fail "did not name the constraint"
[ "$RC" -eq 2 ] && pass "missing constraint exits 2" || fail "missing constraint exited $RC"

build_matching
run_verify
has "All constraints present and matching" && pass "matching constraints still pass" \
  || fail "false positive on matching constraints"

# === Fix 2: sequence values ================================================
log "Fix 2: sequence values compared, not just names"
build_matching
t "SELECT setval('order_seq', 1)"
run_verify
has "Sequences behind the source" && pass "detects target sequence behind source" \
  || fail "missed target sequence behind source: $(counts)"
has "source=987654 target=1" && pass "reports both values" || fail "did not report both values"
[ "$RC" -eq 2 ] && pass "behind sequence exits 2 (FAILED)" || fail "behind sequence exited $RC"

# The realistic case: the target sequence was created but never advanced, so
# last_value is NULL and nextval would restart from 1.
build_matching
adm "DROP DATABASE IF EXISTS vm_tgt"; adm "CREATE DATABASE vm_tgt"
t "CREATE TABLE plain (id bigint PRIMARY KEY, name text)"
t "INSERT INTO plain SELECT g,'n'||g FROM generate_series(1,1000) g"
t "CREATE TABLE \"MixedCase\" (id bigint PRIMARY KEY, v text)"
t "INSERT INTO \"MixedCase\" SELECT g,'x' FROM generate_series(1,500) g"
t "CREATE TABLE \"order items\" (id bigint PRIMARY KEY, v text)"
t "INSERT INTO \"order items\" SELECT g,'y' FROM generate_series(1,300) g"
t "CREATE SEQUENCE order_seq"   # never advanced -> last_value IS NULL
run_verify
has "Sequences behind the source" && pass "detects a never-advanced target sequence" \
  || fail "missed never-advanced target sequence (the 'sequences never synced' case): $(counts)"
[ "$RC" -eq 2 ] && pass "never-advanced target sequence exits 2" || fail "exited $RC"

# Ahead is only a gap, not a correctness problem.
build_matching
t "SELECT setval('order_seq', 999999999)"
run_verify
has "Sequences behind the source" && fail "target ahead wrongly reported as behind" \
  || pass "target sequence ahead of source is accepted"
[ "$RC" -eq 0 ] && pass "sequence ahead still exits 0" || fail "sequence ahead exited $RC: $(counts)"

# A sequence that was never called on the source has nothing to fall behind.
build_matching
s "CREATE SEQUENCE never_used"; t "CREATE SEQUENCE never_used"
run_verify
[ "$RC" -eq 0 ] && pass "never-called sequence does not trip the check" || fail "never-called sequence exited $RC"

# === Fix 1: a source that cannot answer queries must not report success ====
log "Fix 1: query failures abort instead of passing vacuously"
build_matching
# Connects fine, but every statement is cancelled -> previously reported
# "All column definitions match", "All indexes present", etc.
BROKEN="$SRC_URL?options=-c%20statement_timeout%3D1ms"
run_verify "$BROKEN"
[ "$RC" -eq 2 ] && pass "unreadable source exits 2" || fail "unreadable source exited $RC ($(result))"
has "Verification aborted" && pass "says verification was aborted" || fail "no abort message: $(result)"
has "All column definitions match" && fail "STILL claims columns match on an unreadable source" \
  || pass "does not claim columns match"
has "All indexes present" && fail "STILL claims indexes present on an unreadable source" \
  || pass "does not claim indexes present"
has "All constraints present" && fail "STILL claims constraints match on an unreadable source" \
  || pass "does not claim constraints match"
has "ALL CHECKS PASSED" && fail "STILL reports ALL CHECKS PASSED" || pass "does not report success"

# An empty source is not a match either.
log "Fix 1: empty source is not a clean match"
reset_dbs
t "CREATE TABLE only_on_target (id int)"
run_verify
[ "$RC" -eq 2 ] && pass "empty source exits 2" || fail "empty source exited $RC ($(result))"
has "Source has no user tables" && pass "explains the source is empty" || fail "no explanation for empty source"

# === Cleanup ===============================================================
adm "DROP DATABASE IF EXISTS vm_src"; adm "DROP DATABASE IF EXISTS vm_tgt"

echo ""
echo "========================================"
printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ]
