set -e

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
  pg_dump --no-owner --no-privileges --no-publications --no-subscriptions --schema-only "$PRIMARY" |
  grep -v -E "^COMMENT ON EXTENSION " |
  psql "$REPLICA" -a --set ON_ERROR_STOP=1
else
  echo "Skipping schema copy (--skip-schema flag set)"
fi

# Add the primary (Heroku) database to Bucardo. Parse the subset of connection
# information Bucardo needs from Heroku's URL-formatted connection information.
bucardo add database "heroku" \
  host="$(echo "$PRIMARY" | cut -d "@" -f 2 | cut -d ":" -f 1)" \
  user="$(echo "$PRIMARY" | cut -d "/" -f 3 | cut -d ":" -f 1)" \
  password="$(echo "$PRIMARY" | cut -d ":" -f 3 | cut -d "@" -f 1)" \
  dbname="$(echo "$PRIMARY" | cut -d "/" -f 4 | cut -d "?" -f 1)"

# Add the (soon to be) replica (PlanetScale) database to Bucardo. Parse the
# connection information Bucardo needs from the URL-formatted connection string.
bucardo add database "planetscale" \
  host="$(echo "$REPLICA" | cut -d "@" -f 2 | cut -d ":" -f 1)" \
  port="$(echo "$REPLICA" | cut -d "@" -f 2 | cut -d ":" -f 2 | cut -d "/" -f 1)" \
  user="$(echo "$REPLICA" | cut -d "/" -f 3 | cut -d ":" -f 1)" \
  password="$(echo "$REPLICA" | cut -d ":" -f 3 | cut -d "@" -f 1)" \
  dbname="$(echo "$REPLICA" | cut -d "/" -f 4 | cut -d "?" -f 1)"

# Add all the sequences and tables to Bucardo.
bucardo add all sequences --relgroup "planetscale_import"
bucardo add all tables --relgroup "planetscale_import"

# Bucardo 5.6 does not filter out PostgreSQL generated columns when issuing
# COPY against the target, which fails with "column ... is a generated column /
# Generated columns cannot be used in COPY". For every table that has at least
# one generated column, register a customcols entry against the planetscale db
# that selects only the non-generated columns. The target already has the
# generation expression (it came across via pg_dump --schema-only), so Postgres
# recomputes the value on insert.
GENERATED_TABLES=$(psql "$PRIMARY" -A -t -F"|" -c "
  SELECT DISTINCT n.nspname, c.relname
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
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
      WHERE attrelid = '${schema}.${table}'::regclass
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

# Give Bucardo enough time to validate all tables across both databases.
# The default 30s timeout is too short for databases with many tables, since
# each table is inspected on both source and target over remote connections.
bucardo set reload_config_timeout=180

# Reload Bucardo, which starts the sync we just added.
bucardo reload

sh "$(dirname "$0")/stat-bucardo-repl.sh" --primary "$PRIMARY" --replica "$REPLICA"
