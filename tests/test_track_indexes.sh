#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# test_track_indexes.sh -- scripts/add-track-indexes.sh.
#
# Bucardo indexes its per-table "track" tables on (target text_pattern_ops,
# txntime), but bucardo_delta_check() anti-joins on txntime alone, so that
# index cannot serve it and the check degrades to a sequential scan per delta
# row. add-track-indexes.sh adds the missing (txntime) index before the sync
# starts.
#
# Fabricates the real Bucardo 5.6 table and index shapes, so it runs against
# any plain PostgreSQL database -- no Bucardo and no plperl needed -- then
# asserts coverage, naming, idempotency, fail-closed behaviour and the plan.
#
# Usage:
#   bash tests/test_track_indexes.sh "<SOURCE_URL>"
#   SOURCE_URL=... bash tests/test_track_indexes.sh
#
# WARNING: drops and recreates the "bucardo" schema of the given database, and
# creates and drops public.canary and public.track_decoy. Use a throwaway
# database.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/add-track-indexes.sh"

URL="${1:-${SOURCE_URL:-}}"
if [ -z "$URL" ]; then
  echo "Usage: bash tests/test_track_indexes.sh \"<SOURCE_URL>\"" >&2
  exit 2
fi

PASS=0; FAIL=0
log()  { printf "\033[1;34m[TRACK-IDX]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1 (= $2)"; else fail "$1 -- expected [$2] got [$3]"; fi; }

# Tuples-only, unaligned psql. -X so a developer's ~/.psqlrc cannot skew output.
q()  { psql "$URL" -X -A -t -c "$1" 2>/dev/null; }
qe() { psql "$URL" -X -A -t -v ON_ERROR_STOP=1 -c "$1"; }

LAST_OUT=""; LAST_RC=0
run_script() { # extra args...
  LAST_OUT="$(sh "$SCRIPT" --primary "$URL" "$@" 2>&1)"
  LAST_RC=$?
}

# --- Fixture ----------------------------------------------------------------
# fixture_mk() reproduces exactly what Bucardo's validate_sync() builds on a
# source database, per replicated table:
#   delta_<maker>  + dex1_<maker> (txntime)                  <- already indexed
#   track_<maker>  + dex3_<maker> (target text_pattern_ops, txntime)
#   stage_<maker>
# plus the bucardo_delta_names registry row.
reset_bucardo() {
  qe "
    DROP SCHEMA IF EXISTS bucardo CASCADE;
    CREATE SCHEMA bucardo;

    CREATE TABLE bucardo.bucardo_delta_names (
      sync      text NOT NULL,
      tablename text NOT NULL,
      deltaname text NOT NULL,
      trackname text NOT NULL,
      cdate     timestamptz NOT NULL DEFAULT now()
    );

    CREATE FUNCTION bucardo.fixture_mk(p_schema text, p_table text, p_maker text,
                                       p_sync text DEFAULT 'planetscale_import',
                                       p_with_stage boolean DEFAULT true)
    RETURNS void LANGUAGE plpgsql AS \$fx\$
    DECLARE
      d text := 'delta_' || p_maker;
      t text := 'track_' || p_maker;
      s text := 'stage_' || p_maker;
    BEGIN
      EXECUTE format('CREATE TABLE bucardo.%I (tablename oid NOT NULL,
                        txntime timestamptz NOT NULL DEFAULT now(), rowid text)', d);
      EXECUTE format('CREATE INDEX %I ON bucardo.%I (txntime)', 'dex1_' || p_maker, d);
      EXECUTE format('CREATE TABLE bucardo.%I (txntime timestamptz, target text)', t);
      EXECUTE format('CREATE INDEX %I ON bucardo.%I (target text_pattern_ops, txntime)',
                     'dex3_' || p_maker, t);
      IF p_with_stage THEN
        EXECUTE format('CREATE TABLE bucardo.%I (txntime timestamptz, target text)', s);
      END IF;
      INSERT INTO bucardo.bucardo_delta_names(sync, tablename, deltaname, trackname)
        VALUES (p_sync, format('%I.%I', p_schema, p_table), d, t);
    END \$fx\$;
  " >/dev/null
}

