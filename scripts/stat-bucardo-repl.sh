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

export PSQL_PAGER=""

TMP="$(mktemp -d)"
trap "rm -f -r \"$TMP\"" EXIT INT QUIT TERM

# Inspect the schema on the primary and replica.
echo >&2
echo "##############################" >&2
echo "# PRIMARY AND REPLICA SCHEMA #" >&2
echo "##############################" >&2
echo >&2
psql "$PRIMARY" -c '\d'
psql "$REPLICA" -c '\d'
echo >&2

echo >&2
echo "######################" >&2
echo "# REPLICATION STATUS #" >&2
echo "######################" >&2
echo >&2

bucardo status "planetscale_import" >"$TMP/status.out"
cat "$TMP/status.out"
echo >&2
echo "STATUS: $(awk -F " : " '/^Status/ {print $2}' <"$TMP/status.out")"
printf "INITIAL COPY PHASE: "
if awk -F " : " '/^Onetimecopy/ {print $2}' <"$TMP/status.out" | grep -q "Yes"
then echo "in-progress"
else echo "finished"
fi
STATE="$(awk -F " : " '/^Current state/ {print $2}' <"$TMP/status.out")"
printf "STATE: "
case "$STATE" in
  "No records found") echo "not-yet-started";;
  "Good"|"Bad") echo "$STATE";;
  *) echo "$STATE (good)";;
esac
LAST_ERROR="$(awk -F " : " '/^Last error/ {print $2}' <"$TMP/status.out")"
if [ "$LAST_ERROR" ]
then echo "LAST ERROR: $LAST_ERROR"
fi
ROWS_CHANGED="$(awk -F " [:/] " '/^Rows deleted\/inserted/ {print $2+$3}' <"$TMP/status.out")"
if [ "$ROWS_CHANGED" ]
then echo "ROWS CHANGED IN LAST SYNC: $ROWS_CHANGED"
fi
LAST_GOOD="$(awk -F " : " '/^Last good/ {print $2}' <"$TMP/status.out")"
SECONDS_SINCE_LAST_SYNC=0
if [ "$LAST_GOOD" ]
then
  TS_NOW="$(date +"%s")"
  TS_LAST_GOOD="$(date -d "$(
    awk -F " : " '/^Last good/ {print $2}' <"$TMP/status.out" |
    cut -c "-21"
  )" +"%s")"
  SECONDS_SINCE_LAST_SYNC="$((TS_NOW - TS_LAST_GOOD))"
  echo "SECONDS SINCE LAST SYNC: $SECONDS_SINCE_LAST_SYNC"
fi
if [ "$SECONDS_SINCE_LAST_SYNC" -gt 60 ]
then
  echo >&2
  echo "It has been more than one minute since the last sync. This means either replication is stalled or there haven't been any writes recently." >&2
fi
