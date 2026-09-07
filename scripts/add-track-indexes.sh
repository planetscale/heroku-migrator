#!/bin/sh
set -e
# =============================================================================
# add-track-indexes.sh -- index the primary's Bucardo track tables on txntime.
#
# Every sync cycle, bucardo_delta_check() anti-joins delta against track on
# txntime alone. Bucardo indexes delta tables on (txntime) but track tables on
# (target text_pattern_ops, txntime), so a txntime-only predicate has no access
# predicate and the check degrades to a sequential scan of the track table per
# delta row. On a large migration those tables grow for hours during the
# initial copy, the check then never returns, and the purge that would shrink
# them never runs -- a stall that restart and pause/resume cannot clear.
#
# Runs from mk-bucardo-repl.sh between `bucardo add sync` (which creates these
# tables) and `bucardo reload` (which starts the sync), so the tables are still
# empty: each CREATE INDEX is instant and takes no lock on the application
# path, since source writes only reach bucardo.delta_*. That is why this needs
# no `bucardo stop`, unlike after-the-fact remediation.
#
# Fails closed -- a non-zero exit aborts setup, because an index missing here
# surfaces hours later as a stall that is hard to trace back.
# =============================================================================

usage() {
  printf "Usage: sh %s --primary \e[4mconninfo\e[0m [--verify-only]\n" "$(basename "$0")" >&2
  printf "  --primary \e[4mconninfo\e[0m  connection information for the primary (Heroku) database\n" >&2
  printf "  --verify-only         report coverage without creating anything\n" >&2
  exit "$1"
}

PRIMARY="" VERIFY_ONLY=0
while [ "$#" -gt 0 ]
do
  case "$1" in

  "-p"|"--primary") PRIMARY="$2" shift 2;;
  "-p"*) PRIMARY="$(echo "$1" | cut -c"3-")" shift;;
  "--primary="*) PRIMARY="$(echo "$1" | cut -d"=" -f"2-")" shift;;

  "--verify-only") VERIFY_ONLY=1 shift;;

  "-h"|"--help") usage 0;;
  *) usage 1;;
  esac
done
if [ -z "$PRIMARY" ]
then usage 1
fi

# Bucardo creates its schema on the source during sync validation. If it is
# absent we were called before `bucardo add sync`, or setup never ran.
HAS_BUCARDO="$(psql "$PRIMARY" -X -A -t -c \
  "SELECT count(*) FROM pg_namespace WHERE nspname = 'bucardo'" | tr -d '[:space:]')"
if [ "$HAS_BUCARDO" = "0" ]; then
  echo "ERROR: the 'bucardo' schema does not exist on the source database." >&2
  echo "Bucardo's change-tracking tables were never created, so there is nothing to index." >&2
  echo "Re-run replication setup before starting the data copy." >&2
  exit 5
fi

TRACK_COUNT="$(psql "$PRIMARY" -X -A -t -c \
  "SELECT count(*) FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'bucardo'
      AND c.relkind IN ('r', 'p')
      AND left(c.relname, 6) = 'track_'" | tr -d '[:space:]')"
if [ "$TRACK_COUNT" = "0" ]; then
  echo "ERROR: no bucardo.track_* tables exist on the source database." >&2
  echo "Bucardo has not created its change-tracking tables, so replication is not armed." >&2
  echo "Re-run replication setup before starting the data copy." >&2
  exit 4
fi

if [ "$VERIFY_ONLY" -eq 1 ]; then
  echo "Verifying txntime indexes on ${TRACK_COUNT} Bucardo track table(s)..."
else
  echo "Ensuring txntime indexes on ${TRACK_COUNT} Bucardo track table(s)..."
fi

psql "$PRIMARY" -X -v ON_ERROR_STOP=1 -v verify_only="$VERIFY_ONLY" <<'SQL'
-- One transaction: either every track table ends up with a txntime-leading
-- index, or nothing changes.
BEGIN;

-- psql does not interpolate :vars inside dollar-quoted bodies, so the mode
-- reaches the DO block through a transaction-local GUC.
SELECT set_config('ps_migrator.verify_only', :'verify_only', true);

-- One statement may loop over thousands of tables, so no statement_timeout;
-- but never queue behind an unexpected lock either. Safe to re-run.
SET LOCAL statement_timeout = 0;
SET LOCAL lock_timeout = '15s';