# --- Canonical assertion ----------------------------------------------------
# Track tables with NO usable txntime index. Must always be empty after a run.
# indkey[0] is the leading key column (int2vector, 0-based); an expression
# leading key has attnum 0 and so fails the join, which is correct -- an
# expression index cannot serve the anti-join either.
UNCOVERED_SQL="
  SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'bucardo'
    AND c.relkind IN ('r','p')
    AND left(c.relname, 6) = 'track_'
    AND NOT EXISTS (
      SELECT 1
      FROM pg_index i
      JOIN pg_class ci ON ci.oid = i.indexrelid
      JOIN pg_am    am ON am.oid = ci.relam
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
      WHERE i.indrelid = c.oid
        AND a.attname = 'txntime'
        AND am.amname = 'btree'
        AND i.indisvalid
        AND i.indpred IS NULL
        AND i.indexprs IS NULL
    )
  ORDER BY 1"

uncovered()       { q "$UNCOVERED_SQL" | grep -c . ; }
uncovered_list()  { q "$UNCOVERED_SQL" | tr '\n' ' ' ; }

assert_all_covered() { # label
  local n; n="$(uncovered)"
  if [ "$n" = "0" ]; then
    pass "$1: every track table has a usable txntime index"
  else
    fail "$1: $n track table(s) still uncovered: $(uncovered_list)"
  fi
}

# Names of the txntime-serving indexes across all track tables.
txntime_index_names() {
  q "
  SELECT ci.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_index i ON i.indrelid = c.oid
  JOIN pg_class ci ON ci.oid = i.indexrelid
  JOIN pg_am am ON am.oid = ci.relam
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
  WHERE n.nspname = 'bucardo'
    AND left(c.relname, 6) = 'track_'
    AND a.attname = 'txntime'
    AND am.amname = 'btree'
    AND i.indisvalid
    AND i.indpred IS NULL
    AND i.indexprs IS NULL
  ORDER BY 1"
}

index_count() { q "SELECT count(*) FROM pg_index WHERE indrelid = 'bucardo.$1'::regclass"; }

summary_line() { printf '%s\n' "$LAST_OUT" | grep -o 'add-track-indexes: tables=[0-9]* created=[0-9]* existing=[0-9]*' | tail -1; }

echo ""
log "Target database: $(q "SELECT current_database() || ' @ PG' || current_setting('server_version')")"
log "Script under test: $SCRIPT"
if [ ! -f "$SCRIPT" ]; then
  fail "scripts/add-track-indexes.sh does not exist"
fi
echo ""

# === S1: CLI contract =======================================================
log "S1: CLI contract"

sh "$SCRIPT" >/dev/null 2>&1
[ $? -ne 0 ] && pass "no arguments -> non-zero exit" || fail "no arguments -> should exit non-zero"

out="$(sh "$SCRIPT" 2>&1 >/dev/null)"
echo "$out" | grep -qi "usage" && pass "no arguments -> usage on stderr" || fail "no arguments -> no usage on stderr"

sh "$SCRIPT" --help >/dev/null 2>&1
[ $? -eq 0 ] && pass "--help -> exit 0" || fail "--help -> should exit 0"

# === S2: Happy path =========================================================
log "S2: Happy path (3 tables, one in a non-public source schema)"
reset_bucardo
qe "
  SELECT bucardo.fixture_mk('public','users','public_users');
  SELECT bucardo.fixture_mk('public','orders','public_orders');
  SELECT bucardo.fixture_mk('analytics','page_views','analytics_page_views');
  DROP TABLE IF EXISTS public.track_decoy, public.canary;
  CREATE TABLE public.track_decoy (txntime timestamptz, target text);
  CREATE TABLE public.canary (id int);
" >/dev/null

run_script
assert_eq "exit code" "0" "$LAST_RC"
assert_all_covered "S2"
assert_eq "summary line" "add-track-indexes: tables=3 created=3 existing=0" "$(summary_line)"

assert_eq "track_public_users index count (dex3 + new)" "2" "$(index_count track_public_users)"
assert_eq "delta_public_users untouched (dex1 only)" "1" "$(index_count delta_public_users)"
assert_eq "stage_public_users untouched (no indexes)" "0" "$(index_count stage_public_users)"
assert_eq "dex3_public_users still present" "1" \
  "$(q "SELECT count(*) FROM pg_class WHERE relname='dex3_public_users'")"
