#!/usr/bin/env bash
set -e
# =============================================================================
# entrypoint.sh -- container start-up.
#
# Validates configuration, brings up the local Postgres that holds Bucardo's
# catalog, starts the status server, and resumes any migration that was in
# flight before the container restarted. Runs the status server in the
# foreground so the container lives as long as it does.
# =============================================================================

echo "=== Bucardo Migration Runner ==="
echo "Started at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
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

# Default both URLs to sslmode=require when it is omitted, so operators do not
# have to tweak URL parameters and the two sides cannot end up on different
# certificate modes.
if [[ "$HEROKU_URL" != *"sslmode="* ]]; then
  if [[ "$HEROKU_URL" == *"?"* ]]; then
    HEROKU_URL="${HEROKU_URL}&sslmode=require"
  else
    HEROKU_URL="${HEROKU_URL}?sslmode=require"
  fi
  export HEROKU_URL
  echo "HEROKU_URL missing sslmode; defaulting to sslmode=require"
fi

if [[ "$PLANETSCALE_URL" != *"sslmode="* ]]; then
  if [[ "$PLANETSCALE_URL" == *"?"* ]]; then
    PLANETSCALE_URL="${PLANETSCALE_URL}&sslmode=require"
  else
    PLANETSCALE_URL="${PLANETSCALE_URL}?sslmode=require"
  fi
  export PLANETSCALE_URL
  echo "PLANETSCALE_URL missing sslmode; defaulting to sslmode=require"
fi

# Strict verification needs a CA bundle; use the system one.
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

# ---------------------------------------------------------------------------
# Runtime environment
# ---------------------------------------------------------------------------
PGDATA="/opt/bucardo/pgdata"
PGPORT=5432
PGSOCKET="/tmp"

# The container may run as a random non-root UID with no /etc/passwd entry,
# which Postgres and Bucardo both require.
if ! whoami &>/dev/null; then
  echo "heroku:x:$(id -u):0:Heroku User:/opt/bucardo:/bin/bash" >> /etc/passwd
fi
export HOME="/opt/bucardo"

# Private temp dir for all children: Ruby's Dir.tmpdir rejects a
# world-writable one without the sticky bit, so a 0777 /tmp would break it.
export TMPDIR="$HOME/tmp"
export TMP="$TMPDIR"
mkdir -p "$TMPDIR" 2>/dev/null || true
chmod 700 "$TMPDIR" 2>/dev/null || true
if [ ! -w "$TMPDIR" ]; then
  echo "WARNING: TMPDIR ($TMPDIR) is not writable; falling back to /tmp"
  export TMPDIR=/tmp
  export TMP=/tmp
fi

# Bucardo writes bucardo.restart.reason.txt to the working directory, and would
# not start from a non-writable one.
cd "$HOME" || true

# ---------------------------------------------------------------------------
# Migration state from the target (survives container restarts)
# ---------------------------------------------------------------------------
echo "Checking for existing migration state..."
PERSISTED_PHASE=""
PERSISTED_STARTED=""
PERSISTED_SWITCHED=""
PERSISTED_COMPLETED=""

STATE_ROW=$(psql "$PLANETSCALE_URL" -A -t -c "SELECT phase, started_at, switched_at, completed_at FROM _ps_migrator.migration_state WHERE id = 1" 2>/dev/null || echo "")
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
  "aborted")
    echo "Migration was aborted. Starting dashboard only."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"aborted","state":"aborted","message":"Migration aborted. All Bucardo triggers have been removed from your Heroku database.","error":null,"started_at":"${PERSISTED_STARTED}","completed_at":"${PERSISTED_COMPLETED}"}
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
  "rebuilding_indexes")
    echo "Migration was rebuilding indexes. Will resume the rebuild after infrastructure is back."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"rebuilding_indexes","state":"resuming","message":"Resuming index rebuild after restart...","error":null,"started_at":"${PERSISTED_STARTED}"}
EOF
    ;;
  "index_rebuild_failed")
    echo "Migration was holding after index-rebuild failures. Replication stays paused for review."
    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"index_rebuild_failed","state":"rebuild_failed","message":"Index rebuild had failures. Replication is paused. Retry or proceed from the dashboard.","error":null,"started_at":"${PERSISTED_STARTED}"}
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
# Status server -- started first so the platform sees the port bound
# ---------------------------------------------------------------------------
echo "Starting status server on port ${PORT:-8080}..."
ruby /opt/bucardo/status-server/server.rb &
STATUS_SERVER_PID=$!

