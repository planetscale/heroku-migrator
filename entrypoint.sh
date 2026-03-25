#!/usr/bin/env bash
set -e

echo "=== Bucardo Migration Runner ==="
echo "Started at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Validate required env vars
if [ -z "$HEROKU_URL" ]; then
  echo "ERROR: HEROKU_URL environment variable is required"
  exit 1
fi

if [ -z "$PLANETSCALE_URL" ]; then
  echo "ERROR: PLANETSCALE_URL environment variable is required"
  exit 1
fi

if [ -z "$PASSWORD" ]; then
  echo "ERROR: PASSWORD environment variable is required"
  exit 1
fi

# Default source TLS behavior too (Heroku URL), for consistency and to avoid
# certificate-mode mismatches when sslmode is omitted.
if [[ "$HEROKU_URL" != *"sslmode="* ]]; then
  if [[ "$HEROKU_URL" == *"?"* ]]; then
    HEROKU_URL="${HEROKU_URL}&sslmode=require"
  else
    HEROKU_URL="${HEROKU_URL}?sslmode=require"
  fi
  export HEROKU_URL
  echo "HEROKU_URL missing sslmode; defaulting to sslmode=require"
fi

# Default PlanetScale TLS behavior so operators do not need to tweak URL params.
# - If sslmode is missing, default to sslmode=require.
# - If strict verification is requested, use the system CA bundle automatically.
if [[ "$PLANETSCALE_URL" != *"sslmode="* ]]; then
  if [[ "$PLANETSCALE_URL" == *"?"* ]]; then
    PLANETSCALE_URL="${PLANETSCALE_URL}&sslmode=require"
  else
    PLANETSCALE_URL="${PLANETSCALE_URL}?sslmode=require"
  fi
  export PLANETSCALE_URL
  echo "PLANETSCALE_URL missing sslmode; defaulting to sslmode=require"
fi

if [[ "$PLANETSCALE_URL" == *"sslmode=verify-full"* || "$PLANETSCALE_URL" == *"sslmode=verify-ca"* ]]; then
  if [[ "$PLANETSCALE_URL" != *"sslrootcert="* ]]; then
    if [[ "$PLANETSCALE_URL" == *"?"* ]]; then
      PLANETSCALE_URL="${PLANETSCALE_URL}&sslrootcert=system"
    else
      PLANETSCALE_URL="${PLANETSCALE_URL}?sslrootcert=system"
    fi
    export PLANETSCALE_URL
    echo "PLANETSCALE_URL strict sslmode detected; defaulting sslrootcert=system"
  fi
fi

PGDATA="/opt/bucardo/pgdata"
PGPORT=5432
PGSOCKET="/tmp"

# Heroku runs containers as a random non-root UID that may not exist in
# /etc/passwd. PostgreSQL and Bucardo require a valid user entry, so we
# add one at runtime if missing.
if ! whoami &>/dev/null; then
  echo "heroku:x:$(id -u):0:Heroku User:/opt/bucardo:/bin/bash" >> /etc/passwd
fi
export HOME="/opt/bucardo"

# ---------------------------------------------------------------------------
# Check PlanetScale for existing migration state (survives dyno restarts)
# ---------------------------------------------------------------------------
echo "Checking for existing migration state..."
PERSISTED_PHASE=""
PERSISTED_STARTED=""
PERSISTED_SWITCHED=""
PERSISTED_COMPLETED=""

STATE_ROW=$(psql "$PLANETSCALE_URL" -A -t -c "SELECT phase, started_at, switched_at, completed_at FROM _ps_migration_state WHERE id = 1" 2>/dev/null || echo "")
if [ -n "$STATE_ROW" ]; then
  PERSISTED_PHASE=$(echo "$STATE_ROW" | cut -d'|' -f1)
  PERSISTED_STARTED=$(echo "$STATE_ROW" | cut -d'|' -f2)
  PERSISTED_SWITCHED=$(echo "$STATE_ROW" | cut -d'|' -f3)
  PERSISTED_COMPLETED=$(echo "$STATE_ROW" | cut -d'|' -f4)
  echo "Found existing migration state: phase=$PERSISTED_PHASE"
fi

# ---------------------------------------------------------------------------
# Write initial local status based on persisted state
# ---------------------------------------------------------------------------
mkdir -p /opt/bucardo/state

