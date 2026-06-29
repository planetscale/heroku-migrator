#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN_DIR="$TMP_DIR/bin"
LOG_FILE="$TMP_DIR/commands.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN_DIR"

cat > "$FAKE_BIN_DIR/pg_dump" <<'SH'
#!/bin/sh
printf "pg_dump %s\n" "$*" >> "$COMMAND_LOG"
cat <<'SQL'
CREATE SCHEMA public;
CREATE SCHEMA app_private;
CREATE EXTENSION pg_partman;
CREATE TABLE public.partman_events (id bigint, created_at timestamptz NOT NULL, payload jsonb NOT NULL, PRIMARY KEY (id, created_at)) PARTITION BY RANGE (created_at);
CREATE TABLE app_private.docs (id bigint PRIMARY KEY, title text NOT NULL);
CREATE TABLE public.part_config (parent_table text PRIMARY KEY, template_table text);
CREATE TABLE public.template_public_partman_events (LIKE public.partman_events);
SQL
SH
chmod +x "$FAKE_BIN_DIR/pg_dump"

cat > "$FAKE_BIN_DIR/psql" <<'SH'
#!/bin/sh
query=""
printf "psql %s\n" "$*" >> "$COMMAND_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-c" ]; then
    shift
    query="$1"
  fi
  shift
done

case "$query" in
  *"FROM pg_extension e"*"e.extname = 'pg_partman'"*)
    echo "public"
    ;;
  *"dump_partitioned_table_definition(parent_table)"*"part_config"*)
    cat <<'SQL'
SELECT public.create_parent(
  p_parent_table := 'public.partman_events',
  p_control := 'created_at',
  p_interval := '1 month',
  p_type := 'range'
);
SQL
    ;;
  *"SELECT n.nspname"*"c.relkind IN ('r', 'p', 'S')"*)
    echo "app_private"
    echo "public"
    ;;
  *"SELECT format('%I.%I', n.nspname, c.relname)"*"c.relkind = 'r'"*)
    echo "app_private.docs"
    echo "public.partman_events_p20260101"
    echo "public.partman_events_p20260201"
    echo "public.posts"
    ;;
  *"SELECT DISTINCT n.nspname, c.relname"*)
    echo "public|posts"
    echo "app_private|docs"
    ;;
  *"string_agg(quote_ident(attname)"*)
    echo "id, title"
    ;;
esac

if [ -z "$query" ]; then
  printf "psql stdin start\n" >> "$COMMAND_LOG"
  cat >> "$COMMAND_LOG"
  printf "psql stdin end\n" >> "$COMMAND_LOG"
fi
exit 0
SH
chmod +x "$FAKE_BIN_DIR/psql"

cat > "$FAKE_BIN_DIR/bucardo" <<'SH'
#!/bin/sh
printf "bucardo %s\n" "$*" >> "$COMMAND_LOG"
if [ "$1" = "status" ]; then
  cat <<'OUT'
Status                   : Active
Onetimecopy              : No
Current state            : Good
OUT
fi
SH
chmod +x "$FAKE_BIN_DIR/bucardo"

export COMMAND_LOG="$LOG_FILE"
export PATH="$FAKE_BIN_DIR:$PATH"

sh "$PROJECT_DIR/scripts/mk-bucardo-repl.sh" \
  --primary "postgres://user:pass@primary:5432/source" \
  --replica "postgres://user:pass@replica:5432/target" \
  >/dev/null

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf "  PASS %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "  FAIL %s\n" "$*" >&2; }

assert_log_contains() {
  local pattern="$1" message="$2"
  if grep -Fq -- "$pattern" "$LOG_FILE"; then
    pass "$message"
  else
    fail "$message"
  fi
}

assert_log_absent() {
  local pattern="$1" message="$2"
  if grep -Fq -- "$pattern" "$LOG_FILE"; then
    fail "$message"
  else
    pass "$message"
  fi
}

assert_log_contains "CREATE EXTENSION pg_partman;" "schema copy preserves pg_partman extension"
assert_log_contains "SELECT public.create_parent(" "pg_partman recreation SQL is applied to replica"
assert_log_contains "bucardo add table public.posts db=heroku relgroup=planetscale_import" "Bucardo includes public application table"
assert_log_contains "bucardo add table app_private.docs db=heroku relgroup=planetscale_import" "Bucardo includes non-public application table"
assert_log_contains "bucardo add table public.partman_events_p20260101 db=heroku relgroup=planetscale_import" "Bucardo includes partition leaf tables"
assert_log_absent "bucardo add table public.partman_events db=heroku relgroup=planetscale_import" "Bucardo excludes partitioned parent table"
assert_log_absent "bucardo add table public.part_config" "Bucardo excludes pg_partman config table"
assert_log_absent "bucardo add table public.template_public_partman_events" "Bucardo excludes pg_partman template table"
assert_log_contains "bucardo add sync planetscale_import dbs=heroku,planetscale onetimecopy=1 checktime=5 relgroup=planetscale_import" "Bucardo sync has periodic checktime fallback"
assert_log_contains "bucardo add customcols public.posts SELECT id, title db=planetscale" "Generated-column customcols still run for public tables"
assert_log_contains "bucardo add customcols app_private.docs SELECT id, title db=planetscale" "Generated-column customcols still run for non-public tables"

if [ "$FAIL" -gt 0 ]; then
  printf "\nCommand log:\n" >&2
  sed 's/^/  /' "$LOG_FILE" >&2
  printf "\n%d passed, %d failed\n" "$PASS" "$FAIL" >&2
  exit 1
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
