#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# test_schema_scope.sh -- replication scope: extension schemas and pg_partman.
#
# Exercises the rules that decide which relations the migrator replicates, using
# a real pg_partman install as the fixture. Asserts:
#
#   1. The exclusion query in scripts/mk-bucardo-repl.sh and the scope predicate
#      in status-server/server.rb are exact complements. Both are read out of
#      the real files, so this fails if either drifts.
#   2. The exclusion query names every pg_partman table and nothing else.
#   3. The primary-key preflight sees a keyless table in a custom schema, and
#      does NOT flag pg_partman's keyless template tables.
#   4. The schema copy succeeds against a target that already has pg_partman.
#   5. Switch Traffic's REVOKE covers every app schema and skips partman.
#
# Usage:
#   bash tests/test_schema_scope.sh "<SOURCE_URL>" "<TARGET_URL>"
#
# Both URLs must be superusers. pg_partman must be installable on both.
# WARNING: clears both databases. Use throwaway databases.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SCRIPT="$PROJECT_DIR/scripts/mk-bucardo-repl.sh"
SERVER_RB="$PROJECT_DIR/status-server/server.rb"
PARTMAN_SCRIPT="$PROJECT_DIR/scripts/recreate-partman-config.sh"

SRC="${1:-${SOURCE_URL:-}}"
TGT="${2:-${TARGET_URL:-}}"
if [ -z "$SRC" ] || [ -z "$TGT" ]; then
  echo "Usage: bash tests/test_schema_scope.sh \"<SOURCE_URL>\" \"<TARGET_URL>\"" >&2
  exit 2
fi

# The role the migrator would connect as: owns the app schemas, owns nothing of pg_partman's. 
APP_ROLE="scope_app_role"
APP_PASS="scope_app_pass"

