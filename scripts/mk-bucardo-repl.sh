#!/bin/sh
set -e
# =============================================================================
# mk-bucardo-repl.sh -- configure replication from primary to replica.
#
# Copies the schema, drops the target's secondary indexes for a faster initial
# copy, registers both databases and all relations with Bucardo, then starts
# the sync. Re-runnable: --skip-schema resumes without re-copying the schema.
# =============================================================================

usage() {
  printf "Usage: sh %s --primary \e[4mconninfo\e[0m --replica \e[4mconninfo\e[0m [--skip-schema] [--no-initial-copy]\n" "$(basename "$0")" >&2
  printf "  --primary \e[4mconninfo\e[0m  connection information for the primary (Heroku) Postgres database\n" >&2
  printf "  --replica \e[4mconninfo\e[0m  connection information for the replica (PlanetScale) Postgres database\n" >&2
  printf "  --skip-schema         skip schema copy (schema already exists on replica)\n" >&2
  printf "  --no-initial-copy     set onetimecopy=0 (data already copied, resume replication only)\n" >&2
  exit "$1"
}

PRIMARY="" REPLICA="" SKIP_SCHEMA=0 NO_INITIAL_COPY=0
while [ "$#" -gt 0 ]
do
  case "$1" in

  "-p"|"--primary") PRIMARY="$2" shift 2;;
  "-p"*) PRIMARY="$(echo "$1" | cut -c"3-")" shift;;
  "--primary="*) PRIMARY="$(echo "$1" | cut -d"=" -f"2-")" shift;;

  "-r"|"--replica") REPLICA="$2" shift 2;;
  "-r"*) REPLICA="$(echo "$1" | cut -c"3-")" shift;;
  "--replica="*) REPLICA="$(echo "$1" | cut -d"=" -f"2-")" shift;;

  "--skip-schema") SKIP_SCHEMA=1 shift;;
  "--no-initial-copy") NO_INITIAL_COPY=1 shift;;

  "-h"|"--help") usage 0;;
  *) usage 1;;
  esac
done
if [ -z "$PRIMARY" -o -z "$REPLICA" ]
then usage 1
fi

# pg_partman can be installed in any schema, so resolve it once. quote_ident
# makes it safe to interpolate below.
PM_SCHEMA=$(psql "$PRIMARY" -A -t -c "
  SELECT quote_ident(n.nspname)
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'pg_partman';" 2>/dev/null | tr -d '[:space:]')

# pg_partman's template tables have no primary key, so Bucardo refuses them.
# With pg_partman in public they look like ordinary app tables, so
# match them by name from part_config instead.
PM_TEMPLATE_FILTER=""
if [ -n "$PM_SCHEMA" ]; then
  PM_TEMPLATE_FILTER="OR (n.nspname || '.' || c.relname) IN (
        SELECT template_table FROM ${PM_SCHEMA}.part_config
        WHERE template_table IS NOT NULL
      )"
fi

# Copy the schema from the primary to the replica.
if [ "$SKIP_SCHEMA" -eq 0 ]; then
  echo "Copying schema from primary to replica..."

  EXCLUDE_PATTERN="^COMMENT ON EXTENSION |^CREATE TRIGGER bucardo_"
  REPLICA_VERSION_NUM=$(psql "$REPLICA" -Atc "SHOW server_version_num;")
  if [ "$REPLICA_VERSION_NUM" -lt 170000 ]; then
    EXCLUDE_PATTERN="$EXCLUDE_PATTERN|^SET transaction_timeout = 0;$"
  fi

  pg_dump --no-owner --no-privileges --no-publications --no-subscriptions --schema-only \
    --exclude-schema=bucardo --exclude-schema=_ps_migrator --exclude-schema=pscale_extensions "$PRIMARY" |
  sed -E "s/^CREATE SCHEMA (.+);$/CREATE SCHEMA IF NOT EXISTS \1;/" |
  grep -v -E "$EXCLUDE_PATTERN" |
  psql "$REPLICA" -a --set ON_ERROR_STOP=1
else
  echo "Skipping schema copy (--skip-schema flag set)"
fi

# pg_partman keeps its partition sets in part_config, which the schema copy
# creates empty: it carries the extension, not the extension's rows. Without
# this the target has pg_partman installed, no partition sets registered, and
# never creates another partition. Re-register them from the source.

# Drop secondary/unique indexes so the initial COPY skips per-row index
# maintenance
if [ "$SKIP_SCHEMA" -eq 0 ]; then
  sh "$(dirname "$0")/drop-secondary-indexes.sh" --replica "$REPLICA"
fi

# Register both databases, parsing the fields Bucardo needs out of each URL.
bucardo add database "heroku" \
  host="$(echo "$PRIMARY" | cut -d "@" -f 2 | cut -d ":" -f 1)" \
  user="$(echo "$PRIMARY" | cut -d "/" -f 3 | cut -d ":" -f 1)" \
  password="$(echo "$PRIMARY" | cut -d ":" -f 3 | cut -d "@" -f 1)" \
  dbname="$(echo "$PRIMARY" | cut -d "/" -f 4 | cut -d "?" -f 1)"

