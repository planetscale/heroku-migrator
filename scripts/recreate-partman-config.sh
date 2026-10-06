#!/bin/sh
set -u
# =============================================================================
# recreate-partman-config.sh -- replay the source's pg_partman configuration
# onto the replica. Runs AFTER the initial copy: create_partition premakes
# partitions, and a target partition covering a range the source keeps in a
# DEFAULT partition makes those rows unloadable, because Bucardo copies leaf to
# leaf and bypasses tuple routing.
# =============================================================================
usage() {
  printf "Usage: sh %s --primary \033[4mconninfo\033[0m --replica \033[4mconninfo\033[0m\n" "$(basename "$0")" >&2
  exit "$1"
}

PRIMARY="" REPLICA=""
while [ "$#" -gt 0 ]
do
  case "$1" in
  "-p"|"--primary") PRIMARY="$2" shift 2;;
  "--primary="*) PRIMARY="$(echo "$1" | cut -d"=" -f"2-")" shift;;
  "-r"|"--replica") REPLICA="$2" shift 2;;
  "--replica="*) REPLICA="$(echo "$1" | cut -d"=" -f"2-")" shift;;
  "-h"|"--help") usage 0;;
  *) usage 1;;
  esac
done
[ -z "$PRIMARY" ] || [ -z "$REPLICA" ] && usage 1

PM_SCHEMA=$(psql "$PRIMARY" -A -t -c "
  SELECT quote_ident(n.nspname)
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'pg_partman';" 2>/dev/null | tr -d '[:space:]')

pm="$PM_SCHEMA"
[ -z "$pm" ] && exit 0
# dump_partitioned_table_definition arrived in pg_partman 4.5.
if [ -z "$(psql "$PRIMARY" -A -t -c "
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE quote_ident(n.nspname) = '${pm}'
        AND p.proname = 'dump_partitioned_table_definition' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')" ]; then
  echo "pg_partman found but dump_partitioned_table_definition is unavailable;"
  echo "  re-register partition sets on the target by hand after cutover."
  exit 0
fi

echo "Detected pg_partman; recreating partition configuration on the replica..."

# Pin the start to the oldest existing child; NULL (no children) replays as-is.
# The schema copy already created the default partition, replay with 'f'
pm_sql=$(psql "$PRIMARY" -A -t -c "
  SELECT replace(replace(
           ${pm}.dump_partitioned_table_definition(parent_table),
           format('p_parent_table := %L,', parent_table),
           format('p_parent_table := %L,' || E'\n\tp_start_partition := %L,', parent_table,
             (SELECT coalesce(i.child_start_time::text, i.child_start_id::text)
              FROM (SELECT * FROM ${pm}.show_partitions(parent_table) LIMIT 1) s,
                   ${pm}.show_partition_info(
                     format('%I.%I', s.partition_schemaname, s.partition_tablename)) i))),
           'p_default_table := ''t''', 'p_default_table := ''f''')
  FROM ${pm}.part_config
  ORDER BY parent_table;" 2>&1) || pm_sql=""

case "$pm_sql" in
  *ERROR*)
    echo "  WARNING: could not generate the pg_partman definitions:"
    printf "%s\n" "$pm_sql" | head -3 | sed "s/^/    /"
    echo "  The data migration is unaffected; re-register the sets by hand."
    exit 0
    ;;
esac

if [ -z "$pm_sql" ]; then
  echo "  No partition sets registered on the source; nothing to recreate."
  exit 0
fi

# Deliberately no ON_ERROR_STOP: one partition set that will not replay must
# not abort an otherwise good migration.
pm_out=$(printf "%s\n" "$pm_sql" | psql "$REPLICA" -q 2>&1)
printf "%s\n" "$pm_out" | grep -E "^(ERROR|WARNING)" | sed "s/^/  /"
if printf "%s\n" "$pm_out" | grep -q "^ERROR"; then
  echo "  WARNING: some pg_partman sets did not replay. The data migration is"
  echo "  unaffected; re-register them on the target with"
  echo "  ${pm}.dump_partitioned_table_definition() after cutover."
fi

pm_sub=$(psql "$PRIMARY" -A -t -c "SELECT count(*) FROM ${pm}.part_config_sub;" 2>/dev/null | tr -d '[:space:]')
if [ -n "$pm_sub" ] && [ "$pm_sub" != "0" ]; then
  echo "  NOTE: $pm_sub sub-partition set(s) found. dump_partitioned_table_definition()"
  echo "  covers single-level sets only; re-register sub-partitioning by hand."
fi

pm_done=$(psql "$REPLICA" -A -t -c "SELECT count(*) FROM ${pm}.part_config;" 2>/dev/null | tr -d '[:space:]')
echo "  Partition sets registered on the replica: ${pm_done:-unknown}"
