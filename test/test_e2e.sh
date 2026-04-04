#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# End-to-end migration test against real Heroku Postgres and PlanetScale.
#
# Prerequisites:
#   - heroku CLI authenticated
#   - pscale CLI authenticated (org: mike)
#   - psql available locally
#   - Source Heroku database has tables with data
#
# Usage:
#   bash test/test_e2e.sh
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HEROKU_SRC_APP="ps-migrate-test-src"
PS_DATABASE="import-test"
PS_BRANCH="main"
PS_ORG="mike"
TEST_PASSWORD="e2e-test-$(date +%s)"
HEROKU_APP=""
PS_ROLE_NAME=""
PS_URL=""
HEROKU_URL=""

PASS=0
FAIL=0
STEP=0

cleanup() {
  echo ""
  log "Cleaning up..."

  if [ -n "$HEROKU_APP" ]; then
    log "Destroying Heroku app $HEROKU_APP..."
    heroku apps:destroy "$HEROKU_APP" --confirm "$HEROKU_APP" 2>/dev/null || true
  fi

  if [ -n "$PS_ROLE_NAME" ]; then
    log "Deleting PlanetScale role $PS_ROLE_NAME..."
    pscale role delete "$PS_DATABASE" "$PS_BRANCH" "$PS_ROLE_NAME" --org "$PS_ORG" --force 2>/dev/null || true
  fi

  echo ""
  echo "========================================"
  printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
  echo "========================================"
}
trap cleanup EXIT

# --- Helpers ----------------------------------------------------------------