bucardo add database "planetscale" \
  host="$(echo "$REPLICA" | cut -d "@" -f 2 | cut -d ":" -f 1)" \
  port="$(echo "$REPLICA" | cut -d "@" -f 2 | cut -d ":" -f 2 | cut -d "/" -f 1)" \
  user="$(echo "$REPLICA" | cut -d "/" -f 3 | cut -d ":" -f 1)" \
  password="$(echo "$REPLICA" | cut -d ":" -f 3 | cut -d "@" -f 1)" \
  dbname="$(echo "$REPLICA" | cut -d "/" -f 4 | cut -d "?" -f 1)"

bucardo update database planetscale dbconn='options=--transaction_timeout=0'
bucardo update database heroku dbconn='options=--transaction_timeout=0'

# Add all the sequences and tables to Bucardo.
bucardo add all sequences --relgroup "planetscale_import"
bucardo add all tables --relgroup "planetscale_import"

# `add all tables` enrols every user table, including ones Bucardo cannot
# replicate, and `bucardo add sync` fails. 
# Subtract them here, while the sync does not exist yet: validate_sync is what
# creates the triggers, so nothing is left behind on the source.
# Keep this predicate in sync with migrated_relation_scope_sql in server.rb.
NOT_REPLICATABLE=$(psql "$PRIMARY" -A -t -c "
  SELECT n.nspname || '.' || c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r'
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'bucardo')
    AND left(n.nspname, 3) <> 'pg_'
    AND (
      n.nspname IN (
        SELECT en.nspname FROM pg_extension e
        JOIN pg_namespace en ON en.oid = e.extnamespace
        WHERE en.nspname NOT IN ('public', 'pg_catalog')
      )
      OR EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_class'::regclass
          AND d.objid = c.oid AND d.deptype = 'e'
      )
      OR NOT pg_catalog.has_table_privilege(current_user, c.oid, 'TRIGGER')
      ${PM_TEMPLATE_FILTER}
    )
  ORDER BY 1;")

if [ -n "$NOT_REPLICATABLE" ]; then
  echo "Excluding tables Bucardo cannot replicate (extension-owned, or no TRIGGER privilege):"
  echo "$NOT_REPLICATABLE" | sed "s/^/  /"

  bucardo remove table $NOT_REPLICATABLE
fi

# Bucardo 5.6 cannot COPY into generated columns, so for each table that has
# one, register an override selecting only the non-generated columns. The
# target keeps the generation expression and recomputes the value on insert.
GENERATED_TABLES=$(psql "$PRIMARY" -A -t -F"|" -c "
  SELECT DISTINCT n.nspname, c.relname
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname <> 'information_schema'
    AND n.nspname <> 'bucardo'
    AND left(n.nspname, 3) <> 'pg_'
    AND c.relkind = 'r'
    AND a.attnum > 0 AND NOT a.attisdropped
    AND a.attgenerated <> ''
  ORDER BY n.nspname, c.relname;")

if [ -n "$GENERATED_TABLES" ]; then
  echo "Detected tables with generated columns; registering customcols overrides..."
  echo "$GENERATED_TABLES" | while IFS='|' read -r schema table; do
    [ -z "$table" ] && continue
    cols=$(psql "$PRIMARY" -A -t -c "
      SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum)
      FROM pg_attribute
      WHERE attrelid = format('%I.%I', '${schema}', '${table}')::regclass
        AND attnum > 0 AND NOT attisdropped
        AND attgenerated = '';")
    if [ -z "$cols" ]; then
      echo "  Skipping ${schema}.${table}: no non-generated columns found"
      continue
    fi
    echo "  Excluding generated columns on ${schema}.${table} via customcols"
    bucardo add customcols "${schema}.${table}" "SELECT ${cols}" db=planetscale
  done
fi

# Add the sync configuration to Bucardo.
if [ "$NO_INITIAL_COPY" -eq 0 ]; then
  echo "Configuring sync with initial data copy..."
  bucardo add sync "planetscale_import" dbs="heroku,planetscale" onetimecopy=1 relgroup="planetscale_import"
else
  echo "Configuring sync without initial copy (--no-initial-copy flag set)..."
  bucardo add sync "planetscale_import" dbs="heroku,planetscale" onetimecopy=0 relgroup="planetscale_import"
fi

# `bucardo add sync` created the source-side track tables; `bucardo reload`
# below starts the sync. Index them here, while they are still empty: instant,
# and it locks nothing.
sh "$(dirname "$0")/add-track-indexes.sh" --primary "$PRIMARY"

bucardo set reload_config_timeout=180 log_level=verbose

# Reload Bucardo, which starts the sync we just added.
bucardo reload

sh "$(dirname "$0")/stat-bucardo-repl.sh" --primary "$PRIMARY" --replica "$REPLICA"
