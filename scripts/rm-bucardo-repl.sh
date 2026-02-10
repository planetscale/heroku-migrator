set -e

usage() {
  printf "Usage: sh %s --primary \e[4mconninfo\e[0m --replica \e[4mconninfo\e[0m\n" "$(basename "$0")" >&2
  printf "  --primary \e[4mconninfo\e[0m  connection information for the primary (Heroku) Postgres database\n" >&2
  printf "  --replica \e[4mconninfo\e[0m  connection information for the replica (PlanetScale) Postgres database\n" >&2
  exit "$1"
}

PRIMARY="" REPLICA=""
while [ "$#" -gt 0 ]
do
  case "$1" in

  "-p"|"--primary") PRIMARY="$2" shift 2;;
  "-p"*) PRIMARY="$(echo "$1" | cut -c"3-")" shift;;
  "--primary="*) PRIMARY="$(echo "$1" | cut -d"=" -f"2-")" shift;;

  "-r"|"--replica") REPLICA="$2" shift 2;;
  "-r"*) REPLICA="$(echo "$1" | cut -c"3-")" shift;;
  "--replica="*) REPLICA="$(echo "$1" | cut -d"=" -f"2-")" shift;;

  "-h"|"--help") usage 0;;
  *) usage 1;;
  esac
done
if [ -z "$PRIMARY" -o -z "$REPLICA" ]
then usage 1
fi

# Bucardo metadata may be partially missing after restarts; keep teardown idempotent.
bucardo remove sync "planetscale_import" 2>/dev/null || true
bucardo list tables 2>/dev/null | tr -s " " | cut -d " " -f 3 | xargs -r bucardo remove table 2>/dev/null || true
bucardo list sequences 2>/dev/null | tr -s " " | cut -d " " -f 2 | xargs -r bucardo remove sequence 2>/dev/null || true
bucardo remove relgroup "planetscale_import" 2>/dev/null || true
bucardo remove dbgroup "planetscale_import" 2>/dev/null || true
bucardo remove database "planetscale" 2>/dev/null || true
bucardo remove database "heroku" 2>/dev/null || true
bucardo stop 2>/dev/null || true

psql "$PRIMARY" -A -t -c "SELECT format('DROP TRIGGER IF EXISTS %I ON %I.%I;', t.tgname, n.nspname, c.relname)
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE t.tgname LIKE 'bucardo_%'
  AND n.nspname <> 'bucardo';" | psql "$PRIMARY" -a

psql "$PRIMARY" -c "DROP SCHEMA IF EXISTS bucardo CASCADE;"
