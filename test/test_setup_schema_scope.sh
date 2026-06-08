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
echo "CREATE SCHEMA public;"
echo "CREATE TABLE public.accounts (id bigint PRIMARY KEY);"
echo "CREATE SCHEMA analytics;"
echo "CREATE TABLE analytics.events (id bigint PRIMARY KEY);"
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
  *"SELECT DISTINCT n.nspname, c.relname"*)
    echo "public|accounts"
    echo "analytics|events"
    ;;
  *"string_agg(quote_ident(attname)"*)
    echo "id, name"
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

cat > "$FAKE_BIN_DIR/awk" <<'SH'
#!/bin/sh
exec /usr/bin/awk "$@"
SH
chmod +x "$FAKE_BIN_DIR/awk"

export COMMAND_LOG="$LOG_FILE"
export PATH="$FAKE_BIN_DIR:$PATH"
export MIGRATION_SCHEMAS=" public, analytics, partman, public "
export MIGRATION_EXCLUDE_SCHEMAS=" partman, pg_partman "

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

assert_log_contains "--schema=public --schema=analytics" "pg_dump is constrained to included schemas"
assert_log_absent "--schema=partman" "pg_dump excludes partman schema"
assert_log_contains "CREATE SCHEMA IF NOT EXISTS public;" "public schema restore is idempotent"
assert_log_absent "CREATE SCHEMA public;" "public schema restore does not fail on default target schema"
assert_log_contains "CREATE SCHEMA analytics;" "non-public schemas are still created normally"
assert_log_contains "bucardo add all tables db=heroku -n public relgroup=planetscale_import" "Bucardo add all tables is used for public"
assert_log_contains "bucardo add all tables db=heroku -n analytics relgroup=planetscale_import" "Bucardo add all tables is used for analytics"
assert_log_contains "bucardo add all sequences db=heroku -n public relgroup=planetscale_import" "Bucardo add all sequences is schema filtered"
assert_log_contains "bucardo set tcp_keepalives_idle=60" "Bucardo TCP keepalive idle setting is configured"
assert_log_contains "bucardo set tcp_keepalives_interval=10" "Bucardo TCP keepalive interval setting is configured"
assert_log_contains "bucardo set tcp_keepalives_count=6" "Bucardo TCP keepalive count setting is configured"

if grep -R "MIGRATION_EXCLUDE_TABLES\|exclude table\|exclude_tables" "$PROJECT_DIR/scripts/mk-bucardo-repl.sh" >/dev/null; then
  fail "setup script contains table-level exclude logic"
else
  pass "setup script has no table-level exclude logic"
fi

if [ "$FAIL" -gt 0 ]; then
  printf "\n%d passed, %d failed\n" "$PASS" "$FAIL" >&2
  exit 1
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