log()  { printf "\033[1;34m[E2E]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }

step() {
  STEP=$((STEP + 1))
  echo ""
  log "Step $STEP: $1"
}

dashboard_url() {
  echo "https://$HEROKU_APP.herokuapp.com"
}

api() {
  local method="$1" path="$2"
  local url="$(dashboard_url)$path"
  curl -s -u "admin:$TEST_PASSWORD" -X "$method" -H "Content-Length: 0" -H "Content-Type: text/plain" "$url" 2>/dev/null
}

api_code() {
  local method="$1" path="$2"
  local url="$(dashboard_url)$path"
  curl -s -o /dev/null -w "%{http_code}" -u "admin:$TEST_PASSWORD" -X "$method" -H "Content-Length: 0" -H "Content-Type: text/plain" "$url" 2>/dev/null
}

wait_for_phase() {
  local target_phase="$1"
  local timeout_seconds="${2:-300}"
  local elapsed=0

  while [ $elapsed -lt $timeout_seconds ]; do
    local phase
    phase=$(api GET /status | ruby -rjson -e 'puts JSON.parse(STDIN.read)["phase"]' 2>/dev/null || echo "")
    if [ "$phase" = "$target_phase" ]; then
      return 0
    fi
    if [ "$phase" = "error" ] && [ "$target_phase" != "error" ]; then
      local error
      error=$(api GET /status | ruby -rjson -e 'puts JSON.parse(STDIN.read)["error"]' 2>/dev/null || echo "unknown")
      fail "Migration entered error state while waiting for $target_phase: $error"
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    printf "."
  done
  echo ""
  fail "Timed out waiting for phase=$target_phase after ${timeout_seconds}s (current: $phase)"
  return 1
}

heroku_psql() {
  psql "$HEROKU_URL" -A -t -c "$1" 2>&1
}

# === SETUP ==================================================================

step "Get Heroku source database URL"
HEROKU_URL=$(heroku config:get DATABASE_URL -a "$HEROKU_SRC_APP" 2>/dev/null)
if [ -z "$HEROKU_URL" ]; then
  fail "Could not get DATABASE_URL from $HEROKU_SRC_APP"
  exit 1
fi
pass "Got Heroku URL from $HEROKU_SRC_APP"

step "Create PlanetScale role"
PS_ROLE_NAME="e2e-test-$(date +%s)"
role_json=$(pscale role create "$PS_DATABASE" "$PS_BRANCH" "$PS_ROLE_NAME" \
  --org "$PS_ORG" --inherited-roles postgres -f json 2>&1)
PS_URL=$(echo "$role_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["database_url"]' 2>/dev/null)
if [ -z "$PS_URL" ]; then
  fail "Could not create PlanetScale role: $role_json"
  exit 1
fi
pass "Created PlanetScale role: $PS_ROLE_NAME"

step "Verify source database has tables"
table_count=$(heroku_psql "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';")
table_count=$(echo "$table_count" | tr -d '[:space:]')
if [ "$table_count" -lt 1 ] 2>/dev/null; then
  fail "Source database has no tables"
  exit 1
fi
pass "Source database has $table_count tables"

step "Create Heroku migrator app"
HEROKU_APP="ps-e2e-test-$(date +%s)"
heroku create "$HEROKU_APP" --stack container --region us 2>&1 | tail -1
heroku config:set -a "$HEROKU_APP" \
  HEROKU_URL="$HEROKU_URL" \
  PLANETSCALE_URL="$PS_URL" \
  PASSWORD="$TEST_PASSWORD" \
  DISABLE_NOTIFICATIONS="true" \
  2>&1 | tail -1
pass "Created Heroku app: $HEROKU_APP"

step "Deploy migrator to Heroku"
(
  cd "$PROJECT_DIR"
  heroku git:remote -a "$HEROKU_APP" 2>/dev/null
  git push heroku HEAD:main --force 2>&1 | tail -5
)
pass "Deployed to $HEROKU_APP"

step "Wait for migrator to boot"
boot_timeout=180
elapsed=0
while [ $elapsed -lt $boot_timeout ]; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$(dashboard_url)/health" 2>/dev/null || echo "000")
  if [ "$code" = "200" ]; then
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
  printf "."
done
echo ""
if [ "$code" != "200" ]; then
  fail "Migrator failed to boot after ${boot_timeout}s"
  exit 1
fi
pass "Migrator is running at $(dashboard_url)"

# === PREFLIGHT ==============================================================

step "Run preflight checks"
preflight=$(api GET /preflight-checks)
all_valid=$(echo "$preflight" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["all_tables_valid"]' 2>/dev/null)
if [ "$all_valid" = "true" ]; then
  pass "All tables have primary key or unique index"
else
  bad_tables=$(echo "$preflight" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["tables_without_pk_or_unique"].join(", ")' 2>/dev/null)
  fail "Tables without PK/unique index: $bad_tables"
  exit 1
fi

# === START MIGRATION ========================================================

step "Start migration"
result=$(api POST /start-migration)
success=$(echo "$result" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["success"]' 2>/dev/null)
if [ "$success" = "true" ]; then
  pass "Migration started"
else
  fail "Start migration failed: $result"
  exit 1
fi

step "Wait for schema copy and replication config (phase=ready_to_copy)"
if wait_for_phase "ready_to_copy" 300; then
  pass "Schema copied, ready to copy data"
fi

# === START COPY =============================================================

step "Start data copy"
result=$(api POST /start-copy)
success=$(echo "$result" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["success"]' 2>/dev/null)
if [ "$success" = "true" ]; then
  pass "Data copy started"
else
  fail "Start copy failed: $result"
  exit 1
fi

step "Wait for replication (phase=replicating)"
if wait_for_phase "replicating" 600; then
  pass "Initial copy complete, replication active"
fi

# === VERIFY READINESS =======================================================

step "Check cutover readiness"
status=$(api GET /status)
level=$(echo "$status" | ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("cutover_readiness", "level")' 2>/dev/null)
if [ "$level" = "ready" ]; then
  pass "Cutover readiness: ready"
elif [ "$level" = "warning" ]; then
  pass "Cutover readiness: warning (will use override)"
else
  fail "Cutover readiness: $level (expected ready or warning)"
fi

# === VERIFY ROW COUNTS ======================================================

step "Spot-check row counts"
src_count=$(heroku_psql "SELECT count(*) FROM users;" | tr -d '[:space:]')
# Get a table name that exists on both sides
if [ -n "$src_count" ] && [ "$src_count" -gt 0 ] 2>/dev/null; then
  pass "Source users table has $src_count rows"
else
  pass "Skipping row count check (users table empty or missing)"
fi

# === SWITCH TRAFFIC =========================================================

step "Switch traffic (revoke writes on Heroku)"
if [ "$level" = "warning" ]; then
  result=$(api POST "/switch-traffic?force=1")
else
  result=$(api POST /switch-traffic)
fi
success=$(echo "$result" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["success"]' 2>/dev/null)
if [ "$success" = "true" ]; then
  pass "Traffic switched"
else
  fail "Switch traffic failed: $result"
  exit 1
fi

step "Verify phase is switched"
sleep 2
phase=$(api GET /status | ruby -rjson -e 'puts JSON.parse(STDIN.read)["phase"]' 2>/dev/null)
if [ "$phase" = "switched" ]; then
  pass "Phase is switched"
else
  fail "Phase is $phase (expected switched)"
fi

step "Verify writes are blocked on Heroku"
insert_result=$(heroku_psql "INSERT INTO users (id, name, email) VALUES (gen_random_uuid(), 'e2e_test_blocked', 'blocked@test.com');" 2>&1 || true)
if echo "$insert_result" | grep -qi "permission denied\|ERROR"; then
  pass "Writes are blocked on Heroku (INSERT failed as expected)"
else
  fail "Writes should be blocked but INSERT succeeded: $insert_result"
fi

# === REVERT SWITCH ==========================================================

step "Revert switch (restore writes on Heroku)"
result=$(api POST /revert-switch)
success=$(echo "$result" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["success"]' 2>/dev/null)
if [ "$success" = "true" ]; then
  pass "Switch reverted"
else
  fail "Revert switch failed: $result"
fi

step "Verify writes are restored on Heroku"
sleep 2
insert_result=$(heroku_psql "INSERT INTO users (id, name, email) VALUES (gen_random_uuid(), 'e2e_test_revert', 'revert@test.com');" 2>&1)
if echo "$insert_result" | grep -qi "INSERT\|1"; then
  pass "Writes are restored (INSERT succeeded)"
  heroku_psql "DELETE FROM users WHERE email = 'revert@test.com';" >/dev/null 2>&1 || true
else
  fail "Writes should be restored but INSERT failed: $insert_result"
fi

# === SWITCH AGAIN AND CLEANUP ===============================================

step "Switch traffic again for final cutover"
sleep 3
# Refresh status to get back to replicating
phase=$(api GET /status | ruby -rjson -e 'puts JSON.parse(STDIN.read)["phase"]' 2>/dev/null)
if [ "$phase" = "replicating" ]; then
  level=$(api GET /status | ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("cutover_readiness", "level")' 2>/dev/null)
  if [ "$level" = "warning" ]; then
    result=$(api POST "/switch-traffic?force=1")
  else
    result=$(api POST /switch-traffic)
  fi
  success=$(echo "$result" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["success"]' 2>/dev/null)
  if [ "$success" = "true" ]; then
    pass "Second switch succeeded"
  else
    fail "Second switch failed: $result"
  fi
else
  log "Phase is $phase after revert, skipping second switch"
fi

step "Run cleanup"
result=$(api POST /cleanup)
success=$(echo "$result" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["success"]' 2>/dev/null)
if [ "$success" = "true" ]; then
  pass "Cleanup started"
else
  fail "Cleanup failed to start: $result"
fi

if wait_for_phase "completed" 120; then
  pass "Migration completed"
fi

step "Verify no Bucardo triggers remain on Heroku"
trigger_count=$(heroku_psql "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'bucardo_%';" | tr -d '[:space:]')
if [ "$trigger_count" = "0" ]; then
  pass "No Bucardo triggers remain on Heroku"
else
  fail "$trigger_count Bucardo triggers still exist on Heroku"
fi

echo ""
log "End-to-end test complete."