# ---------------------------------------------------------------------------
# Start PostgreSQL and Bucardo infrastructure (needed for all active states)
# ---------------------------------------------------------------------------
if [ "$PERSISTED_PHASE" != "completed" ] && [ "$PERSISTED_PHASE" != "aborted" ]; then
  # Initialize PostgreSQL at runtime
  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    # $PGDATA ships owned by root; a non-root uid can't set initdb's required 0700
    # perms on it, so recreate the empty dir to take ownership first (any uid).
    if [ ! -O "$PGDATA" ]; then
      rm -rf "$PGDATA" 2>/dev/null || true
      mkdir -p "$PGDATA" 2>/dev/null || true
    fi
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

  echo "Configuring Bucardo verbose logging..."
  bucardo set log_level=verbose

  # Purge applied deltas aggressively so deltas converge to 0 quickly after writes
  # are frozen. vac_run is the actual purge interval (default 30s); vac_sleep is the
  # VAC's internal check granularity.
  bucardo set vac_run=10 vac_sleep=5

  # TCP keepalives so a silently-dropped long-haul connection can't stall
  # replication: idle 60s, probe every 10s, drop after 6 failures.
  bucardo set tcp_keepalives_idle=60 tcp_keepalives_interval=10 tcp_keepalives_count=6

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
    # Onetimecopy "Yes" => copy still running; anything else => done, resume in
    # delta mode rather than re-copying.
    ONETIME_COPY=$(bucardo status planetscale_import 2>/dev/null | awk -F " : " '/^Onetimecopy/ {print $2}' | tr -d '[:space:]')
    if ! echo "$ONETIME_COPY" | grep -qi "^Yes"; then
      echo "Initial copy was already finished before restart; resuming without initial copy."
      should_skip_initial_copy=1
    fi
  fi

  if [ "$should_skip_initial_copy" -eq 1 ]; then
    RESUME_ARGS="--skip-schema --no-initial-copy"
  fi

  # Check the script's exit status.
  sh /opt/bucardo/scripts/mk-bucardo-repl.sh --primary "$HEROKU_URL" --replica "$PLANETSCALE_URL" $RESUME_ARGS 2>&1 | tee /opt/bucardo/state/setup.log
  RESUME_RC=${PIPESTATUS[0]}
  if [ "$RESUME_RC" -eq 0 ]; then
    echo "Replication resumed!"
    bucardo kick planetscale_import 0 || true

    if [ "$should_skip_initial_copy" -eq 1 ]; then
      # Land in "copying" (not "replicating") so the status server can run any
      # pending deferred index rebuild before promoting.
      RESUMED_PHASE="copying"
      RESUMED_STATE="initial_copy_complete"
      RESUMED_MESSAGE="Initial copy complete. Finalizing replication (rebuilding any deferred indexes)..."
    else
      RESUMED_PHASE="copying"
      RESUMED_STATE="initial_copy"
      RESUMED_MESSAGE="Copy resumed after restart."
    fi

    cat > /opt/bucardo/state/status.json <<EOF
{"phase":"${RESUMED_PHASE}","state":"${RESUMED_STATE}","message":"${RESUMED_MESSAGE}","error":null,"started_at":"${PERSISTED_STARTED}"}
EOF
  else
    ERROR_MSG=$(tail -5 /opt/bucardo/state/setup.log | tr '\n' ' ' | sed 's/"/\\"/g')
    # Missing schema on target: resume uses --skip-schema and can't recover.
    # User must start a fresh migration so the schema is re-copied.
    if grep -qi "Could not find schema" /opt/bucardo/state/setup.log; then
      MISSING_SCHEMA_MSG="The target database is missing one or more schemas from the source (resume does not re-copy the schema). Abort this migration and start a fresh one against a target that does not yet have the schema. Details: ${ERROR_MSG}"
      cat > /opt/bucardo/state/status.json <<EOF
{"phase":"error","state":"resume_failed","message":"Cannot resume: target is missing schema(s) present on the source. Start a fresh migration.","error":"${MISSING_SCHEMA_MSG}","started_at":"${PERSISTED_STARTED}"}
EOF
    else
      cat > /opt/bucardo/state/status.json <<EOF
{"phase":"error","state":"resume_failed","message":"Failed to resume replication after restart.","error":"${ERROR_MSG}","started_at":"${PERSISTED_STARTED}"}
EOF
    fi
    echo "ERROR: Failed to resume replication (rc=${RESUME_RC})."
  fi