case "$PERSISTED_PHASE" in
  "switched")
    echo "Migration was in 'switched' phase. Writes are blocked on Heroku. Starting dashboard only."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"switched","state":"writes_revoked","message":"Write access revoked on Heroku. Update your app to use PlanetScale.","error":null,"started_at":"${PERSISTED_STARTED}","switched_at":"${PERSISTED_SWITCHED}"}
EOF
    ;;
  "completed")
    echo "Migration is already complete. Starting dashboard only."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"completed","state":"cleanup_complete","message":"Migration complete. Bucardo replication removed.","error":null,"started_at":"${PERSISTED_STARTED}","completed_at":"${PERSISTED_COMPLETED}"}
EOF
    ;;
  "cleaning_up")
    echo "Migration was cleaning up. Showing status. You may need to re-run cleanup."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"switched","state":"writes_revoked","message":"Dyno restarted during cleanup. You can re-run Complete Migration from the dashboard.","error":null,"started_at":"${PERSISTED_STARTED}","switched_at":"${PERSISTED_SWITCHED}"}
EOF
    ;;
  "error")
    echo "Migration was in error state. Starting dashboard for diagnostics."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"error","state":"setup_failed","message":"Migration encountered an error. Check logs for details.","error":null,"started_at":"${PERSISTED_STARTED}"}
EOF
    ;;
  "ready_to_copy")
    echo "Migration schema was copied. Waiting for user to start data copy."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"ready_to_copy","state":"schema_copied","message":"Schema and replication configured. Ready to start data copy.","error":null,"started_at":"${PERSISTED_STARTED}"}
EOF
    ;;
  "copying"|"replicating"|"configuring"|"starting")
    echo "Migration was in '$PERSISTED_PHASE' phase. Will resume replication."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"starting","state":"resuming","message":"Resuming migration after restart...","error":null,"started_at":"${PERSISTED_STARTED}"}
EOF
    ;;
  *)
    echo "No existing migration found. Waiting for user to start migration."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"waiting","state":"ready","message":"Ready to start migration. Click Start Migration to begin.","error":null,"started_at":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"}
EOF
    ;;
esac

# ---------------------------------------------------------------------------
# Start the status HTTP server immediately so Heroku sees the port bound
# ---------------------------------------------------------------------------
echo "Starting status server on port ${PORT:-8080}..."
ruby /opt/bucardo/status-server/server.rb &
STATUS_SERVER_PID=$!

# ---------------------------------------------------------------------------
# Start PostgreSQL and Bucardo infrastructure (needed for all active states)
# ---------------------------------------------------------------------------
if [ "$PERSISTED_PHASE" != "completed" ]; then
  # Initialize PostgreSQL at runtime
  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "Initializing PostgreSQL data directory..."
    initdb -D "$PGDATA" --auth=trust --no-locale -U "$(whoami 2>/dev/null || echo pg)"
  fi

  echo "Starting PostgreSQL..."
  pg_ctl -D "$PGDATA" -l "$PGDATA/pg.log" -o "-p $PGPORT -k $PGSOCKET" start -w

  CURRENT_USER="$(whoami 2>/dev/null || echo pg)"

  if ! psql -h "$PGSOCKET" -p "$PGPORT" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'bucardo'" | grep -q 1; then
    echo "Creating bucardo database..."
    createdb -h "$PGSOCKET" -p "$PGPORT" bucardo
  fi

  cat > /etc/bucardorc <<RCEOF
piddir = /var/run/bucardo
log_conflict_file = /var/log/bucardo/log.bucardo.conflict
dbhost = $PGSOCKET
dbport = $PGPORT
dbname = bucardo
dbuser = $CURRENT_USER
RCEOF

  echo "Installing Bucardo..."
  echo "p" | bucardo install \
    --db-name bucardo \
    --db-user "$CURRENT_USER" \
    --db-host "$PGSOCKET" \
    --db-port "$PGPORT" \
    --verbose 2>/dev/null || true

  echo "Starting Bucardo daemon..."
  bucardo start || bucardo restart
fi