DO $do$
DECLARE
  r        record;
  idxname  text;
  total    int := 0;
  created  int := 0;
  existing int := 0;
  missing  text[] := ARRAY[]::text[];
  verify_only boolean := coalesce(current_setting('ps_migrator.verify_only', true), '0') = '1';
BEGIN
  FOR r IN
    SELECT c.oid, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'bucardo'
      AND c.relkind IN ('r', 'p')
      AND left(c.relname, 6) = 'track_'
    ORDER BY c.relname
  LOOP
    total := total + 1;

    -- Covered already? Any valid btree index that is neither partial nor an
    -- expression index and leads with txntime can serve the anti-join. indkey
    -- is a 0-based int2vector, so indkey[0] is the leading key column; an
    -- expression leading key has attnum 0 and correctly fails the join.
    IF EXISTS (
      SELECT 1
      FROM pg_index i
      JOIN pg_class ci ON ci.oid = i.indexrelid
      JOIN pg_am    am ON am.oid = ci.relam
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
      WHERE i.indrelid = r.oid
        AND a.attname = 'txntime'
        AND am.amname = 'btree'
        AND i.indisvalid
        AND i.indisready
        AND i.indpred IS NULL
        AND i.indexprs IS NULL
    ) THEN
      existing := existing + 1;
      CONTINUE;
    END IF;

    CONTINUE WHEN verify_only;

    -- 'dex4_' || makername, matching Bucardo's own dex1_/dex2_/dex3_ naming.
    -- makername is <= 57 chars and collision-free (bucardo_tablename_maker
    -- keeps an md5 tail when it truncates), so this is <= 62 chars and unique.
    -- Do NOT use left('bc_txntime_' || relname, 63): it chops off exactly that
    -- md5 tail, so two long names collide, IF NOT EXISTS silently no-ops, and
    -- one table ends up with no index at all.
    idxname := 'dex4_' || substring(r.relname from 7);

    -- An index of our name that is INVALID or on the wrong column would make
    -- the CREATE below a silent no-op. This table is not covered, so any such
    -- index is unusable: drop it. If the name belongs to something that is not
    -- an index, let CREATE fail loudly rather than dropping it.
    IF EXISTS (
      SELECT 1
      FROM pg_class ic
      JOIN pg_namespace n2 ON n2.oid = ic.relnamespace
      WHERE n2.nspname = 'bucardo'
        AND ic.relname = idxname
        AND ic.relkind IN ('i', 'I')
    ) THEN
      EXECUTE format('DROP INDEX bucardo.%I', idxname);
      RAISE NOTICE 'Dropped unusable pre-existing index bucardo.%', idxname;
    END IF;

    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON bucardo.%I (txntime)',
                   idxname, r.relname);
    created := created + 1;

    -- Bounded so thousands of tables cannot flood setup.log.
    IF created <= 20 OR created % 250 = 0 THEN
      RAISE NOTICE 'Indexed bucardo.% -> %', r.relname, idxname;
    END IF;
  END LOOP;

  IF total = 0 THEN
    RAISE EXCEPTION 'No bucardo.track_* tables exist on the source database; '
      'Bucardo replication is not armed.';
  END IF;

  -- Re-derive coverage from the catalog instead of trusting the loop above,
  -- so a CREATE that silently no-opped surfaces here rather than as a stall.
  FOR r IN
    SELECT c.oid, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'bucardo'
      AND c.relkind IN ('r', 'p')
      AND left(c.relname, 6) = 'track_'
    ORDER BY c.relname
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_index i
      JOIN pg_class ci ON ci.oid = i.indexrelid
      JOIN pg_am    am ON am.oid = ci.relam
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
      WHERE i.indrelid = r.oid
        AND a.attname = 'txntime'
        AND am.amname = 'btree'
        AND i.indisvalid
        AND i.indisready
        AND i.indpred IS NULL
        AND i.indexprs IS NULL
    ) THEN
      missing := missing || r.relname;
    END IF;
  END LOOP;

  IF array_length(missing, 1) > 0 THEN
    RAISE EXCEPTION 'Verification failed: % of % Bucardo track table(s) have no '
      'index leading with txntime (%). Delta replication would stall after the '
      'initial copy.',
      array_length(missing, 1), total, array_to_string(missing[1:5], ', ');
  END IF;

  RAISE NOTICE 'add-track-indexes: tables=% created=% existing=%',
    total, created, existing;
END
$do$;

COMMIT;
SQL

echo "Done ensuring track-table txntime indexes."
