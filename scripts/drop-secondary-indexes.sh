#!/bin/sh
set -e
# =============================================================================
# drop-secondary-indexes.sh -- clear the replica's indexes before the copy.
#
# Drops secondary and UNIQUE indexes so the initial COPY does not pay per-row
# index maintenance, recording an exact rebuild recipe for each one first. The
# rebuild orchestrator in status-server/server.rb replays them afterwards.
#
# Safety: introspect and drop run as ONE transaction, never with CASCADE. Each
# dependent foreign key is recorded and dropped first, and any index with a
# dependent we cannot fully reconstruct is left in place and marked 'skipped',
# so the database can never hold an object we are unable to rebuild.
#
# Primary keys and the REPLICA IDENTITY USING INDEX are deliberately kept
# =============================================================================

usage() {
  printf "Usage: sh %s --replica \033[4mconninfo\033[0m\n" "$(basename "$0")" >&2
  printf "  --replica \033[4mconninfo\033[0m  connection information for the replica (PlanetScale) database\n" >&2
  exit "$1"
}

REPLICA=""
while [ "$#" -gt 0 ]
do
  case "$1" in
  "-r"|"--replica") REPLICA="$2"; shift 2;;
  "-r"*) REPLICA="$(echo "$1" | cut -c"3-")"; shift;;
  "--replica="*) REPLICA="$(echo "$1" | cut -d"=" -f"2-")"; shift;;
  "-h"|"--help") usage 0;;
  *) usage 1;;
  esac
done
if [ -z "$REPLICA" ]
then usage 1
fi

# Escape hatch: copy with all indexes left in place.
if [ "${DISABLE_INDEX_DEFERRAL:-false}" = "true" ]; then
  echo "DISABLE_INDEX_DEFERRAL=true; leaving all indexes in place (no deferred rebuild)."
  exit 0
fi

echo "Dropping secondary/unique indexes on the target for a faster initial copy..."

psql "$REPLICA" -v ON_ERROR_STOP=1 <<'SQL'

DO $$ BEGIN PERFORM set_config('transaction_timeout','0',false);
EXCEPTION WHEN undefined_object THEN NULL; END $$;

-- One transaction: the recorded rebuild recipes and the DROPs commit together
-- or not at all, so an index can never be dropped without its recipe. Any
-- failure -- an unforeseen dependency, a lost connection -- rolls back, and
-- ON_ERROR_STOP=1 makes psql abort on the first error.
BEGIN;

CREATE SCHEMA IF NOT EXISTS _ps_migrator;

CREATE TABLE IF NOT EXISTS _ps_migrator.dropped_indexes (
  id          serial PRIMARY KEY,
  schemaname  text NOT NULL,
  tablename   text NOT NULL,
  objectname  text NOT NULL,
  kind        text NOT NULL,        -- 'index' | 'unique' | 'fkey'
  rebuild_sql text NOT NULL,
  pass        smallint NOT NULL,    -- 1 = indexes + uniques, 2 = dependent FKs
  size_bytes  bigint,               -- target table size, filled at rebuild start
  status      text NOT NULL DEFAULT 'pending',  -- pending|building|done|failed|skipped
  error       text,
  started_at  timestamptz,
  finished_at timestamptz,
  UNIQUE (schemaname, objectname, kind)
);

DO $do$
DECLARE
  r           record;
  dep         record;
  j           int;
  unsafe      boolean;
  fk_defs     text[];
  fk_names    text[];
  fk_schemas  text[];
  fk_tables   text[];
  v_kind      text;
  v_rebuild   text;
  v_name      text;
