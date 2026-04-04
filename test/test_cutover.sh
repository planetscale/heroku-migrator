#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Local mock test for cutover readiness logic.
# Starts the status server with a fake bucardo binary and temp state dir,
# then exercises all readiness scenarios via curl.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_PORT="${TEST_PORT:-9876}"
TEST_STATE_DIR="$(mktemp -d)"
FAKE_BIN_DIR="$(mktemp -d)"
FAKE_BUCARDO_OUTPUT="$TEST_STATE_DIR/bucardo_output.txt"

PASS=0
FAIL=0
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_STATE_DIR" "$FAKE_BIN_DIR"
}
trap cleanup EXIT

# --- Helpers ----------------------------------------------------------------

log()  { printf "\033[1;34m[TEST]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }

write_status() {
  cat > "$TEST_STATE_DIR/status.json"
}

write_bucardo_output() {
  cat > "$FAKE_BUCARDO_OUTPUT"
}

# $1=method $2=path $3=expected_http_code $4=optional body grep pattern
http_check() {
  local method="$1" path="$2" expect_code="$3" expect_body="${4:-}"
  local url="http://127.0.0.1:$TEST_PORT$path"
  local response code body
  response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" 2>/dev/null)
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$code" != "$expect_code" ]; then
    fail "$method $path → HTTP $code (expected $expect_code)"
    printf "    response: %s\n" "$body"
    return 1
  fi

  if [ -n "$expect_body" ]; then
    if echo "$body" | grep -q "$expect_body"; then
      pass "$method $path → HTTP $code, body contains '$expect_body'"
    else
      fail "$method $path → HTTP $code but body missing '$expect_body'"
      printf "    response: %s\n" "$body"
      return 1
    fi
  else
    pass "$method $path → HTTP $code"
  fi
  return 0
}

# Extract a JSON field (shallow, for simple checks)
json_field() {
  local body="$1" field="$2"
  echo "$body" | ruby -rjson -e "puts JSON.parse(STDIN.read).dig(*ARGV.map{|a| a =~ /\A\d+\z/ ? a.to_i : a})" "$field" 2>/dev/null
}

get_status_field() {
  local field="$1"
  local body
  body=$(curl -s "http://127.0.0.1:$TEST_PORT/status" 2>/dev/null)
  echo "$body" | ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    keys = ARGV[0].split(".")
    val = keys.reduce(data) { |d, k| d.is_a?(Hash) ? d[k] : nil }
    puts val.to_s
  ' "$field" 2>/dev/null
}

now_iso() {
  ruby -e "puts Time.now.utc.strftime('%b %d, %Y %H:%M:%S')"
}

# --- Create fake bucardo binary --------------------------------------------

cat > "$FAKE_BIN_DIR/bucardo" << 'FAKE_BUCARDO'
#!/bin/sh
if [ -f "$FAKE_BUCARDO_OUTPUT" ]; then
  cat "$FAKE_BUCARDO_OUTPUT"
else
  echo ""
fi
FAKE_BUCARDO
chmod +x "$FAKE_BIN_DIR/bucardo"

# Also create fake psql that always fails (for switch-traffic REVOKE)
cat > "$FAKE_BIN_DIR/psql" << 'FAKE_PSQL'
#!/bin/sh
echo "fake psql: $*" >&2
exit 1
FAKE_PSQL
chmod +x "$FAKE_BIN_DIR/psql"

# --- Start the server -------------------------------------------------------

log "Starting test server on port $TEST_PORT..."

export TEST_STATE_DIR
export FAKE_BUCARDO_OUTPUT
export PORT="$TEST_PORT"
export PASSWORD="test"
export DISABLE_AUTH="true"
export DISABLE_NOTIFICATIONS="true"
export HEROKU_URL="postgres://fakeuser:fakepass@localhost:5432/fakedb"
export PLANETSCALE_URL=""
export PATH="$FAKE_BIN_DIR:$PATH"

ruby "$SCRIPT_DIR/test_server_wrapper.rb" &
SERVER_PID=$!

# Wait for server to be ready
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:$TEST_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if ! curl -s "http://127.0.0.1:$TEST_PORT/health" >/dev/null 2>&1; then
  echo "ERROR: Server failed to start"
  exit 1
fi

log "Server running (PID $SERVER_PID)"
echo ""

# === SCENARIO 1: Cutover blocked (initial copy not finished) ================

log "Scenario 1: Cutover blocked - initial copy not finished"

write_status << 'EOF'
{"phase":"replicating","state":"running","message":"Replicating","error":null,"started_at":"2026-01-01T00:00:00Z"}
EOF

RECENT_TIME=$(now_iso)
write_bucardo_output << EOF
======================================================================
Sync name                : planetscale_import
Current state            : Good
Source relgroup/database : planetscale_import / heroku
Tables in sync           : 10
Status                   : Active
Onetimecopy              : Yes
Last good                : $RECENT_TIME (time to run: 2s)
Last error:              :
======================================================================
EOF

http_check POST /switch-traffic 409 "cutover_blocked"

# === SCENARIO 2: Cutover warning (replication_not_healthy) ==================

log "Scenario 2: Cutover warning - stale error, no recent good sync"

write_status << 'EOF'
{"phase":"replicating","state":"running","message":"Replicating","error":null,"started_at":"2026-01-01T00:00:00Z"}
EOF

write_bucardo_output << 'EOF'
======================================================================
Sync name                : planetscale_import
Current state            : Good
Source relgroup/database : planetscale_import / heroku
Tables in sync           : 10
Status                   : Active
Onetimecopy              : No
Last good                : Jan 01, 2025 00:00:00 (time to run: 2s)
Last error:              : Ended (CTL 999)
======================================================================
EOF

http_check POST /switch-traffic 409 "cutover_override_required"

# === SCENARIO 3: Cutover warning with force override ========================

log "Scenario 3: Cutover warning with force override"

# Status and bucardo output same as scenario 2 (already set)

# force=1 should pass the readiness gate. The REVOKE will fail (fake psql)
# but we verify it doesn't return cutover_blocked or cutover_override_required.
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Length: 0" -H "Content-Type: text/plain" "http://127.0.0.1:$TEST_PORT/switch-traffic?force=1" 2>/dev/null)
code=$(echo "$response" | tail -1)
body=$(echo "$response" | sed '$d')

if echo "$body" | grep -q "cutover_blocked\|cutover_override_required"; then
  fail "POST /switch-traffic?force=1 still blocked by readiness"
  printf "    response: %s\n" "$body"
else
  pass "POST /switch-traffic?force=1 → HTTP $code, passed readiness gate"
fi

# Reset status back to replicating for next scenario
write_status << 'EOF'
{"phase":"replicating","state":"running","message":"Replicating","error":null,"started_at":"2026-01-01T00:00:00Z"}
EOF

# === SCENARIO 4: Cutover ready (no errors) ==================================

log "Scenario 4: Cutover ready - clean state"

RECENT_TIME=$(now_iso)
write_bucardo_output << EOF
======================================================================
Sync name                : planetscale_import
Current state            : Good
Source relgroup/database : planetscale_import / heroku
Tables in sync           : 10
Status                   : Active
Onetimecopy              : No
Last good                : $RECENT_TIME (time to run: 2s)
Last error:              :
======================================================================
EOF

level=$(get_status_field "cutover_readiness.level")
if [ "$level" = "ready" ]; then
  pass "GET /status → cutover_readiness.level=ready"
else
  fail "GET /status → cutover_readiness.level=$level (expected ready)"
fi

# === SCENARIO 5: Stale error with recent good sync ==========================

log "Scenario 5: Stale error with recent good sync → should be ready"

RECENT_TIME=$(now_iso)
write_bucardo_output << EOF
======================================================================
Sync name                : planetscale_import
Current state            : Good
Source relgroup/database : planetscale_import / heroku
Tables in sync           : 10
Status                   : Active
Onetimecopy              : No
Last good                : $RECENT_TIME (time to run: 2s)
Last error:              : Ended (CTL 14640)
======================================================================
EOF

level=$(get_status_field "cutover_readiness.level")
if [ "$level" = "ready" ]; then
  pass "GET /status → cutover_readiness.level=ready (stale error ignored)"
else
  fail "GET /status → cutover_readiness.level=$level (expected ready, stale error should be ignored)"
fi

# === SCENARIO 6: Unknown current_state with recent good sync ================

log "Scenario 6: Unknown current_state with recent good sync → should be ready"

RECENT_TIME=$(now_iso)
write_bucardo_output << EOF
======================================================================
Sync name                : planetscale_import
Current state            : Syncing
Source relgroup/database : planetscale_import / heroku
Tables in sync           : 10
Status                   : Active
Onetimecopy              : No
Last good                : $RECENT_TIME (time to run: 2s)
Last error:              :
======================================================================
EOF

level=$(get_status_field "cutover_readiness.level")
if [ "$level" = "ready" ]; then
  pass "GET /status → cutover_readiness.level=ready (unknown state overridden by recent sync)"
else
  fail "GET /status → cutover_readiness.level=$level (expected ready)"
fi

# === SCENARIO 7: Retry from error ===========================================

log "Scenario 7: Retry from error state"

write_status << 'EOF'
{"phase":"error","state":"setup_failed","message":"Setup failed","error":"something broke","started_at":"2026-01-01T00:00:00Z"}
EOF

http_check POST /retry 200 '"success":true'

# Verify phase reset to waiting
sleep 0.5
level=$(get_status_field "phase")
if [ "$level" = "waiting" ]; then
  pass "After retry, phase=waiting"
else
  fail "After retry, phase=$level (expected waiting)"
fi

# === SCENARIO 8: Retry blocked from non-error phase =========================

log "Scenario 8: Retry blocked from non-error phase"

write_status << 'EOF'
{"phase":"replicating","state":"running","message":"Replicating","error":null,"started_at":"2026-01-01T00:00:00Z"}
EOF

http_check POST /retry 409

# === Summary ================================================================

echo ""
echo "========================================"
printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