PASS=0; FAIL=0
log()  { printf "\033[1;34m[SCOPE]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }

# Same connection, but as APP_ROLE
as_app() { # url -> url with the app role's credentials swapped in
  python3 - "$1" "$APP_ROLE" "$APP_PASS" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
host = p.hostname or "localhost"
port = f":{p.port}" if p.port else ""
print(u.urlunsplit((p.scheme, f"{sys.argv[2]}:{sys.argv[3]}@{host}{port}", p.path, p.query, p.fragment)))
PY
}

clear_db() { # url
  psql "$1" -X -v ON_ERROR_STOP=1 -c "DO \$\$
  DECLARE r record;
  BEGIN
    FOR r IN SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname NOT IN ('information_schema','public','pscale_extensions') LOOP
      EXECUTE format('DROP SCHEMA %I CASCADE', r.nspname);
    END LOOP;
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', r.tablename); END LOOP;
  END \$\$;" >/dev/null 2>&1
  psql "$1" -X -c "DROP EXTENSION IF EXISTS pg_partman CASCADE" >/dev/null 2>&1
}

log "Checking pg_partman availability..."
HAVE=$(psql "$SRC" -X -A -t -c "SELECT count(*) FROM pg_available_extensions WHERE name='pg_partman'" 2>/dev/null | tr -d '[:space:]')
if [ "${HAVE:-0}" != "1" ]; then
  echo "SKIP: pg_partman is not available on the source. Install postgresql-<v>-partman." >&2
  exit 0
fi

log "Clearing both databases..."
clear_db "$SRC"; clear_db "$TGT"

log "Seeding the source: pg_partman in its own schema, app tables elsewhere..."
psql "$SRC" -X -v ON_ERROR_STOP=1 >/dev/null <<SQL
DROP ROLE IF EXISTS $APP_ROLE;
CREATE ROLE $APP_ROLE LOGIN PASSWORD '$APP_PASS';
GRANT CREATE, CONNECT ON DATABASE $(psql "$SRC" -X -A -t -c "SELECT current_database()" | tr -d '[:space:]') TO $APP_ROLE;
ALTER SCHEMA public OWNER TO $APP_ROLE;

CREATE SCHEMA partman;
CREATE EXTENSION pg_partman SCHEMA partman;
-- pg_partman's own documented grants: no TRIGGER, which is what breaks Bucardo.
GRANT USAGE, CREATE ON SCHEMA partman TO $APP_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA partman TO $APP_ROLE;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA partman TO $APP_ROLE;

CREATE SCHEMA analytics AUTHORIZATION $APP_ROLE;

SET ROLE $APP_ROLE;
CREATE TABLE public.accounts (id bigserial PRIMARY KEY, name text);
CREATE TABLE public.events (
  id bigserial, occurred_at timestamptz NOT NULL, kind text,
  PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);
CREATE INDEX events_kind_idx ON public.events (kind);
CREATE TABLE analytics.rollup (id bigserial PRIMARY KEY, day date);
-- Outside public: invisible to a public-only index deferral.
CREATE INDEX rollup_day_idx ON analytics.rollup (day);
-- Keyless, and outside public: invisible to a public-only preflight.
CREATE TABLE analytics.clickstream (session_id text, url text);
-- A view in a replicated schema: REVOKE ON ALL TABLES would target it too.
CREATE VIEW public.accounts_view AS SELECT id, name FROM public.accounts;
RESET ROLE;
SQL

psql "$SRC" -X -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
SET ROLE $APP_ROLE;
CREATE TABLE public.ledger (
  id bigserial, entry_no bigint NOT NULL, PRIMARY KEY (id, entry_no)
) PARTITION BY RANGE (entry_no);
-- Partitions starting well before now()/zero: without a pinned
-- p_start_partition the replay aligns to now() and collides with the children
-- pg_dump already created.
SELECT partman.create_parent(
  p_parent_table := 'public.events', p_control := 'occurred_at',
  p_interval := '1 day', p_premake := 2,
  p_start_partition := (now() - interval '15 days')::text
);
SELECT partman.create_parent(
  p_parent_table := 'public.ledger', p_control := 'entry_no',
  p_interval := '1000', p_type := 'range', p_premake := 2,
  p_start_partition := '1000000'
);
SQL
APP_URL="$(as_app "$SRC")"

# --- 1. the two predicates must be exact complements -------------------------
log "Extracting both predicates from the real source files..."
EXCLUDE_SQL=$(python3 - "$SETUP_SCRIPT" <<'PY'
import re, sys, io
s = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'NOT_REPLICATABLE=\$\(psql "\$PRIMARY" -A -t -c "\n(.*?)"\)', s, re.S)
if not m:
    sys.exit("could not find the NOT_REPLICATABLE query in mk-bucardo-repl.sh")
q = m.group(1).strip()
# PM_TEMPLATE_FILTER is built at runtime from the resolved pg_partman schema;
# this fixture installs it as "partman".
t = re.search(r'PM_TEMPLATE_FILTER="(OR .*?)"\nfi', s, re.S)
if not t:
    sys.exit("could not find PM_TEMPLATE_FILTER in mk-bucardo-repl.sh")
print(q.replace("${PM_TEMPLATE_FILTER}", t.group(1).replace("${PM_SCHEMA}", "partman")))
PY
)
if [ -z "$EXCLUDE_SQL" ]; then fail "extract exclusion query"; else pass "extracted exclusion query from mk-bucardo-repl.sh"; fi

INCLUDE_SQL=$(ruby - "$SERVER_RB" <<'RUBYSCRIPT'
src = File.read(ARGV[0])
HEROKU_URL = ""
block = src[/^MIGRATED_SCHEMA_SCOPE_SQL = .*?^end$/m] or abort "MIGRATED_SCHEMA_SCOPE_SQL not found in server.rb"
eval(block)
puts "SELECT n.nspname || '.' || c.relname FROM pg_class c " \
     "JOIN pg_namespace n ON n.oid = c.relnamespace " \
     "WHERE #{MIGRATED_RELATION_SCOPE_SQL.gsub("\n", " ")} AND c.relkind = 'r' ORDER BY 1"
RUBYSCRIPT
)
if [ -z "$INCLUDE_SQL" ]; then fail "extract scope predicate"; else pass "extracted scope predicate from server.rb"; fi

