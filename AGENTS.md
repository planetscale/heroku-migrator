# Migration Agent Guide

You are helping a user migrate their Heroku Postgres database to PlanetScale using this tool. This file contains everything you need to assist them, including pre-checks, common errors, and troubleshooting procedures.

## Project overview

This tool uses [Bucardo](https://bucardo.org/Bucardo/) to replicate data from Heroku Postgres to PlanetScale with minimal downtime. It runs as a temporary Heroku app (or Docker container) with a web dashboard for managing the migration.

**Key files:**
- `entrypoint.sh` -- Container entry point. Starts Postgres, Bucardo, and the status server. Handles state recovery after dyno restarts.
- `scripts/mk-bucardo-repl.sh` -- Schema copy (`pg_dump | psql`) and Bucardo replication setup.
- `scripts/rm-bucardo-repl.sh` -- Cleanup: removes triggers, schema, and Bucardo config from Heroku.
- `status-server/server.rb` -- WEBrick HTTP server. All dashboard endpoints, readiness checks, and migration actions.
- `status-server/dashboard.html` -- Single-page dashboard UI.

**Migration phases:** `waiting` → `starting` → `configuring` → `ready_to_copy` → `copying` → `replicating` → `switched` → `cleaning_up` → `completed`. Any phase can transition to `error`.

## Pre-migration checklist

Run these checks BEFORE the user clicks Start Migration. Each check includes the exact query or command to use.

### 1. Extensions

Query the Heroku database for non-default extensions:

```sql
SELECT extname, extversion FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;
```

Every extension listed must be enabled on the PlanetScale database before starting. If an extension is missing on PlanetScale, the schema copy will fail silently for tables that depend on it. See [PlanetScale extensions docs](https://planetscale.com/docs/postgres/extensions).

### 2. Primary keys and unique indexes

Every table must have a primary key or unique index. Bucardo cannot track rows without one.

```sql
SELECT c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.oid AND (i.indisprimary OR i.indisunique)
  )
ORDER BY c.relname;
```

If any tables are returned, the user must add a primary key or unique index to each one on their Heroku database before starting. Example fix: `ALTER TABLE table_name ADD PRIMARY KEY (id);`

The dashboard also runs this check automatically via `GET /preflight-checks` and blocks the Start Migration button.

### 3. Storage sizing

PlanetScale needs at least **2x** the Heroku database size. Check current Heroku usage:

```bash
heroku pg:info -a <app-name>
```

Look for "Data Size". If Heroku uses 10 GB, PlanetScale needs at least 20 GB.

### 4. Dyno sizing

The migrator runs PostgreSQL and Bucardo inside the dyno. Memory usage scales with write volume and data size.

| Database size | Recommended dyno |
|---|---|
| Under 10 GB, low write volume | Standard-1x (512 MB) |
| Under 100 GB, moderate writes | Standard-2x (1 GB) |
| Under 100 GB, high writes or many tables | Performance-M (2.5 GB) |
| **Over 100 GB** | **Performance-L (14 GB)** |

Databases over 100 GB will likely OOM on smaller dynos. A user with a 150 GB database crashed repeatedly on Standard-2x. When in doubt, start with Performance-M or Performance-L -- this is a temporary app that gets deleted after migration.

Watch for R14 memory errors: `heroku logs --tail -a <migration-app> | grep R14`

If R14 errors appear, resize immediately: `heroku ps:resize web=performance-l -a <migration-app>`

### 5. Vacuum check

Long-running autovacuum processes can block Bucardo's trigger creation, which can also block the user's application queries:

```bash
heroku pg:locks -a <app-name>
```

If any `VACUUM` queries with `(to prevent wraparound)` appear, wait for them to finish before starting.

### 6. Region matching

Heroku and PlanetScale should be in the same AWS region. Cross-region replication adds latency to every table inspection and sync cycle, slowing the migration significantly.

Parse the Heroku host to identify the region:
- `compute-1.amazonaws.com` = `us-east-1` (legacy naming, no region prefix)
- `<region>.compute.amazonaws.com` = that region (e.g., `us-west-2.compute.amazonaws.com`)

Match the PlanetScale database region accordingly (e.g., `us-east` for Heroku `us-east-1`).

### 7. Fresh PlanetScale target

Always use a clean PlanetScale database or branch for each migration attempt. Retrying against a target that has leftover tables/data from a failed run will cause errors.

## Common errors and fixes

### "Could not find TABLE inside public schema on database planetscale"

The schema copy (`pg_dump | psql`) failed silently for one or more tables. The table exists on Heroku but wasn't created on PlanetScale. Check the **Setup Log** in the dashboard (or `GET /logs` → `setup` field) for the actual `psql` error. Most common cause: a missing extension on PlanetScale that the table depends on.

### Deadlock during validate_sync

```
DBD::Pg::st execute failed: ERROR: deadlock detected
```

Transient race condition between Bucardo installing triggers and the app's active transactions. Abort and retry -- it almost always succeeds on the second attempt. If it keeps happening, try during a lower-traffic period.

### R14 / OOM errors

Dyno is too small. Resize immediately:

```bash
heroku ps:resize web=performance-l -a <migration-app>
```

If the dyno is in a crash loop after OOM, destroy and recreate the migration app with a larger dyno. Clean up the Heroku source database manually (see Cleanup section below).

### Cutover blocked with stale error

Dashboard shows cutover is blocked but everything else looks healthy (syncs completing, data in sync). Check the "Last Error" field -- if it says something like `Ended (CTL 999)`, that's a normal Bucardo controller restart, not a real error. If "Last Good Sync" shows a recent timestamp, replication is working fine. Use the override button to proceed.

### Setup fails, can't restart

If the migration entered the `error` phase during setup, click **Retry Migration** in the dashboard. This resets to the `waiting` phase so the user can fix the issue and start again. If the dashboard is inaccessible, the user needs to destroy and recreate the migration app.

## Retrieving logs

### Dashboard API

```bash
curl -u admin:<password> https://<migration-app>.herokuapp.com/logs
```

Returns JSON with two fields:
- `setup` -- Output from the schema copy and Bucardo configuration (mk-bucardo-repl.sh). Check this first for schema copy errors.
- `bucardo` -- Tail of the Bucardo replication log. Check this for replication errors, table inspection issues, and sync state.

### Heroku CLI

```bash
heroku logs --tail -a <migration-app>
```

Shows container-level output including R14 memory errors, dyno restarts, and server startup messages.

### Export diagnostics

The dashboard has an **Export Diagnostics JSON** button (in the Details section). This dumps the full migration status, Bucardo state, progress signals, and recent logs into a single JSON blob. Ask users to share this when troubleshooting.

### Status API

```bash
curl -u admin:<password> https://<migration-app>.herokuapp.com/status
```

Key fields in the response:
- `phase` -- Current migration phase
- `state` -- Sub-state within the phase
- `error` -- Error message if in error phase
- `bucardo.current_state` -- Bucardo's replication state (`good`, `applying_changes`, `bad`, etc.)
- `bucardo.initial_copy_phase` -- `in-progress` or `finished`
- `bucardo.last_good_sync` -- Timestamp of last successful sync
- `bucardo.last_error` -- Last Bucardo error string (may be stale)
- `cutover_readiness.level` -- `blocked`, `warning`, or `ready`
- `cutover_readiness.hard_blockers` -- Array of reasons cutover is blocked
- `cutover_readiness.soft_blockers` -- Array of warnings (can be overridden)
- `progress_signals.byte_weighted.percent` -- Estimated copy progress percentage
- `progress_signals.stall_detection.stalled` -- Whether progress has stalled

## Diagnostic queries

Run these against the Heroku source database to help diagnose issues:

```sql
-- List non-default extensions
SELECT extname, extversion FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;

-- Tables without primary key or unique index
SELECT c.relname FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND (i.indisprimary OR i.indisunique))
ORDER BY c.relname;

-- Table row counts (estimated, fast)
SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;

-- Check for blocking vacuum processes
SELECT pid, query, wait_event_type, state FROM pg_stat_activity WHERE query LIKE '%VACUUM%' AND state != 'idle';

-- Check for leftover Bucardo triggers (after failed migration)
SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'bucardo_%';

-- Check for leftover Bucardo schema
SELECT count(*) FROM pg_namespace WHERE nspname = 'bucardo';
```

## Interpreting dashboard status

| Phase | What's happening | User action |
|---|---|---|
| `waiting` | Ready to start. Preflight checks run automatically. | Review checklist, click Start Migration. |
| `starting` / `configuring` | Setting up Postgres, Bucardo, copying schema. | Wait. Typically 1-2 minutes. |
| `ready_to_copy` | Schema copied, replication configured. | Click Start Data Copy. |
| `copying` | Initial bulk copy of all rows in progress. | Wait. Can take minutes to hours for large DBs. |
| `replicating` | Initial copy done, real-time replication active. | Verify data, then click Switch Traffic when ready. |
| `switched` | Writes blocked on Heroku. | Update app's DATABASE_URL to PlanetScale, verify, then Complete or Revert. |
| `completed` | Migration done, triggers removed. | Delete the migration app. |
| `error` | Something failed. | Check error message and logs. Click Retry or Abort. |

### Cutover readiness levels

- **blocked** -- Hard blockers present (e.g., initial copy not finished, Bucardo status unavailable). Cannot proceed.
- **warning** -- Soft blockers present (e.g., replication health check failing due to stale error). Can override with the Switch Traffic button, which shows a confirmation modal.
- **ready** -- All checks pass. Safe to switch.

## Cleanup after failed migration

If abort fails or the dashboard is inaccessible, clean up the Heroku source database manually:

```sql
-- Remove all Bucardo triggers
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT tgname, relname FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE tgname LIKE 'bucardo_%' AND n.nspname = 'public'
  LOOP
    EXECUTE format('DROP TRIGGER %I ON %I', r.tgname, r.relname);
  END LOOP;
END $$;

-- Drop the Bucardo schema
DROP SCHEMA IF EXISTS bucardo CASCADE;
```

Verify cleanup:

```sql
SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'bucardo_%';  -- expect 0
SELECT count(*) FROM pg_namespace WHERE nspname = 'bucardo';     -- expect 0
```

Always use a **fresh PlanetScale branch/database** for the next attempt after cleanup.
