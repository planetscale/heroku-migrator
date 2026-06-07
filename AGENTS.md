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
SELECT n.nspname || '.' || c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('public') AND c.relkind = 'r'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.oid AND (i.indisprimary OR i.indisunique)
  )
ORDER BY n.nspname, c.relname;
```

If any tables are returned, the user must add a primary key or unique index to each one on their Heroku database before starting. Example fix: `ALTER TABLE table_name ADD PRIMARY KEY (id);`

The dashboard also runs this check automatically via `GET /preflight-checks` and blocks the Start Migration button.

### 3. Storage sizing

PlanetScale needs at least **2x** the Heroku database size. Check current Heroku usage:

```bash
heroku pg:info -a <app-name>
```

Look for "Data Size". If Heroku uses 10 GB, PlanetScale needs at least 20 GB. This is due to the amount of WAL which can be generated during the migration. Postgres will vacuum it up quickly, but running out of space will break the migration and it's not worth the risk. The user can always downsize their PlanetScale database after the migration is complete.

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

### 7. Generated columns

PostgreSQL `GENERATED ALWAYS AS ... STORED` columns are handled automatically by the migrator -- it registers a `customcols` override against the PlanetScale side that omits each generated column from `COPY`, and PlanetScale recomputes the value on insert. No user action required. The dashboard's preflight section lists any affected tables for visibility.

### 8. pg_partman

The migrator supports pg_partman by filtering migration scope by schema while
still using Bucardo's `add all tables` flow. Defaults:

- `MIGRATION_SCHEMAS=public`
- `MIGRATION_EXCLUDE_SCHEMAS=heroku_ext,partman,pg_partman,bucardo,pg_catalog,information_schema`

Example deployment override:

```bash
heroku config:set \
  MIGRATION_SCHEMAS=public \
  MIGRATION_EXCLUDE_SCHEMAS=heroku_ext,partman,pg_partman \
  -a <migration-app>
```

Before migration, tell the operator to pause pg_partman maintenance jobs on
Heroku and install pg_partman on PlanetScale. The dashboard detects
`partman.part_config` and `partman.dump_partitioned_table_definition(parent_table)`.
When detected, it shows managed parent tables and generated SQL from:

```sql
SELECT partman.dump_partitioned_table_definition(parent_table)
FROM partman.part_config
ORDER BY parent_table;
```

The operator must apply this SQL manually on PlanetScale after schema copy and
pg_partman extension installation. Do not auto-apply it. The dump function
supports single-level partition sets only.

Leaf partition tables in included application schemas are replicated. pg_partman
config/internal schemas are excluded. If a user stores pg_partman config tables
inside an included application schema, schema exclusion will not filter those
tables; they should move config tables to the extension schema or exclude that
schema from the migration.

### 9. Fresh PlanetScale target

Always use a clean PlanetScale database or branch for each migration attempt. Retrying against a target that has leftover tables/data from a failed run will cause errors.

## Common errors and fixes

### "Could not find TABLE inside public schema on database planetscale"

The schema copy (`pg_dump | psql`) failed silently for one or more tables. The table exists on Heroku but wasn't created on PlanetScale. Check the **Setup Log** in the dashboard (or `GET /logs` → `setup` field) for the actual `psql` error. Most common cause: a missing extension on PlanetScale that the table depends on. For non-public schemas, check that `MIGRATION_SCHEMAS` includes the app schema and that it is not removed by `MIGRATION_EXCLUDE_SCHEMAS`.

### "Generated columns cannot be used in COPY"

```
Failed : DBD::Pg::db do failed: ERROR: column "<colname>" is a generated column
DETAIL: Generated columns cannot be used in COPY.
```

Bucardo 5.6 does not filter out PostgreSQL `GENERATED ALWAYS AS ... STORED` columns when building the `COPY` it issues against the target. Any sync containing a table with a generated column will fail with this error during the initial copy and during ongoing replication.

**Current migrator (with auto-fix):** [scripts/mk-bucardo-repl.sh](scripts/mk-bucardo-repl.sh) detects generated columns in included migration schemas and registers `bucardo add customcols ... db=planetscale` overrides automatically. The setup log will show `Excluding generated columns on <schema>.<table> via customcols`. The dashboard's preflight section also lists affected tables as an informational note. No user action required.

**Older migrator (manual workaround):** If a user is on a version of the migrator without the auto-fix and they hit this error, they can apply the workaround inside the migration dyno (`heroku ps:exec -a <migration-app>`):

1. Identify generated columns:

   ```sql
   SELECT n.nspname, c.relname, a.attname
   FROM pg_attribute a
   JOIN pg_class c ON c.oid = a.attrelid
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('public') AND c.relkind = 'r'
     AND a.attnum > 0 AND NOT a.attisdropped
     AND a.attgenerated <> ''
   ORDER BY n.nspname, c.relname, a.attnum;
   ```

2. For each affected table, register a customcols override that omits the generated column(s) (the PlanetScale target already has the generation expression and will recompute the value on insert):

   ```bash
   bucardo add customcols <schema>.<table> "SELECT id, col_a, col_b, ..." db=planetscale
   ```

3. Abort the migration in the dashboard, recreate the PlanetScale target as a fresh database/branch, and start the migration again.

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

## Pause/Resume safety

The dashboard exposes **Pause Sync** in both the `copying` and `replicating` phases. Pause behaves very differently in each:

- **Phase `copying` (initial copy in progress, dashboard title "Copying data to PlanetScale"):** Warn users before they pause. Bucardo's `onetimecopy` cannot be resumed mid-table -- `bucardo pause` stops the in-flight `COPY` and `bucardo resume` restarts the initial copy from the beginning. All progress on the current table (and subsequent tables in the run) is lost. If a user needs to reduce load during the initial copy, the safer options are: wait for the copy to finish, resize to a larger Heroku Postgres plan, or **Abort Migration** and restart later.
- **Phase `replicating` with `bucardo.initial_copy_phase === "finished"` (dashboard title "Your databases are in sync"):** Pause is safe. Writes continue to be tracked in `bucardo_delta` and drain on Resume. The longer the pause, the larger the queue.
- Triggers remain active in both cases -- pause does not reduce write-side trigger overhead. Only **Abort Migration** removes triggers.

When triaging "my database is overloaded" reports, check `bucardo.initial_copy_phase` in `/status` before recommending Pause.

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
SELECT n.nspname || '.' || c.relname FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('public') AND c.relkind = 'r'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND (i.indisprimary OR i.indisunique))
ORDER BY n.nspname, c.relname;

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
    SELECT tgname, n.nspname, c.relname FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE tgname LIKE 'bucardo_%' AND n.nspname <> 'bucardo'
  LOOP
    EXECUTE format('DROP TRIGGER %I ON %I.%I', r.tgname, r.nspname, r.relname);
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