ALL=$(psql "$APP_URL" -X -A -t -c "
  SELECT n.nspname || '.' || c.relname FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r'
    AND n.nspname NOT IN ('pg_catalog','information_schema','bucardo','_ps_migrator','pscale_extensions')
    AND left(n.nspname, 3) <> 'pg_' ORDER BY 1" | sed '/^$/d' | sort)
EXCLUDED=$(psql "$APP_URL" -X -A -t -c "$EXCLUDE_SQL" | sed '/^$/d' | sort)
INCLUDED=$(psql "$APP_URL" -X -A -t -c "$INCLUDE_SQL" | sed '/^$/d' | sort)

assert_eq "included + excluded partition every user table" \
  "$(echo "$ALL" | md5sum 2>/dev/null || echo "$ALL" | md5)" \
  "$(printf '%s\n%s\n' "$INCLUDED" "$EXCLUDED" | sed '/^$/d' | sort | md5sum 2>/dev/null || printf '%s\n%s\n' "$INCLUDED" "$EXCLUDED" | sed '/^$/d' | sort | md5)"
assert_eq "no relation is both included and excluded" "" "$(comm -12 <(echo "$INCLUDED") <(echo "$EXCLUDED"))"

# --- 2. the exclusion list is exactly pg_partman's tables --------------------
assert_eq "exclusion list is exactly pg_partman's own tables" \
  "partman.part_config
partman.part_config_sub
partman.template_public_events
partman.template_public_ledger" "$EXCLUDED"
assert_eq "app tables in a custom schema stay in scope" "analytics.rollup" \
  "$(echo "$INCLUDED" | grep '^analytics\.rollup$')"

# --- 3. primary-key preflight scope -----------------------------------------
PK_SQL=$(ruby - "$SERVER_RB" <<'RUBYSCRIPT'
src = File.read(ARGV[0])
HEROKU_URL = ""
eval(src[/^MIGRATED_SCHEMA_SCOPE_SQL = .*?^end$/m])
puts "SELECT n.nspname || '.' || c.relname FROM pg_class c " \
     "JOIN pg_namespace n ON n.oid = c.relnamespace " \
     "WHERE #{MIGRATED_RELATION_SCOPE_SQL.gsub("\n", " ")} AND c.relkind = 'r' " \
     "AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid " \
     "AND (i.indisprimary OR i.indisunique)) ORDER BY 1"
RUBYSCRIPT
)
NOPK=$(psql "$APP_URL" -X -A -t -c "$PK_SQL" | sed '/^$/d' | sort)
assert_eq "preflight flags the keyless table outside public" "analytics.clickstream" "$NOPK"
assert_eq "preflight does not flag pg_partman's keyless templates" "" "$(echo "$NOPK" | grep 'template_' || true)"

# --- 4. schema copy against a target that already has pg_partman ------------
log "Pre-installing pg_partman on the target, then running the schema copy..."
psql "$TGT" -X -v ON_ERROR_STOP=1 -c "CREATE SCHEMA partman; CREATE EXTENSION pg_partman SCHEMA partman;" >/dev/null 2>&1
SED_EXPR=$(python3 - "$SETUP_SCRIPT" <<'PY'
import re, sys, io
s = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^\s*sed -E "(s/\^CREATE SCHEMA.*?)" \|$', s, re.M)
if not m:
    sys.exit("could not find the CREATE SCHEMA sed in mk-bucardo-repl.sh")
print(m.group(1).replace('\\1', '\\1'))
PY
)
if [ -z "$SED_EXPR" ]; then fail "extract CREATE SCHEMA sed"; else pass "extracted CREATE SCHEMA sed from mk-bucardo-repl.sh"; fi

COPY_ERR=$(pg_dump --no-owner --no-privileges --no-publications --no-subscriptions \
             --schema-only "$SRC" 2>/dev/null |
           sed -E "$SED_EXPR" |
           grep -v -E "^COMMENT ON EXTENSION " |
           psql "$TGT" -X -v ON_ERROR_STOP=1 -q 2>&1)
COPY_RC=$?
assert_eq "schema copy succeeds when the target already has the extension's schema" "0" "$COPY_RC"
assert_eq "schema copy reports no errors" "" "$(echo "$COPY_ERR" | grep -i '^ERROR' || true)"
assert_eq "app tables landed on the target" "analytics.rollup" \
  "$(psql "$TGT" -X -A -t -c "SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='analytics' AND c.relname='rollup'" | tr -d '[:space:]')"

# --- 4b. the schema copy must not carry the migrator's own schemas ----------
log "Checking schema-copy exclusions..."
for sch in bucardo _ps_migrator pscale_extensions; do
  if grep -q -- "--exclude-schema=$sch" "$SETUP_SCRIPT"; then
    pass "schema copy excludes $sch"
  else
    fail "schema copy does NOT exclude $sch"
  fi
done
# --exclude-schema alone leaves Bucardo's triggers on app tables behind.
if grep -q 'EXCLUDE_PATTERN="[^"]*CREATE TRIGGER bucardo_' "$SETUP_SCRIPT"; then
  pass "schema copy filters Bucardo's triggers on application tables"
else
  fail "schema copy does NOT filter CREATE TRIGGER bucardo_*"
fi
assert_eq "no bucardo schema landed on the target" "0" \
  "$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_namespace WHERE nspname='bucardo'" | tr -d '[:space:]')"
