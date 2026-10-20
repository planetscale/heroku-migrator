#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# test_schema_copy_deferral.sh -- source to target, end to end without Bucardo.
#
# Mirrors the real migration flow against two plain PostgreSQL databases: seed
# the source, copy its schema with the same `pg_dump --schema-only | psql` the
# migrator uses, drop the target's secondary and unique indexes, copy the data,
# rebuild from the registry, then assert the target's index and constraint set
# matches the source exactly.
#
# Usage:
#   bash tests/test_schema_copy_deferral.sh "<SOURCE_URL>" "<TARGET_URL>"
#
# WARNING: clears the public schema of BOTH databases. Use throwaway databases.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DROP_SCRIPT="$PROJECT_DIR/scripts/drop-secondary-indexes.sh"

SRC="${1:-${SOURCE_URL:-}}"
TGT="${2:-${TARGET_URL:-}}"
if [ -z "$SRC" ] || [ -z "$TGT" ]; then
  echo "Usage: bash tests/test_schema_copy_deferral.sh \"<SOURCE_URL>\" \"<TARGET_URL>\"" >&2
  exit 2
fi

PASS=0; FAIL=0
log()  { printf "\033[1;34m[E2E-IDX]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1 (= $2)"; else fail "$1 -- expected [$2] got [$3]"; fi; }

clear_db() { # url
  psql "$1" -X -v ON_ERROR_STOP=1 -c "DO \$\$
  DECLARE r record;
  BEGIN
    FOR r IN SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname NOT IN ('information_schema','public','pscale_extensions') LOOP
      EXECUTE format('DROP SCHEMA %I CASCADE', r.nspname);
    END LOOP;
    FOR r IN SELECT viewname FROM pg_views WHERE schemaname='public' LOOP EXECUTE format('DROP VIEW IF EXISTS public.%I CASCADE', r.viewname); END LOOP;
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', r.tablename); END LOOP;
    FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname='public' LOOP EXECUTE format('DROP SEQUENCE IF EXISTS public.%I CASCADE', r.sequencename); END LOOP;
  END \$\$;" >/dev/null 2>&1
}

fingerprint() { # url
  # Indexes + unique/PK/FK/check constraints -- i.e. everything the deferred-index
  # feature manages. NOT NULL constraints (contype='n') are excluded: the feature
  # never touches them, and pg_dump version differences name them inconsistently.
  psql "$1" -X -A -t -c "
    SELECT 'IDX '||indexname||' :: '||indexdef FROM pg_indexes WHERE schemaname='public'
    UNION ALL
    SELECT 'CON '||conname||' :: '||pg_get_constraintdef(oid) FROM pg_constraint
      WHERE connamespace='public'::regnamespace AND contype <> 'n'
    ORDER BY 1" 2>/dev/null
}

copy_table() { # table
  psql "$SRC" -X -c "\\copy public.$1 TO STDOUT" 2>/dev/null | psql "$TGT" -X -v ON_ERROR_STOP=1 -c "\\copy public.$1 FROM STDIN" >/dev/null 2>&1
}

log "Clearing both databases..."
clear_db "$SRC"; clear_db "$TGT"