BEGIN
  -- Idempotent: a prior run already populated the registry, so stop here.
  IF EXISTS (SELECT 1 FROM _ps_migrator.dropped_indexes) THEN
    RAISE NOTICE 'Registry already populated; skipping introspection and drop.';
    RETURN;
  END IF;

  FOR r IN
    SELECT i.indexrelid,
           n.nspname AS schemaname,
           c.relname AS tablename,
           ic.relname AS objectname,
           i.indisunique,
           regexp_replace(pg_get_indexdef(i.indexrelid), ' ON ONLY ', ' ON ') AS indexdef,
           con.oid     AS conoid,
           con.conname AS conname,
           CASE WHEN con.oid IS NOT NULL THEN pg_get_constraintdef(con.oid) END AS condef
    FROM pg_index i
    JOIN pg_class c       ON c.oid = i.indrelid
    JOIN pg_class ic      ON ic.oid = i.indexrelid
    JOIN pg_namespace n   ON n.oid = c.relnamespace
    LEFT JOIN pg_constraint con
           ON con.conindid = i.indexrelid AND con.contype IN ('u', 'p')
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'bucardo', '_ps_migrator', 'pscale_extensions')
      AND left(n.nspname, 3) <> 'pg_'
      AND n.nspname NOT IN (
        SELECT en.nspname FROM pg_extension e
        JOIN pg_namespace en ON en.oid = e.extnamespace
        WHERE en.nspname NOT IN ('public', 'pg_catalog')
      )
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend dx
        WHERE dx.classid = 'pg_class'::regclass
          AND dx.objid = c.oid AND dx.deptype = 'e'
      )
      -- 'p' is the partitioned parent: dropping its index drops every child's,
      -- and rebuilding it rebuilds them all. 
      AND c.relkind IN ('r', 'p')
      AND NOT EXISTS (SELECT 1 FROM pg_inherits ih WHERE ih.inhrelid = i.indexrelid)
      AND i.indislive
      AND NOT i.indisprimary      -- keep primary keys
      AND NOT i.indisexclusion    -- keep exclusion constraints
      AND NOT i.indisreplident    -- keep the REPLICA IDENTITY USING INDEX index
    ORDER BY n.nspname, c.relname, ic.relname
  LOOP
    unsafe     := false;
    fk_defs    := ARRAY[]::text[];
    fk_names   := ARRAY[]::text[];
    fk_schemas := ARRAY[]::text[];
    fk_tables  := ARRAY[]::text[];

    -- Enumerate every object that depends on this index. A foreign key is the
    -- only dependent we can fully reconstruct;
    FOR dep IN
      SELECT dcon.oid AS dconoid, dcon.contype AS dcontype, dcon.conname AS dconname,
             dn.nspname AS dnsp, dcl.relname AS dtable,
             pg_get_constraintdef(dcon.oid) AS dcondef
      FROM pg_depend d
      LEFT JOIN pg_constraint dcon ON dcon.oid = d.objid
                                  AND d.classid = 'pg_constraint'::regclass
      LEFT JOIN pg_class dcl       ON dcl.oid = dcon.conrelid
      LEFT JOIN pg_namespace dn    ON dn.oid = dcl.relnamespace
      WHERE d.refobjid = r.indexrelid
        AND d.refclassid = 'pg_class'::regclass
        AND d.deptype IN ('n', 'a')
    LOOP
      -- Skip the internal/auto dependency of the owning unique constraint itself.
      IF dep.dconoid IS NOT NULL AND dep.dconoid = r.conoid THEN
        CONTINUE;
      END IF;

      IF dep.dcontype = 'f' THEN
        -- Re-add the FK as NOT VALID, then VALIDATE it separately. 
        fk_defs    := fk_defs    || format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s NOT VALID; ALTER TABLE %I.%I VALIDATE CONSTRAINT %I',
                                            dep.dnsp, dep.dtable, dep.dconname, dep.dcondef,
                                            dep.dnsp, dep.dtable, dep.dconname);
        fk_names   := fk_names   || dep.dconname;
        fk_schemas := fk_schemas || dep.dnsp;
        fk_tables  := fk_tables  || dep.dtable;
      ELSE
        unsafe := true;
      END IF;
    END LOOP;

    -- Compute the rebuild recipe and kind for the index/unique object.
    IF r.conoid IS NOT NULL THEN
      v_kind    := 'unique';
      v_name    := r.conname;
      v_rebuild := format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
                          r.schemaname, r.tablename, r.conname, r.condef);
    ELSIF r.indisunique THEN
      v_kind    := 'unique';
      v_name    := r.objectname;
      v_rebuild := r.indexdef;
    ELSE
      v_kind    := 'index';
      v_name    := r.objectname;
      v_rebuild := r.indexdef;
    END IF;

    IF unsafe THEN
      INSERT INTO _ps_migrator.dropped_indexes
        (schemaname, tablename, objectname, kind, rebuild_sql, pass, status)
      VALUES (r.schemaname, r.tablename, v_name, v_kind, v_rebuild, 1, 'skipped')
      ON CONFLICT DO NOTHING;
      RAISE NOTICE 'SKIP %.% index % (non-FK dependent; left in place)',
        r.schemaname, r.tablename, v_name;
      CONTINUE;
    END IF;

    -- Record dependent FKs (pass 2) and drop them first so the unique can be
    -- dropped under RESTRICT.
    FOR j IN 1 .. coalesce(array_length(fk_names, 1), 0) LOOP
      INSERT INTO _ps_migrator.dropped_indexes
        (schemaname, tablename, objectname, kind, rebuild_sql, pass, status)
      VALUES (fk_schemas[j], fk_tables[j], fk_names[j], 'fkey', fk_defs[j], 2, 'pending')
      ON CONFLICT DO NOTHING;
      EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I',
                     fk_schemas[j], fk_tables[j], fk_names[j]);
      RAISE NOTICE 'Dropped dependent FK %.%.% (rebuilds in pass 2)',
        fk_schemas[j], fk_tables[j], fk_names[j];
    END LOOP;

    -- Record the object (pass 1) BEFORE dropping it, then drop with RESTRICT.
    INSERT INTO _ps_migrator.dropped_indexes
      (schemaname, tablename, objectname, kind, rebuild_sql, pass, status)
    VALUES (r.schemaname, r.tablename, v_name, v_kind, v_rebuild, 1, 'pending')
    ON CONFLICT DO NOTHING;

    IF r.conoid IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I',
                     r.schemaname, r.tablename, r.conname);
    ELSE
      EXECUTE format('DROP INDEX %I.%I', r.schemaname, r.objectname);
    END IF;
    RAISE NOTICE 'Dropped % %.% (kind=%)', v_kind, r.schemaname, v_name, v_kind;
  END LOOP;

  RAISE NOTICE 'Index deferral complete: % object(s) recorded for rebuild, % skipped.',
    (SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE status = 'pending'),
    (SELECT count(*) FROM _ps_migrator.dropped_indexes WHERE status = 'skipped');
END
$do$;

COMMIT;
SQL

echo "Done dropping indexes."
