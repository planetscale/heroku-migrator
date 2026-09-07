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

# Copy the schema from the primary to the (soon to be) replica.
if [ "$SKIP_SCHEMA" -eq 0 ]; then
  echo "Copying schema from primary to replica..."

  # pg_dump 17 always emits "SET transaction_timeout = 0;", a GUC that only
  # exists on PG17+. Strip it for older replicas, which would otherwise abort
  # with "unrecognized configuration parameter".
  EXCLUDE_PATTERN="^COMMENT ON EXTENSION "
  REPLICA_VERSION_NUM=$(psql "$REPLICA" -Atc "SHOW server_version_num;")
  if [ "$REPLICA_VERSION_NUM" -lt 170000 ]; then
    EXCLUDE_PATTERN="$EXCLUDE_PATTERN|^SET transaction_timeout = 0;$"
  fi

  pg_dump --no-owner --no-privileges --no-publications --no-subscriptions --schema-only "$PRIMARY" |
  grep -v -E "$EXCLUDE_PATTERN" |
  psql "$REPLICA" -a --set ON_ERROR_STOP=1
else
  echo "Skipping schema copy (--skip-schema flag set)"
fi

# Drop secondary/unique indexes so the initial COPY skips per-row index
# maintenance; rebuild recipes are recorded and replayed once it finishes.
# Only meaningful on a fresh schema copy.
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

# Add all the sequences and tables to Bucardo.
bucardo add all sequences --relgroup "planetscale_import"
bucardo add all tables --relgroup "planetscale_import"

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

# Give Bucardo enough time to validate all tables across both databases.
# The default 30s timeout is too short for databases with many tables, since
# each table is inspected on both source and target over remote connections.
bucardo set reload_config_timeout=180 log_level=verbose

# Reload Bucardo, which starts the sync we just added.
bucardo reload

sh "$(dirname "$0")/stat-bucardo-repl.sh" --primary "$PRIMARY" --replica "$REPLICA"