assert_eq "no Bucardo triggers landed on the target" "0" \
  "$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'bucardo%'" | tr -d '[:space:]')"
assert_eq "the extension's own schema IS copied (needed for types/templates)" "1" \
  "$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_namespace WHERE nspname='partman'" | tr -d '[:space:]')"

# --- 4c. pg_partman config is recreated on the target, with a pinned start ---
log "Checking pg_partman config recreation..."
PM_SQL=$(python3 - "$PARTMAN_SCRIPT" <<'PMEXTRACT'
import re, sys, io
s = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'pm_sql=\$\(psql "\$PRIMARY" -A -t -c "\n(.*?)" 2>(?:&1|/dev/null)\)', s, re.S)
if not m:
    sys.exit("could not find the pg_partman recreation query in recreate-partman-config.sh")
# ${pm} is resolved from pg_extension at runtime; this fixture installs it here.
print(m.group(1).strip().replace("${pm}", "partman"))
PMEXTRACT
)
if [ -z "$PM_SQL" ]; then fail "extract pg_partman recreation query"; else pass "extracted pg_partman recreation query"; fi

GEN_PM=$(psql "$SRC" -X -A -t -c "$PM_SQL")
assert_eq "p_start_partition is pinned for both sets" "2" \
  "$(printf '%s\n' "$GEN_PM" | grep -c 'p_start_partition :=')"
assert_eq "no set is left pinned to NULL" "0" \
  "$(printf '%s\n' "$GEN_PM" | grep -c 'p_start_partition := NULL')"
# The schema copy already created the default partition; replaying with 't'
# makes create_partition try to attach it again and the set goes unregistered.
assert_eq "the replay does not re-attach the default partition" "0" \
  "$(printf '%s\n' "$GEN_PM" | grep -c "p_default_table := 't'")"

# Applied the way the script applies it: no ON_ERROR_STOP, so one bad set
# cannot abort the run.
printf '%s\n' "$GEN_PM" | psql "$TGT" -X -q >/dev/null 2>&1
assert_eq "both partition sets are registered on the target" "public.events
public.ledger" "$(psql "$TGT" -X -A -t -c "SELECT parent_table FROM partman.part_config ORDER BY 1" | sed '/^$/d')"
MAINT=$(psql "$TGT" -X -A -t -c "CALL partman.run_maintenance_proc();" 2>&1 | tail -1)
case "$MAINT" in
  *ERROR*) fail "partman maintenance on the target: $MAINT" ;;
  *) pass "partman maintenance runs on the target" ;;
esac

# --- 4d. index deferral must cover partitioned tables and every schema ------
log "Checking partition-aware index deferral..."
CHILD_BEFORE=$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname LIKE 'events_p%kind_idx'" | tr -d '[:space:]')
if [ "${CHILD_BEFORE:-0}" -gt 0 ]; then
  pass "target has $CHILD_BEFORE partition child index(es) to defer"