assert_eq "non-public-schema track table covered" "1" \
  "$(q "SELECT count(*) FROM pg_index WHERE indrelid='bucardo.track_analytics_page_views'::regclass AND indexrelid <> 'bucardo.dex3_analytics_page_views'::regclass")"
assert_eq "public.track_decoy untouched (bucardo schema only)" "0" \
  "$(q "SELECT count(*) FROM pg_index WHERE indrelid='public.track_decoy'::regclass")"
assert_eq "public.canary survives" "1" \
  "$(q "SELECT count(*) FROM pg_class WHERE relname='canary'")"

# === S3: 63-char truncation collision (top priority) ========================
log "S3: 63-char index-name truncation collision"
reset_bucardo
qe "
  DO \$\$
  DECLARE pfx text := rpad('public_shared_prefix_', 46, 'x');
  BEGIN
    PERFORM bucardo.fixture_mk('public','tbl_one',   pfx || '!' || left(md5('public.tbl_one'),   10));
    PERFORM bucardo.fixture_mk('public','tbl_two',   pfx || '!' || left(md5('public.tbl_two'),   10));
    PERFORM bucardo.fixture_mk('public','tbl_three', pfx || '!' || left(md5('public.tbl_three'), 10));
  END \$\$;
" >/dev/null

# Fixture-validity guard: if the naive name no longer collides, this scenario
# proves nothing and must fail loudly rather than pass vacuously.
assert_eq "fixture is armed: naive left('bc_txntime_'||relname,63) collapses 3 names into 1" "3/1" \
  "$(q "SELECT count(*) || '/' || count(DISTINCT left('bc_txntime_'||c.relname,63))
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='bucardo' AND c.relkind='r' AND left(c.relname,6)='track_'")"
assert_eq "fixture track names are at the 63-char identifier limit" "63" \
  "$(q "SELECT DISTINCT length(c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='bucardo' AND c.relkind='r' AND left(c.relname,6)='track_'")"

run_script
assert_eq "exit code" "0" "$LAST_RC"
assert_all_covered "S3"
assert_eq "one distinct index per colliding table" "3/3" \
  "$(txntime_index_names | awk 'BEGIN{n=0} {n++; seen[$0]=1} END{print n"/"length(seen)}')"
assert_eq "no created index name exceeds 63 chars" "0" \
  "$(txntime_index_names | awk 'length($0) > 63' | grep -c .)"

# === S4: Fail closed ========================================================
log "S4: Fail-closed behaviour"

# 4a: zero track tables
reset_bucardo
qe "INSERT INTO bucardo.bucardo_delta_names VALUES ('planetscale_import','public.x','delta_x','track_x')" >/dev/null
run_script
[ "$LAST_RC" -ne 0 ] && pass "zero track tables -> non-zero exit ($LAST_RC)" || fail "zero track tables -> exited 0"
printf '%s\n' "$LAST_OUT" | grep -qi "track" && pass "zero track tables -> message mentions track tables" \
  || fail "zero track tables -> unhelpful message: $LAST_OUT"

# 4b: no bucardo schema at all
qe "DROP SCHEMA IF EXISTS bucardo CASCADE" >/dev/null
run_script
[ "$LAST_RC" -ne 0 ] && pass "no bucardo schema -> non-zero exit ($LAST_RC)" || fail "no bucardo schema -> exited 0"
assert_eq "script did not create the bucardo schema" "0" \
  "$(q "SELECT count(*) FROM pg_namespace WHERE nspname='bucardo'")"

# 4c: --verify-only detects an induced miss and creates nothing
reset_bucardo
qe "
  SELECT bucardo.fixture_mk('public','a','public_a');
  SELECT bucardo.fixture_mk('public','b','public_b');
  SELECT bucardo.fixture_mk('public','c','public_c');
  CREATE INDEX dex4_public_a ON bucardo.track_public_a (txntime);
  CREATE INDEX dex4_public_b ON bucardo.track_public_b (txntime);
" >/dev/null
before="$(q "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='bucardo'")"
run_script --verify-only
[ "$LAST_RC" -ne 0 ] && pass "--verify-only with one uncovered table -> non-zero exit ($LAST_RC)" \
  || fail "--verify-only with one uncovered table -> exited 0"
printf '%s\n' "$LAST_OUT" | grep -q "track_public_c" && pass "--verify-only names the uncovered table" \
  || fail "--verify-only did not name track_public_c: $LAST_OUT"
assert_eq "--verify-only created nothing" "$before" \
  "$(q "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='bucardo'")"

run_script
assert_eq "full run after partial state -> exit 0" "0" "$LAST_RC"
assert_eq "full run reports 2 pre-existing" "add-track-indexes: tables=3 created=1 existing=2" "$(summary_line)"
run_script --verify-only
assert_eq "--verify-only now passes" "0" "$LAST_RC"

# 4d: read-only session, e.g. the source URL pointing at a read replica
reset_bucardo
qe "SELECT bucardo.fixture_mk('public','ro','public_ro')" >/dev/null
LAST_OUT="$(PGOPTIONS='-c default_transaction_read_only=on' sh "$SCRIPT" --primary "$URL" 2>&1)"; LAST_RC=$?
[ "$LAST_RC" -ne 0 ] && pass "read-only session -> non-zero exit ($LAST_RC)" || fail "read-only session -> exited 0"
assert_eq "read-only failure left nothing half-done" "1" "$(uncovered)"

# === S5: Quoting / injection ================================================
log "S5: Hostile identifiers (quoting, injection)"
reset_bucardo
qe "
  DROP TABLE IF EXISTS public.canary;
  CREATE TABLE public.canary (id int);
  SELECT bucardo.fixture_mk('public','Users','Users_MixedCase');
  SELECT bucardo.fixture_mk('public','order items','order items');
  SELECT bucardo.fixture_mk('public','q','tab\"quote');
  SELECT bucardo.fixture_mk('public','o','o''brien');
  SELECT bucardo.fixture_mk('public','u','naive_unicode_ü');
  SELECT bucardo.fixture_mk('public','e','evil--comment');
  SELECT bucardo.fixture_mk('public','s','semi;colon');
  SELECT bucardo.fixture_mk('public','d','\$dollar\$quote');
  SELECT bucardo.fixture_mk('public','w','white space');
" >/dev/null

run_script
assert_eq "exit code" "0" "$LAST_RC"
assert_all_covered "S5"
assert_eq "all 9 hostile-named track tables indexed" "add-track-indexes: tables=9 created=9 existing=0" "$(summary_line)"
assert_eq "public.canary survives (no SQL injection)" "1" \
  "$(q "SELECT count(*) FROM pg_class WHERE relname='canary'")"
printf '%s\n' "$LAST_OUT" | grep -qiE "syntax error|ERROR:" && fail "errors in output: $LAST_OUT" \
  || pass "no SQL errors on hostile identifiers"

# === S6: Idempotency ========================================================
log "S6: Idempotency"
reset_bucardo
qe "
  SELECT bucardo.fixture_mk('public','users','public_users');
  SELECT bucardo.fixture_mk('public','orders','public_orders');
" >/dev/null
SNAP_SQL="SELECT ci.relname || ' :: ' || pg_get_indexdef(i.indexrelid)
  FROM pg_index i
  JOIN pg_class ci ON ci.oid = i.indexrelid
  JOIN pg_class c ON c.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'bucardo' ORDER BY 1"

run_script
snap1="$(q "$SNAP_SQL")"
run_script
assert_eq "second run exit 0" "0" "$LAST_RC"
assert_eq "second run creates nothing" "add-track-indexes: tables=2 created=0 existing=2" "$(summary_line)"
run_script
snap3="$(q "$SNAP_SQL")"
assert_eq "third run exit 0" "0" "$LAST_RC"
if [ "$snap1" = "$snap3" ]; then
  pass "index definitions byte-identical across runs"
else
  fail "index definitions drifted across runs"
fi
assert_all_covered "S6"

# === S7: Near-miss indexes ==================================================
log "S7: Near-miss indexes that must not count as satisfied"
reset_bucardo
qe "
  SELECT bucardo.fixture_mk('public','partial','public_partial');
  SELECT bucardo.fixture_mk('public','hash','public_hash');
  SELECT bucardo.fixture_mk('public','dex3only','public_dex3only');
  SELECT bucardo.fixture_mk('public','composite','public_composite');
  SELECT bucardo.fixture_mk('public','foreign','public_foreign');
  SELECT bucardo.fixture_mk('public','expr','public_expr');
  CREATE INDEX ON bucardo.track_public_partial (txntime) WHERE target = 'x';
  CREATE INDEX ON bucardo.track_public_hash USING hash (txntime);
  CREATE INDEX ON bucardo.track_public_composite (txntime, target);
  CREATE INDEX my_custom_txntime ON bucardo.track_public_foreign (txntime);
  CREATE INDEX ON bucardo.track_public_expr ((txntime AT TIME ZONE 'UTC'));
" >/dev/null

run_script
assert_eq "exit code" "0" "$LAST_RC"
assert_all_covered "S7"
# partial, hash, dex3-only and expression-only are NOT satisfied -> 4 created.
# (txntime, target) composite and the foreign-named (txntime) ARE satisfied.
assert_eq "only genuinely-uncovered tables get an index" "add-track-indexes: tables=6 created=4 existing=2" "$(summary_line)"
assert_eq "pre-existing foreign-named index kept, not duplicated" "2" "$(index_count track_public_foreign)"
assert_eq "composite (txntime,target) accepted, not duplicated" "2" "$(index_count track_public_composite)"

# === S8: Teardown lifecycle =================================================
log "S8: Teardown drops our indexes with the schema; re-run restores them"
reset_bucardo
qe "SELECT bucardo.fixture_mk('public','users','public_users')" >/dev/null
run_script
assert_eq "indexes present before teardown" "0" "$(uncovered)"
# What rm-bucardo-repl.sh does to the source on cleanup/abort/retry:
qe "DROP SCHEMA IF EXISTS bucardo CASCADE" >/dev/null
assert_eq "no dex4_* index survives teardown" "0" \
  "$(q "SELECT count(*) FROM pg_class WHERE relname LIKE 'dex4\_%'")"
assert_eq "nothing of ours left in the database" "0" \
  "$(q "SELECT count(*) FROM pg_namespace WHERE nspname='bucardo'")"
reset_bucardo
qe "SELECT bucardo.fixture_mk('public','users','public_users')" >/dev/null
run_script
assert_eq "re-run after teardown -> exit 0" "0" "$LAST_RC"
assert_eq "re-run recreates from scratch" "add-track-indexes: tables=1 created=1 existing=0" "$(summary_line)"
assert_all_covered "S8"

# === S9: Scale ==============================================================
log "S9: Scale (500 track tables, 50 sharing a long prefix)"
reset_bucardo
qe "
  DO \$\$
  BEGIN
    FOR i IN 1..450 LOOP
      PERFORM bucardo.fixture_mk('public','t'||i, 'public_t'||i, 'planetscale_import', false);
    END LOOP;
    FOR i IN 1..50 LOOP
      PERFORM bucardo.fixture_mk('public','long'||i,
        rpad('public_bulk_shared_prefix_',46,'z') || '!' || left(md5('bulk'||i),10),
        'planetscale_import', false);
    END LOOP;
  END \$\$;
" >/dev/null
assert_eq "fixture built 500 track tables" "500" \
  "$(q "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='bucardo' AND c.relkind='r' AND left(c.relname,6)='track_'")"

START=$SECONDS
run_script
ELAPSED=$((SECONDS - START))
assert_eq "exit code" "0" "$LAST_RC"
assert_all_covered "S9"
assert_eq "500 distinct index names" "500/500" \
  "$(txntime_index_names | awk 'BEGIN{n=0} {n++; seen[$0]=1} END{print n"/"length(seen)}')"
if [ "$ELAPSED" -lt 60 ]; then
  pass "500 tables indexed in ${ELAPSED}s (< 60s)"
else
  fail "500 tables took ${ELAPSED}s (>= 60s) -- likely one psql per table"
fi

# === S10: Concurrency =======================================================
log "S10: Two concurrent invocations"
reset_bucardo
qe "
  DO \$\$ BEGIN
    FOR i IN 1..25 LOOP PERFORM bucardo.fixture_mk('public','c'||i, 'public_c'||i); END LOOP;
  END \$\$;
" >/dev/null
sh "$SCRIPT" --primary "$URL" >/tmp/track_idx_a.log 2>&1 & pid_a=$!
sh "$SCRIPT" --primary "$URL" >/tmp/track_idx_b.log 2>&1 & pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?
if [ "$rc_a" -eq 0 ] || [ "$rc_b" -eq 0 ]; then
  pass "at least one concurrent run succeeded (rc=$rc_a/$rc_b)"
else
  fail "both concurrent runs failed (rc=$rc_a/$rc_b): $(tail -3 /tmp/track_idx_a.log)"
fi
assert_all_covered "S10"
assert_eq "no duplicate txntime indexes after concurrent runs" "25/25" \
  "$(txntime_index_names | awk 'BEGIN{n=0} {n++; seen[$0]=1} END{print n"/"length(seen)}')"

# === B: Query-plan and timing gate ==========================================
log "B: bucardo_delta_check plan and timing"
reset_bucardo
qe "SELECT bucardo.fixture_mk('public','perf','perf')" >/dev/null
qe "
  INSERT INTO bucardo.track_perf (txntime, target)
  SELECT timestamptz '2026-01-01 00:00:00+00' + (g || ' seconds')::interval,
         'dbgroup planetscale_import'
  FROM generate_series(1, 100000) g;

  INSERT INTO bucardo.delta_perf (tablename, txntime, rowid)
  SELECT 'bucardo.track_perf'::regclass::oid,
         timestamptz '2026-01-01 00:00:00+00' + (g || ' seconds')::interval, g::text
  FROM generate_series(1, 20000) g;

  -- One unmatched row, inserted last, so the LIMIT 1 anti-join must scan everything.
  INSERT INTO bucardo.delta_perf (tablename, txntime, rowid)
  VALUES ('bucardo.track_perf'::regclass::oid, timestamptz '1999-01-01 00:00:00+00', 'orphan');

  ANALYZE bucardo.track_perf;
  ANALYZE bucardo.delta_perf;
" >/dev/null

# Verbatim bucardo_delta_check() anti-join (bucardo.schema:1517-1524).
Q="SELECT 1 FROM bucardo.delta_perf d
   WHERE NOT EXISTS (
     SELECT 1 FROM bucardo.track_perf t
     WHERE d.txntime = t.txntime
       AND (t.target = 'dbgroup planetscale_import'::text OR t.target ~ '^T:')
   ) LIMIT 1"

# Both the plan and the timing are measured in the NESTED-LOOP regime, because
# that is the regime the production stall happens in: delta_check wraps the query
# in LIMIT 1, and on a multi-million-row track table the planner prefers a plan
# with cheap startup (nested loop, early exit) over hashing the whole table. At
# the modest row counts a test can afford, the planner would instead pick a Hash
# Right Anti Join, which is fast with or without our index -- so measuring the
# default plan here would pass whether or not the fix exists. Forcing the
# nested loop reproduces the real shape and isolates exactly what the index
# changes: whether the inner side is an index scan or a per-row seq scan.
NL="SET enable_hashjoin=off; SET enable_mergejoin=off;
    SET enable_memoize=off; SET enable_material=off;"

exec_ms() { # setup_sql -> min of 3 runs, in ms
  local best=999999 i ms
  for i in 1 2 3; do
    ms="$(psql "$URL" -X -A -t -c "
      SET statement_timeout = '60s';
      $1
      EXPLAIN (ANALYZE, TIMING ON, COSTS OFF) $Q" 2>&1 \
      | grep -o 'Execution Time: [0-9.]*' | grep -o '[0-9.]*' | tail -1)"
    [ -z "$ms" ] && ms=60000
    awk -v a="$ms" -v b="$best" 'BEGIN{exit !(a<b)}' && best="$ms"
  done
  printf '%s' "$best"
}

# --- P1-neg: negative control, BEFORE the fix ---
# Pre-fix the anti-join has no txntime-leading index to use. Depending on
# version and statistics it either sequential-scans track_perf or does a full
# scan of dex3_* (whose leading column is target) applying the txntime cond as a
# filter -- both are O(track rows) per delta row, which is the pathology. What
# must NOT be true pre-fix is that a txntime-leading index is used; if it were,
# P1 below would be a tautology.
plan_pre="$(psql "$URL" -X -A -t -c "$NL EXPLAIN (COSTS OFF) $Q" 2>&1)"
pre_access="$(printf '%s\n' "$plan_pre" | grep -iE 'Scan.*on track_perf' | head -1 | sed 's/^ *//;s/  */ /g')"
if printf '%s\n' "$plan_pre" | grep -q "dex4_"; then
  fail "P1-neg: a txntime-leading index is already in use pre-fix -- control broken"
else
  pass "P1-neg: pre-fix plan uses no txntime-leading index (${pre_access:-no track_perf scan node})"
fi
base_ms="$(exec_ms "$NL")"
plan_pre_natural="$(psql "$URL" -X -A -t -c "EXPLAIN (COSTS OFF) $Q" 2>&1 | grep -iE 'Anti Join|Scan on track_perf' | head -2 | tr '\n' ' ' | sed 's/  */ /g')"
log "  pre-fix: forced-nested-loop ${base_ms}ms; unforced plan =${plan_pre_natural}"

run_script
assert_eq "perf fixture indexed" "0" "$LAST_RC"

IDX="$(txntime_index_names | tr '\n' '|' | sed 's/|$//')"
plan_post="$(psql "$URL" -X -A -t -c "$NL EXPLAIN (COSTS OFF) $Q" 2>&1)"

# Assert on the index NAME, not on "Index Cond: (txntime = ...)": on PG18 a btree
# skip scan can serve a txntime equality from dex3_perf (target, txntime), so a
# condition-text assertion could pass even with the fix absent.
if printf '%s\n' "$plan_post" | grep -Eq "(Index (Only )?Scan|Bitmap Index Scan) using ($IDX)"; then
  pass "P1: delta_check anti-join uses our txntime index ($IDX)"
else
  fail "P1: plan does not use our index ($IDX): $(printf '%s\n' "$plan_post" | tr '\n' ' ')"
fi
if printf '%s\n' "$plan_post" | grep -q "Seq Scan on track_perf"; then
  fail "P1: plan still sequential-scans track_perf"
else
  pass "P1: no Seq Scan on track_perf"
fi

idx_ms="$(exec_ms "$NL")"
log "  post-fix: forced-nested-loop ${idx_ms}ms (was ${base_ms}ms)"

# The invariant that must hold on every version: after the fix, delta_check is
# fast in the nested-loop regime.
if awk -v v="$idx_ms" 'BEGIN{exit !(v < 250)}'; then
  pass "P2: indexed delta_check runs in ${idx_ms}ms (< 250ms)"
else
  fail "P2: indexed delta_check took ${idx_ms}ms (>= 250ms)"
fi

# The speedup assertion only applies where the baseline is actually pathological.
# PostgreSQL 18 added btree skip scan, which can use dex3_* (target, txntime) for
# a txntime-only predicate, so on PG18 the pre-fix plan is already fast and there
# is no slowdown to remove. Demanding a speedup there would be asserting a bug
# that version does not have. Note that skip scan degrades as the number of
# distinct "target" values grows, so the index is still worth having on PG18.
if awk -v b="$base_ms" 'BEGIN{exit !(b > 250)}'; then
  if awk -v b="$base_ms" -v i="$idx_ms" 'BEGIN{exit !(i > 0 && b/i >= 20)}'; then
    pass "P2: pathological baseline removed -- speedup $(awk -v b="$base_ms" -v i="$idx_ms" 'BEGIN{printf "%.0fx", b/i}') (>= 20x)"
  else
    fail "P2: baseline was ${base_ms}ms but speedup is only $(awk -v b="$base_ms" -v i="$idx_ms" 'BEGIN{printf "%.1fx", b/i}') (< 20x)"
  fi
else
  pass "P2: this planner already avoids the pathology (baseline ${base_ms}ms); index still applied and correct"
  log "  NOTE: baseline was not pathological on this version -- expected on PG18+ (btree skip scan)."
fi

# --- Cleanup ----------------------------------------------------------------
qe "DROP SCHEMA IF EXISTS bucardo CASCADE; DROP TABLE IF EXISTS public.track_decoy, public.canary" >/dev/null 2>&1

echo ""
echo "========================================"
printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ]