log "Seeding the source with a realistic schema + data..."
psql "$SRC" -X -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE users (
  id       bigint PRIMARY KEY,
  email    text NOT NULL,
  username text NOT NULL,
  status   text NOT NULL DEFAULT 'active',
  created  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE users ADD CONSTRAINT users_email_key UNIQUE (email);   -- unique constraint (FK target)
CREATE UNIQUE INDEX users_username_uidx ON users (username);        -- standalone unique index
CREATE INDEX users_status_idx ON users (status);                    -- secondary
CREATE INDEX users_email_lower_idx ON users (lower(email));         -- expression index
CREATE INDEX users_active_idx ON users (created) WHERE status = 'active';  -- partial index

CREATE TABLE products (
  sku   text PRIMARY KEY,
  name  text NOT NULL,
  price numeric(10,2) NOT NULL
);
CREATE INDEX products_name_idx ON products (name);

CREATE TABLE orders (
  id          bigint PRIMARY KEY,
  user_email  text NOT NULL,
  sku         text NOT NULL,
  qty         int NOT NULL,
  created     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE orders ADD CONSTRAINT orders_user_fk FOREIGN KEY (user_email) REFERENCES users (email);  -- FK -> users unique
ALTER TABLE orders ADD CONSTRAINT orders_sku_fk  FOREIGN KEY (sku) REFERENCES products (sku);        -- FK -> products PK
CREATE INDEX orders_user_email_idx ON orders (user_email);
CREATE INDEX orders_user_created_idx ON orders (user_email, created);   -- multicolumn

INSERT INTO users (id, email, username, status)
SELECT g, 'user'||g||'@x.com', 'user'||g, CASE WHEN g % 3 = 0 THEN 'inactive' ELSE 'active' END
FROM generate_series(1, 500) g;
INSERT INTO products (sku, name, price)
SELECT 'SKU'||g, 'Product '||g, (g % 100) + 0.99 FROM generate_series(1, 100) g;
INSERT INTO orders (id, user_email, sku, qty)
SELECT g, 'user'||((g % 500) + 1)||'@x.com', 'SKU'||((g % 100) + 1), (g % 5) + 1
FROM generate_series(1, 2000) g;
SQL

SRC_FP="$(fingerprint "$SRC")"
log "Source has $(echo "$SRC_FP" | grep -c '^IDX') indexes and $(echo "$SRC_FP" | grep -c '^CON') constraints."

# === schema copy (same flags as scripts/mk-bucardo-repl.sh) =================
# NOTE: if the stand-in source is itself a managed database, its dump may
# contain a `CREATE SCHEMA` for a vendor schema that already exists on the
# target. Filtering it keeps the test usable on any provider. We drop
# ON_ERROR_STOP for the copy (unlike production) so that benign already-exists
# errors do not abort the restore; the fingerprint assertion below still proves
# every public index/constraint landed correctly.
log "Copying schema source -> target (pg_dump --schema-only | psql)..."
pg_dump --no-owner --no-privileges --no-publications --no-subscriptions --schema-only "$SRC" 2>/dev/null \
  | grep -v -E "^COMMENT ON EXTENSION |^CREATE SCHEMA pscale_extensions;" \
  | psql "$TGT" -X >/tmp/e2e_idx_restore.log 2>&1

assert_eq "schema copy reproduces source index+constraint set" "$SRC_FP" "$(fingerprint "$TGT")"

# === drop secondary/unique indexes on the target ===========================
log "Dropping secondary/unique indexes on the target..."
sh "$DROP_SCRIPT" --replica "$TGT" >/tmp/e2e_idx_drop.log 2>&1 || { fail "drop script failed"; cat /tmp/e2e_idx_drop.log; }

pk_kept=$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_index WHERE indisprimary AND indrelid IN ('public.users'::regclass,'public.orders'::regclass,'public.products'::regclass)" 2>/dev/null)
assert_eq "all 3 primary keys kept on target" "3" "$pk_kept"
sec_left=$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname IN ('users_status_idx','users_email_lower_idx','users_active_idx','products_name_idx','orders_user_email_idx','orders_user_created_idx','users_username_uidx')" 2>/dev/null)
assert_eq "all 7 secondary/unique indexes dropped" "0" "$sec_left"
reg_fk=$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE kind='fkey'" 2>/dev/null)
assert_eq "FK depending on dropped unique recorded (orders_user_fk)" "1" "$reg_fk"
# orders_sku_fk references products PK (not dropped) so it must remain untouched
sku_fk=$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_constraint WHERE conname='orders_sku_fk'" 2>/dev/null)
assert_eq "FK to a PRIMARY KEY left untouched (orders_sku_fk)" "1" "$sku_fk"

# === copy data (FK-dependency order) =======================================
log "Copying data source -> target..."
copy_table users
copy_table products
copy_table orders
for t in users products orders; do
  s=$(psql "$SRC" -X -A -t -c "SELECT count(*) FROM public.$t" 2>/dev/null)
  d=$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM public.$t" 2>/dev/null)
  assert_eq "row count matches for $t" "$s" "$d"
done

# === rebuild from the registry (mirrors server.rb orchestrator) ============
log "Rebuilding indexes from the registry..."
for pass in 1 2; do
  ids=$(psql "$TGT" -X -A -t -c "SELECT id FROM _ps_migrator.dropped_indexes WHERE pass=$pass AND status IN ('pending','failed') ORDER BY id" 2>/dev/null)
  for id in $ids; do
    [ -z "$id" ] && continue
    sql=$(psql "$TGT" -X -A -t -c "SELECT rebuild_sql FROM _ps_migrator.dropped_indexes WHERE id=$id" 2>/dev/null)
    tmp=$(mktemp); printf '%s;\n' "$sql" > "$tmp"
    if psql "$TGT" -X -v ON_ERROR_STOP=1 -f "$tmp" >/dev/null 2>&1; then
      psql "$TGT" -X -c "UPDATE _ps_migrator.dropped_indexes SET status='done' WHERE id=$id" >/dev/null 2>&1
    else
      psql "$TGT" -X -c "UPDATE _ps_migrator.dropped_indexes SET status='failed' WHERE id=$id" >/dev/null 2>&1
    fi
    rm -f "$tmp"
  done
done

not_done=$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE status NOT IN ('done','skipped')" 2>/dev/null)
assert_eq "every registry object rebuilt" "0" "$not_done"
assert_eq "FINAL: target schema identical to source" "$SRC_FP" "$(fingerprint "$TGT")"

# integrity actually enforced
dup=$(psql "$TGT" -X -c "INSERT INTO users (id,email,username) VALUES (99999,'user1@x.com','dupe')" 2>&1 || true)
echo "$dup" | grep -qi "duplicate key\|unique" && pass "unique enforced on target after rebuild" || fail "unique NOT enforced: $dup"
badfk=$(psql "$TGT" -X -c "INSERT INTO orders (id,user_email,sku,qty) VALUES (99999,'nobody@x.com','SKU1',1)" 2>&1 || true)
echo "$badfk" | grep -qi "foreign key\|violates" && pass "FK enforced on target after rebuild" || fail "FK NOT enforced: $badfk"

log "Cleaning up both databases..."
clear_db "$SRC"; clear_db "$TGT"

echo ""
echo "========================================"
printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ]