fi

# Rebuild the sync metadata if we were ready_to_copy, so Start Data Copy does
# not fail with "No syncs have been created yet" after a restart.
if [ "$PERSISTED_PHASE" = "ready_to_copy" ]; then
  if ! bucardo status planetscale_import >/dev/null 2>&1; then
    echo "Reconstructing missing Bucardo sync for ready_to_copy phase..."
    sh /opt/bucardo/scripts/mk-bucardo-repl.sh --primary "$HEROKU_URL" --replica "$PLANETSCALE_URL" --skip-schema 2>&1 | tee /opt/bucardo/state/setup.log
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
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

# Restarted during or after the index rebuild: make sure the sync exists and is
# paused. The status server relaunches the rebuild from the registry.
if [ "$PERSISTED_PHASE" = "rebuilding_indexes" ] || [ "$PERSISTED_PHASE" = "index_rebuild_failed" ]; then
  if ! bucardo status planetscale_import >/dev/null 2>&1; then
    echo "Reconstructing Bucardo sync for '$PERSISTED_PHASE' phase (paused)..."
    sh /opt/bucardo/scripts/mk-bucardo-repl.sh --primary "$HEROKU_URL" --replica "$PLANETSCALE_URL" --skip-schema --no-initial-copy 2>&1 | tee /opt/bucardo/state/setup.log
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
      bucardo pause planetscale_import >/dev/null 2>&1 || true
    else
      ERROR_MSG=$(tail -5 /opt/bucardo/state/setup.log | tr '\n' ' ' | sed 's/"/\\"/g')
      cat > /opt/bucardo/state/status.json <<EOF
{"phase":"error","state":"resume_failed","message":"Failed to rebuild Bucardo sync after restart.","error":"${ERROR_MSG}","started_at":"${PERSISTED_STARTED}"}
EOF
      echo "ERROR: Failed to rebuild sync for '$PERSISTED_PHASE'."
    fi
  else
    bucardo pause planetscale_import >/dev/null 2>&1 || true
  fi
fi

# ---------------------------------------------------------------------------
# VAC (delta-purge) watchdog
# ---------------------------------------------------------------------------
# Bucardo only starts its delta-purge VAC daemon at MCP startup, and only if a
# sync already exists. We start the MCP at boot, before the sync is created, so
# on a fresh migration VAC never runs and applied deltas are never purged
# (`bucardo delta` climbs forever). Once replication is steady, restart Bucardo
# if VAC is missing: the MCP then comes up with the sync present. onetimecopy
# has reset by then, so this resumes without re-copying. Gated to never fire
# during the initial copy or the index rebuild.
vac_watchdog() {
  set +e
  attempts=0
  while true; do
    sleep 10
    ps_line=$(ruby -rjson -e 'd=(JSON.parse(File.read("/opt/bucardo/state/status.json")) rescue {}); puts "#{d["phase"]}|#{d["state"]}"' 2>/dev/null)
    phase=${ps_line%%|*}; state=${ps_line#*|}
    case "$phase" in replicating|switched) ;; *) continue ;; esac  # steady state / post-cutover only
    [ "$state" = "paused" ] && continue            # don't disturb a user pause
    if ps -eo args 2>/dev/null | grep -q "[B]ucardo VAC"; then
      attempts=0; continue                         # VAC running -- all good
    fi
    otc=$(bucardo status planetscale_import 2>/dev/null | awk -F " : " '/^Onetimecopy/ {print $2}' | tr -d '[:space:]')
    echo "$otc" | grep -qi "^Yes" && continue      # initial copy not finished -- never restart
    [ "$attempts" -ge 3 ] && continue              # cap restarts to avoid a storm
    attempts=$((attempts + 1))
    echo "VAC watchdog: delta-purge VAC not running in steady replication; restarting Bucardo (attempt $attempts) to start it..."
    bucardo restart >/dev/null 2>&1 || true
  done
}
vac_watchdog &

# ---------------------------------------------------------------------------
# Keep the container running
# ---------------------------------------------------------------------------
echo "Migration runner is active. Visit the dashboard at :${PORT:-8080}/ to monitor progress."
wait $STATUS_SERVER_PID
