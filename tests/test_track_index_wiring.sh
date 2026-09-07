#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# test_track_index_wiring.sh -- where add-track-indexes.sh runs during setup.
#
# The fix depends entirely on its position: after `bucardo add sync`, which
# creates the track tables, and before `bucardo reload`, which starts the sync
# and lets them fill. This pins that ordering, that the primary is indexed
# rather than the replica, and that a failure stops setup.
#
# Stubs bucardo, psql, pg_dump and the sibling scripts, so it needs no database
# and no Bucardo installation.
#
# Usage: bash tests/test_track_index_wiring.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
log()  { printf "\033[1;34m[WIRING]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1 (= $2)"; else fail "$1 -- expected [$2] got [$3]"; fi; }

PRIMARY="postgres://srcuser:srcpass@source-host:5432/source_db"
REPLICA="postgres://tgtuser:tgtpass@target-host:5432/target_db"

WORK=""; RC=0; LOG=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# Builds a sandbox with stubbed binaries and sibling scripts, then runs
# mk-bucardo-repl.sh. $1 = exit code for the fake add-track-indexes.sh,
# remaining args are passed through to mk-bucardo-repl.sh.
run_mk() {
  local idx_rc="$1"; shift
  WORK="$(mktemp -d)"
  local bin="$WORK/bin" scripts="$WORK/scripts"
  mkdir -p "$bin" "$scripts"
  LOG="$WORK/call_log"
  : > "$LOG"

  cp "$PROJECT_DIR/scripts/mk-bucardo-repl.sh" "$scripts/"
  # Sibling scripts are stubbed; only their invocation matters here.
  printf '#!/bin/sh\nprintf "drop-secondary-indexes %%s\\n" "$*" >> "%s"\nexit 0\n' "$LOG" \
    > "$scripts/drop-secondary-indexes.sh"
  printf '#!/bin/sh\nprintf "stat-bucardo-repl %%s\\n" "$*" >> "%s"\nexit 0\n' "$LOG" \
    > "$scripts/stat-bucardo-repl.sh"
  printf '#!/bin/sh\nprintf "add-track-indexes %%s\\n" "$*" >> "%s"\nexit %s\n' "$LOG" "$idx_rc" \
    > "$scripts/add-track-indexes.sh"

  printf '#!/bin/sh\nprintf "bucardo %%s\\n" "$*" >> "%s"\nexit 0\n' "$LOG" > "$bin/bucardo"

  # psql stub: answers the replica version probe, swallows the schema restore,
  # returns no generated-column tables, logs nothing else.
  cat > "$bin/psql" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    "SHOW server_version_num;") echo "170000"; exit 0;;
  esac
done
cat >/dev/null 2>&1
exit 0
EOF
  printf '#!/bin/sh\necho "-- fake schema dump"\nexit 0\n' > "$bin/pg_dump"
  chmod +x "$bin"/* "$scripts"/*

  PATH="$bin:$PATH" sh "$scripts/mk-bucardo-repl.sh" \
    --primary "$PRIMARY" --replica "$REPLICA" "$@" >"$WORK/out.log" 2>&1
  RC=$?
}

line_of() { grep -n "$1" "$LOG" | head -1 | cut -d: -f1; }

echo ""
log "Scenario 1: ordering on a normal setup run"
run_mk 0
assert_eq "mk-bucardo-repl.sh exit code" "0" "$RC"

idx="$(line_of '^add-track-indexes')"
add="$(line_of '^bucardo add sync')"
rel="$(line_of '^bucardo reload')"

if [ -n "$idx" ]; then
  pass "add-track-indexes.sh was invoked"
else
  fail "add-track-indexes.sh was never invoked. Call log: $(tr '\n' '|' < "$LOG")"
fi
if [ -n "$idx" ] && [ -n "$add" ] && [ "$add" -lt "$idx" ]; then
  pass "runs AFTER 'bucardo add sync' (track tables exist by then)"
else
  fail "does not run after 'bucardo add sync' (add=$add idx=$idx)"
fi
if [ -n "$idx" ] && [ -n "$rel" ] && [ "$idx" -lt "$rel" ]; then
  pass "runs BEFORE 'bucardo reload' (track tables still empty)"
else
  fail "does not run before 'bucardo reload' (idx=$idx reload=$rel)"
fi

# Indexing the target instead of the source would be a silent no-op that only
# shows up as a stalled migration hours later.
if grep '^add-track-indexes' "$LOG" | grep -q "source-host"; then
  pass "invoked with the PRIMARY (source) conninfo"
else
  fail "not invoked with the primary conninfo: $(grep '^add-track-indexes' "$LOG")"
fi
if grep '^add-track-indexes' "$LOG" | grep -q "target-host"; then
  fail "invoked with the REPLICA conninfo -- would index the wrong database"
else
  pass "not invoked with the replica conninfo"
fi

log "Scenario 2: fail closed when the index step fails"
run_mk 3
[ "$RC" -ne 0 ] && pass "index-step failure aborts setup (rc=$RC)" \
  || fail "index-step failure did not abort setup (rc=$RC)"
assert_eq "'bucardo reload' never runs, so the sync never starts" "0" \
  "$(grep -c '^bucardo reload' "$LOG")"
assert_eq "the index step is where it stopped" "1" \
  "$(grep -c '^add-track-indexes' "$LOG")"

log "Scenario 3: resume path (--skip-schema)"
run_mk 0 --skip-schema
assert_eq "exit code" "0" "$RC"
assert_eq "still runs on the resume path" "1" "$(grep -c '^add-track-indexes' "$LOG")"
assert_eq "schema copy skipped (no pg_dump restore)" "0" "$(grep -c '^drop-secondary-indexes' "$LOG")"

log "Scenario 4: delta-only path (--skip-schema --no-initial-copy)"
run_mk 0 --skip-schema --no-initial-copy
assert_eq "exit code" "0" "$RC"
assert_eq "still runs when the initial copy is skipped" "1" "$(grep -c '^add-track-indexes' "$LOG")"
idx="$(line_of '^add-track-indexes')"; rel="$(line_of '^bucardo reload')"
if [ -n "$idx" ] && [ -n "$rel" ] && [ "$idx" -lt "$rel" ]; then
  pass "ordering holds on the delta-only path too"
else
  fail "ordering broken on delta-only path (idx=$idx reload=$rel)"
fi

echo ""
echo "========================================"
printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ]