else
  fail "fixture produced no partition child indexes"
fi

sh "$PROJECT_DIR/scripts/drop-secondary-indexes.sh" --replica "$TGT" >/dev/null 2>&1
DEFERRED=$(psql "$TGT" -X -A -t -c "SELECT schemaname||'.'||objectname FROM _ps_migrator.dropped_indexes WHERE status='pending' ORDER BY 1" | sed '/^$/d' | sort)
assert_eq "the partitioned parent's index is deferred" "public.events_kind_idx" \
  "$(echo "$DEFERRED" | grep '^public\.events_kind_idx$')"
assert_eq "a non-public index is deferred too" "analytics.rollup_day_idx" \
  "$(echo "$DEFERRED" | grep '^analytics\.rollup_day_idx$')"
assert_eq "child indexes are not registered separately" "0" \
  "$(echo "$DEFERRED" | grep -c 'events_p')"
assert_eq "dropping the parent index removed every child's" "0" \
  "$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname LIKE 'events_p%kind_idx'" | tr -d '[:space:]')"
# Replaying "ON ONLY" would leave an invalid, childless index that still shows
# up in pg_indexes, so the recipe must not contain it.
assert_eq "the rebuild recipe has ON ONLY stripped" "0" \
  "$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE rebuild_sql LIKE '% ON ONLY %'" | tr -d '[:space:]')"

# Replay, then confirm the children came back and the parent is valid.
psql "$TGT" -X -A -t -c "SELECT rebuild_sql FROM _ps_migrator.dropped_indexes WHERE pass=1 ORDER BY id" |
  while IFS= read -r sql; do [ -z "$sql" ] && continue; psql "$TGT" -X -q -c "$sql" >/dev/null 2>&1; done
assert_eq "rebuild restored every child index" "$CHILD_BEFORE" \
  "$(psql "$TGT" -X -A -t -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname LIKE 'events_p%kind_idx'" | tr -d '[:space:]')"
assert_eq "the rebuilt partitioned index is valid" "t" \
  "$(psql "$TGT" -X -A -t -c "SELECT i.indisvalid FROM pg_index i JOIN pg_class ic ON ic.oid=i.indexrelid WHERE ic.relname='events_kind_idx'" | tr -d '[:space:]')"
# A partitioned parent stores nothing itself, so the old sizing reported 0 and
# scheduled the largest rebuild last.
assert_eq "the partitioned parent is sized by its whole tree" "1" \
  "$(psql "$TGT" -X -A -t -c "SELECT CASE WHEN GREATEST(pg_total_relation_size('public.events'::regclass), (SELECT coalesce(sum(pg_total_relation_size(t.relid)),0) FROM pg_partition_tree('public.events'::regclass) t)) > pg_total_relation_size('public.events'::regclass) THEN 1 ELSE 0 END" | tr -d '[:space:]')"

# --- 4e. Bucardo's connections must neutralise transaction_timeout ----------
log "Checking transaction_timeout override..."
for db in planetscale heroku; do
  if grep -q "bucardo update database $db dbconn=" "$SETUP_SCRIPT"; then
    pass "$db connection sets dbconn"
  else
    fail "$db connection does NOT set dbconn (transaction_timeout would kill the copy)"
  fi
done

if grep -q "dbconn='options=-c " "$SETUP_SCRIPT"; then
  fail "dbconn uses a value containing a space; Bucardo's CLI will truncate it"
else
  pass "dbconn value is space-free"
fi
assert_eq "dbconn disables transaction_timeout" "2" \
  "$(grep -c "dbconn='options=--transaction_timeout=0'" "$SETUP_SCRIPT")"

# --- 4f. edge-case fixes -----------------------------------------------------
log "Checking edge-case fixes..."
if grep -q "recreate_pg_partman_config" "$SETUP_SCRIPT"; then
  fail "partman replay still runs inside mk-bucardo-repl.sh (before the copy)"