# ---------------------------------------------------------------------------
# Resume replication if migration was in progress before restart
# ---------------------------------------------------------------------------
if [ "$PERSISTED_PHASE" = "copying" ] || [ "$PERSISTED_PHASE" = "replicating" ] || [ "$PERSISTED_PHASE" = "configuring" ] || [ "$PERSISTED_PHASE" = "starting" ]; then
  echo "Resuming replication setup after restart..."

  cat > /opt/bucardo/state/status.json <<EOF
{"phase":"configuring","state":"resuming","message":"Resuming replication after restart...","error":null,"started_at":"${PERSISTED_STARTED}"}
EOF

  # Preserve initial-copy semantics unless we know copy already finished.
  RESUME_ARGS="--skip-schema"
  should_skip_initial_copy=0
  if [ "$PERSISTED_PHASE" = "replicating" ]; then
    should_skip_initial_copy=1
  elif [ "$PERSISTED_PHASE" = "copying" ]; then
    if bucardo status planetscale_import 2>/dev/null | awk -F " : " '/^Onetimecopy/ {print $2}' | grep -q "^No$"; then
      echo "Initial copy was already finished before restart; resuming without initial copy."
      should_skip_initial_copy=1
    fi
  fi

  if [ "$should_skip_initial_copy" -eq 1 ]; then
    RESUME_ARGS="--skip-schema --no-initial-copy"
  fi

  if sh /opt/bucardo/scripts/mk-bucardo-repl.sh --primary "$HEROKU_URL" --replica "$PLANETSCALE_URL" $RESUME_ARGS 2>&1 | tee /opt/bucardo/state/setup.log; then
    echo "Replication resumed!"
    bucardo kick planetscale_import 0

    RESUMED_PHASE="copying"
    RESUMED_STATE="initial_copy"
    RESUMED_MESSAGE="Copy resumed after restart."
    if bucardo status planetscale_import 2>/dev/null | awk -F " : " '/^Onetimecopy/ {print $2}' | grep -q "^No$"; then
      RESUMED_PHASE="replicating"
      RESUMED_STATE="running"
      RESUMED_MESSAGE="Bucardo replication resumed after restart."
    fi

    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"${RESUMED_PHASE}","state":"${RESUMED_STATE}","message":"${RESUMED_MESSAGE}","error":null,"started_at":"${PERSISTED_STARTED}"}
EOF
  else
    ERROR_MSG=$(tail -5 /opt/bucardo/state/setup.log | tr '\n' ' ' | sed 's/"/\\"/g')
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"error","state":"resume_failed","message":"Failed to resume replication after restart.","error":"${ERROR_MSG}","started_at":"${PERSISTED_STARTED}"}
EOF
    echo "ERROR: Failed to resume replication."
  fi
fi

# If we were ready_to_copy before restart, rebuild local Bucardo sync metadata.
# This prevents "No syncs have been created yet" when users click Start Data Copy
# after dyno restart or release restart.
if [ "$PERSISTED_PHASE" = "ready_to_copy" ]; then
  if ! bucardo status planetscale_import >/dev/null 2>&1; then
    echo "Reconstructing missing Bucardo sync for ready_to_copy phase..."
    if sh /opt/bucardo/scripts/mk-bucardo-repl.sh --primary "$HEROKU_URL" --replica "$PLANETSCALE_URL" --skip-schema 2>&1 | tee /opt/bucardo/state/setup.log; then
      bucardo pause planetscale_import >/dev/null 2>&1 || true
      CURRENT_PHASE=$(ruby -rjson -e 'f="/opt/bucardo/state/status.json"; if File.exist?(f); puts(JSON.parse(File.read(f))["phase"] || ""); end' 2>/dev/null || true)
      if [ "$CURRENT_PHASE" != "copying" ] && [ "$CURRENT_PHASE" != "replicating" ]; then
        cat > /opt/bucardo/state/status.json <<EOF
{"phase":"ready_to_copy","state":"schema_copied","message":"Schema and replication configured. Ready to start data copy.","error":null,"started_at":"${PERSISTED_STARTED}"}
EOF
      fi
    else
      ERROR_MSG=$(tail -5 /opt/bucardo/state/setup.log | tr '\n' ' ' | sed 's/"/\\"/g')
      cat > /opt/bucardo/state/status.json <<EOF
{"phase":"error","state":"resume_failed","message":"Failed to rebuild Bucardo sync after restart.","error":"${ERROR_MSG}","started_at":"${PERSISTED_STARTED}"}
EOF
      echo "ERROR: Failed to rebuild sync for ready_to_copy."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Keep the container running
# ---------------------------------------------------------------------------
echo "Migration runner is active. Visit the dashboard at :${PORT:-8080}/ to monitor progress."
wait $STATUS_SERVER_PID