else
  pass "partman replay no longer runs during setup"
fi
assert_eq "partman replay lives in its own script" "1" \
  "$([ -f "$PARTMAN_SCRIPT" ] && echo 1 || echo 0)"
assert_eq "server.rb invokes the replay after the copy" "2" \
  "$(grep -c '^ *recreate_partman_config$' "$SERVER_RB")"
if ruby -e 'b=File.read(ARGV[0])[/mount_proc "\/reset".*?^end$/m]; exit(b.include?("run_bucardo_teardown") ? 0 : 1)' "$SERVER_RB"; then
  pass "/reset tears down Bucardo"
else
  fail "/reset does NOT tear down Bucardo"
fi
if ruby -e 'b=File.read(ARGV[0])[/mount_proc "\/reset".*?^end$/m]; exit(b.include?("start_new_rebuild_log") ? 0 : 1)' "$SERVER_RB"; then
  pass "/reset starts a new rebuild log"
else
  fail "/reset does NOT start a new rebuild log"
fi
if ruby -e 'b=File.read(ARGV[0])[/mount_proc "\/start-migration".*?^end$/m]; exit(b.include?("start_new_rebuild_log") ? 0 : 1)' "$SERVER_RB"; then
  pass "/start-migration starts a new rebuild log"
else
  fail "/start-migration does NOT start a new rebuild log"
fi
assert_eq "rebuild log name is timestamped" "1" \
  "$(grep -c 'index-rebuild-' "$SERVER_RB" | head -1)"

# --- 5. Switch Traffic REVOKE covers every app schema ------------------------
log "Checking the generated REVOKE statements..."
REVOKES=$(ruby - "$SERVER_RB" "$APP_URL" "$APP_ROLE" <<'RUBYSCRIPT' | sed 's/ | psql .*//'
src = File.read(ARGV[0])
HEROKU_URL = ARGV[1]
eval(src[/^MIGRATED_SCHEMA_SCOPE_SQL = .*?^end$/m])
print relation_privilege_cmd("REVOKE INSERT, UPDATE, DELETE ON %I.%I FROM %I;", ARGV[2])
RUBYSCRIPT
)
GENERATED=$(eval "$REVOKES" | sed '/^$/d' | sed 's/^ *//' | sort)
assert_eq "REVOKE covers a table in public" "1" \
  "$(echo "$GENERATED" | grep -c 'ON public\.accounts FROM')"
assert_eq "REVOKE covers a table in the custom schema" "1" \
  "$(echo "$GENERATED" | grep -c 'ON analytics\.rollup FROM')"
assert_eq "REVOKE covers the partitioned parent" "1" \
  "$(echo "$GENERATED" | grep -c 'ON public\.events FROM')"
assert_eq "no REVOKE for the extension's own schema" "0" \
  "$(echo "$GENERATED" | grep -c partman)"
assert_eq "no REVOKE targets a view" "0" \
  "$(echo "$GENERATED" | grep -c accounts_view)"
if ruby -e 'src=File.read(ARGV[0]); exit(src[/def relation_privilege_cmd.*?^end$/m].include?("-1") ? 0 : 1)' "$SERVER_RB"; then
  pass "privilege changes are applied in a single transaction"
else
  fail "privilege changes are NOT atomic (psql -1 missing)"
fi

echo "$GENERATED" | psql "$SRC" -X -v ON_ERROR_STOP=1 -q >/dev/null 2>&1
for t in public.accounts analytics.rollup analytics.clickstream; do
  OUT=$(psql "$APP_URL" -X -c "INSERT INTO $t DEFAULT VALUES" 2>&1)
  case "$OUT" in
    *"permission denied"*) pass "writes blocked on $t" ;;
    *) fail "writes NOT blocked on $t -- got: $(echo "$OUT" | head -1)" ;;
  esac
done

log "Cleaning up..."
clear_db "$SRC"; clear_db "$TGT"
psql "$SRC" -X -c "DROP ROLE IF EXISTS $APP_ROLE" >/dev/null 2>&1

echo ""
echo "========================================"
printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ]
