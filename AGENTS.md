# Migration Agent Guide

You are helping a user migrate their Heroku Postgres database to PlanetScale using this tool. This file contains everything you need to assist them, including pre-checks, common errors, and troubleshooting procedures.

## Project overview

This tool uses [Bucardo](https://bucardo.org/Bucardo/) to replicate data from Heroku Postgres to PlanetScale with minimal downtime. It runs as a temporary Heroku app (or Docker container) with a web dashboard for managing the migration.

**Key files:**
- `entrypoint.sh` -- Container entry point. Starts Postgres, Bucardo, and the status server. Handles state recovery after dyno restarts.
- `scripts/mk-bucardo-repl.sh` -- Schema copy (`pg_dump | psql`) and Bucardo replication setup.
- `scripts/drop-secondary-indexes.sh` -- Deferred index rebuild: drops the target's secondary/unique indexes before the copy and records their definitions in `_ps_migrator.dropped_indexes` for rebuild afterward. Skipped when `DISABLE_INDEX_DEFERRAL=true`.
- `scripts/rm-bucardo-repl.sh` -- Cleanup: removes triggers, schema, and Bucardo config from Heroku.
- `status-server/server.rb` -- WEBrick HTTP server. All dashboard endpoints, readiness checks, and migration actions.
- `status-server/dashboard.html` -- Single-page dashboard UI.

**Migration phases:** `waiting` → `starting` → `configuring` → `ready_to_copy` → `copying` → `rebuilding_indexes` → `replicating` → `switched` → `cleaning_up` → `completed`. Any phase can transition to `error`. When a deferred index rebuild has failures, the run holds in `index_rebuild_failed` until the user retries or proceeds. When index deferral is disabled (`DISABLE_INDEX_DEFERRAL=true`), `rebuilding_indexes` is skipped and `copying` goes straight to `replicating`.

## Pre-migration checklist

Run these checks BEFORE the user clicks Start Migration. Each check includes the exact query or command to use.

### 1. Extensions

Query the Heroku database for non-default extensions:

```sql
SELECT extname, extversion FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;
```

Every extension listed must be enabled on the PlanetScale database before starting. If an extension is missing on PlanetScale, the schema copy will fail silently for tables that depend on it. See [PlanetScale extensions docs](https://planetscale.com/docs/postgres/extensions).

### 2. Primary keys and unique indexes

Every table must have a primary key or unique index, **in every schema being migrated** -- not just `public`. Bucardo cannot track rows without one, and refuses to add the sync.

```sql
SELECT n.nspname || '.' || c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'bucardo', '_ps_migrator', 'pscale_extensions')
  AND left(n.nspname, 3) <> 'pg_'
  AND n.nspname NOT IN (
    SELECT en.nspname FROM pg_extension e
    JOIN pg_namespace en ON en.oid = e.extnamespace
    WHERE en.nspname NOT IN ('public', 'pg_catalog')
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.oid AND (i.indisprimary OR i.indisunique)
  )
ORDER BY 1;
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

### 8. Fresh PlanetScale target

Always use a clean PlanetScale database or branch for each migration attempt. Retrying against a target that has leftover tables/data from a failed run will cause errors.

## What gets replicated (schema scope)

All application schemas are migrated, not just `public`. Scope differs between the two stages.

**Schema copy.** `pg_dump` with `--exclude-schema` for `bucardo`, `_ps_migrator` and `pscale_extensions`: the migrator's own bookkeeping must never land on the customer's target. Bucardo's triggers sit on *application* tables, so `--exclude-schema` alone leaves them behind referencing a schema that is no longer dumped -- the copy then fails with `schema "bucardo" does not exist`, and if it succeeded the target would inherit delta tracking. They are filtered by `EXCLUDE_PATTERN` as well. This matters on a re-copy after a failed run, where the source may still carry Bucardo artifacts. `pg_catalog`/`information_schema`/`pg_*` need no handling; pg_dump never emits them. Extension schemas (`heroku_ext`, `partman`) **are** copied and must be: column types depend on them, and pg_partman's template tables are referenced from its config.

**Replication.** Bucardo's `add all tables` enrols every user table. Three kinds of relation are then **subtracted** in [scripts/mk-bucardo-repl.sh](scripts/mk-bucardo-repl.sh), because Bucardo cannot replicate them and `bucardo add sync` fails outright if they are left in:

- **Anything in a schema an extension was installed into** (e.g. `partman`). Holds extension config tables and internal tables with no primary key.
- **Any table owned by an extension** (`pg_depend.deptype = 'e'`). This is what catches an extension installed into `public` -- PostGIS's `spatial_ref_sys`, or pg_partman installed without its own schema.
- **Any table the migrator has no `TRIGGER` privilege on.** Bucardo replicates via triggers, so without it the table cannot be carried. The setup log lists every exclusion and why.

The same scope governs the primary-key preflight and the Switch Traffic `REVOKE`/`GRANT`, which run over **every migrated schema**. `MIGRATED_SCHEMA_SCOPE_SQL` in [status-server/server.rb](status-server/server.rb) and the `NOT_REPLICATABLE` query in [scripts/mk-bucardo-repl.sh](scripts/mk-bucardo-repl.sh) are complements of each other and must be kept in sync; `tests/test_schema_scope.sh` asserts they agree.

Tables left out of the scope are not replicated, so a missing primary key on one of them is not an error and is not reported.

## pg_partman

pg_partman works, with one manual step: pause pg_partman maintenance before starting, and resume it on PlanetScale after cutover. Everything else is automated. The migrator replicates the **leaf partitions** (ordinary tables in an app schema); the partitioned parent is `relkind = 'p'` and carries no rows of its own, so Bucardo skips it and the schema copy recreates it. pg_partman's own `partman` schema is excluded from replication per the scope rules above.

**Before starting (required):**

1. **Pause pg_partman maintenance** -- the pg_cron job, or whatever calls `partman.run_maintenance_proc()`. Leave it paused until after cutover, then resume it on PlanetScale.
2. Installing pg_partman on the PlanetScale target ahead of time is fine; the schema copy is idempotent about schemas that already exist. Letting the schema copy create it works too.

Client tools in the image are PostgreSQL 18, because `pg_dump` refuses to dump a server newer than itself. PG17 and PG18 are supported in either position (source or target); all four combinations are covered by `tests/test_schema_scope.sh` fixtures and were verified end to end.

**Why pausing matters:** Bucardo's relation list is fixed when the sync is created. A partition that maintenance creates *after* that point is not in the sync, so rows written to it are **never replicated and nothing reports an error** -- `bucardo status` stays `Good` and the dashboard stays healthy. With `automatic_maintenance = 'on'` (the pg_partman default) this happens unattended.

**Partition config is recreated automatically, after the data copy.** The schema copy carries the extension, not `part_config`'s rows, so the target would otherwise have pg_partman installed with no sets registered and would never create another partition. [scripts/recreate-partman-config.sh](scripts/recreate-partman-config.sh) replays the source's config onto the replica; the status server runs it once the initial copy is complete -- after a clean deferred index rebuild, or directly after the copy when deferral is disabled -- and before delta apply resumes. Its output goes to the index-rebuild log (`GET /logs` → `rebuild`), not the setup log. pg_partman's schema is resolved from `pg_extension`, so a non-default install schema works.

Three details matter:

- **It must not run before the copy.** `create_partition()` premakes partitions on the target. Bucardo enrols leaf partitions and copies **leaf to leaf**, bypassing tuple routing, so source rows sitting in a DEFAULT partition whose range a premade target partition now covers are pushed into a target DEFAULT that rejects them (`new row ... violates partition constraint`). The KID dies, restarts, re-copies from the first table and dies again -- indefinitely, while `/status` still reports `copying` with `error: null`. Running the replay after the copy removes the hazard: nothing is premade until every row has landed.
- **`p_start_partition` is pinned** to the oldest existing child. `dump_partitioned_table_definition()` omits it, so the replayed `create_partition()` aligns to `now()`; when the source's premade partitions no longer span `now() + premake` it creates partitions the source lacks and then collides with the default partition pg_dump already made, failing that set. Because it depends on `now()`, the same source can replay cleanly one day and fail the next.
- **It is deliberately fail-soft** (no `ON_ERROR_STOP`). A set that will not replay -- a sub-partitioned one, for instance -- is reported and the migration continues; the data copy is unaffected. Running after the copy also means Postgres itself refuses a premake that would strand rows already in a DEFAULT partition (`updated partition constraint for default partition ... would be violated by some row`); that set is reported and skipped rather than breaking anything. Until it is re-registered, pg_partman creates no new partitions for that table on PlanetScale; re-register it there after cutover with `partman.create_parent()`, using the same settings as on the source. Sub-partitioned sets (`part_config_sub`) are counted and called out, since the dump function covers single-level sets only.

Re-running the replay is idempotent, so a retry is safe.

**Checking a source for pg_partman:**

```sql
SELECT e.extname, n.nspname AS schema, e.extversion
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_partman';

SELECT parent_table, control, partition_interval, automatic_maintenance
FROM partman.part_config ORDER BY parent_table;
```

## Deferred index rebuild

To speed up the initial copy, the migrator **drops the target's secondary and unique indexes before copying** (primary keys are kept) and rebuilds them after the copy finishes. Definitions are recorded in `_ps_migrator.dropped_indexes` on the target. This is the default behavior.

Scope is every migrated schema (same rule as replication) and `relkind IN ('r','p')`, so **partitioned tables are covered**: the index is dropped and rebuilt on the parent, which cascades to every partition. Three details make that work:

- **Child indexes are not registered separately.** An index that is a partition of a partitioned index (`pg_inherits` on `indexrelid`) cannot be dropped on its own, so only the parent is recorded. An index created directly on one partition is not part of a partitioned index and is handled individually.
- **`ON ONLY` is stripped from the rebuild recipe.** `pg_get_indexdef` emits `CREATE INDEX ... ON ONLY parent` for a partitioned index; replayed verbatim that builds a childless index left `indisvalid = false` — it still appears in `pg_indexes`, so every schema check passes while queries silently seq-scan. Without `ONLY` the single statement builds every partition.
- **Sizing uses `pg_partition_tree`.** A partitioned parent stores nothing itself, so `pg_total_relation_size` returns 0 and the largest rebuild would be claimed last. `GREATEST(pg_total_relation_size(...), sum over pg_partition_tree(...))` covers both shapes; `pg_partition_tree` returns no rows for a plain table.

Flow: `copying` → (copy finishes) → delta apply is paused → `rebuilding_indexes` (indexes rebuilt `INDEX_REBUILD_WORKERS` at a time) → if all succeed, replication resumes → `replicating`. If any index fails, the run holds in `index_rebuild_failed` so the user can **Retry Failed Indexes** or **Proceed Anyway**.

**What drives the transition.** `apply_auto_transitions` in [status-server/server.rb](status-server/server.rb) is run both by `GET /status` and by a background phase watcher that ticks every 30s, so the migration progresses with no dashboard open. It used to run only in the `/status` handler: with nobody polling, a finished copy sat in `copying` indefinitely -- in one run for 11.7 hours, while deltas were applied to a target still missing its secondary indexes. The watcher only does work in `ready_to_copy`, `copying` and `rebuilding_indexes`, skips its tick if `/status` evaluated within the last 20s (so an open dashboard and the watcher do not both shell out to `bucardo status`), and shares `$phase_transition_mutex` with `/status` so the two can never transition concurrently. It logs only when it actually causes a transition (`[phase-watcher] copying -> rebuilding_indexes`).

Progress is written to `index-rebuild.log` in the state dir, exposed as the `rebuild` field of `GET /logs`: one line per object with its name, table, kind and size, a running `[n/total done, building, pending, failed]` counter, and on failure the reason plus the SQL to retry by hand.

**Env vars (all optional):**
- `DISABLE_INDEX_DEFERRAL` -- default `false`. Set to `true` to keep all indexes in place during the copy (no drop/rebuild). When `true`, the three vars below have **no effect**, `rebuilding_indexes` is skipped, and the dashboard hides the index-rebuild tuning control.
- `INDEX_REBUILD_WORKERS` -- parallel index builds (default `4`). Tunable live from the dashboard before the copy.
- `MAINTENANCE_WORK_MEM` -- `maintenance_work_mem` per build (default `1GB`). Peak target memory ≈ workers × this value.
- `PARALLEL_MAINTENANCE_WORKERS` -- `max_parallel_maintenance_workers` per build (default `2`).

**Diagnosing "target is missing indexes":** if the target has fewer indexes than the source and the run is stuck in `copying`, the rebuild was never triggered. The trigger is gated on the status server detecting the copy is finished *and* healthy (see "Stuck in `copying`..." below). Check `GET /status` → `rebuild_config` and `index_rebuild`.

## Common errors and fixes

### "Could not find TABLE inside public schema on database planetscale"

The schema copy (`pg_dump | psql`) failed silently for one or more tables. The table exists on Heroku but wasn't created on PlanetScale. Check the **Setup Log** in the dashboard (or `GET /logs` → `setup` field) for the actual `psql` error. Most common cause: a missing extension on PlanetScale that the table depends on.

### "Generated columns cannot be used in COPY"

```
Failed : DBD::Pg::db do failed: ERROR: column "<colname>" is a generated column
DETAIL: Generated columns cannot be used in COPY.
```

Bucardo 5.6 does not filter out PostgreSQL `GENERATED ALWAYS AS ... STORED` columns when building the `COPY` it issues against the target. Any sync containing a table with a generated column will fail with this error during the initial copy and during ongoing replication.

**Current migrator (with auto-fix):** [scripts/mk-bucardo-repl.sh](scripts/mk-bucardo-repl.sh) detects generated columns and registers `bucardo add customcols ... db=planetscale` overrides automatically. The setup log will show `Excluding generated columns on public.<table> via customcols`. The dashboard's preflight section also lists affected tables as an informational note. No user action required.

**Older migrator (manual workaround):** If a user is on a version of the migrator without the auto-fix and they hit this error, they can apply the workaround inside the migration dyno (`heroku ps:exec -a <migration-app>`):

1. Identify generated columns:

   ```sql
   SELECT n.nspname, c.relname, a.attname
   FROM pg_attribute a
   JOIN pg_class c ON c.oid = a.attrelid
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r'
     AND a.attnum > 0 AND NOT a.attisdropped
     AND a.attgenerated <> ''
   ORDER BY n.nspname, c.relname, a.attnum;
   ```

2. For each affected table, register a customcols override that omits the generated column(s) (the PlanetScale target already has the generation expression and will recompute the value on insert):

   ```bash
   bucardo add customcols public.<table> "SELECT id, col_a, col_b, ..." db=planetscale
   ```

3. Abort the migration in the dashboard, recreate the PlanetScale target as a fresh database/branch, and start the migration again.

### "permission denied for table part_config" (or any extension table)

```
Failed to add sync: DBD::Pg::st execute failed: ERROR:  DBD::Pg::db do failed:
ERROR:  permission denied for table part_config at line 128. at line 30.
CONTEXT:  PL/Perl function "validate_sync" at /usr/local/bin/bucardo line 4670.
```

Bucardo enrolled a table owned by an extension and tried to put a replication trigger on it. The Heroku connection role does not own extension tables, so `CREATE TRIGGER` is denied. Current migrator subtracts these before adding the sync (see "What gets replicated"); the setup log shows `Excluding tables Bucardo cannot replicate`. If a user hits this on an older build, upgrade -- there is no config workaround, and granting `TRIGGER` on the extension's tables is the wrong fix (it would replicate the extension's own config over the target's).

### "Table X must specify a primary key!" during setup

```
Failed to add sync: DBD::Pg::st execute failed:
ERROR:  Table "analytics.clickstream" must specify a primary key! at line 119.
```

Bucardo needs a primary key or unique index on every table in the sync. Two causes:

- **An app table in a non-`public` schema.** Older builds only ran the preflight check against `public`, so the dashboard reported "all tables valid" and the migration then failed here. Add a primary key or unique index to the table and retry.
- **An extension-internal table**, e.g. pg_partman's `partman.template_*`, which have no primary key by design. Current migrator excludes these automatically.

### "schema ... already exists" during the schema copy

```
CREATE SCHEMA partman;
ERROR:  schema "partman" already exists
```

The target already had that schema -- normally because an extension such as pg_partman was installed on PlanetScale ahead of the migration, which is a reasonable thing to have done. `psql` runs with `ON_ERROR_STOP=1`, so the whole schema copy aborts and the run lands in `error` / `setup_failed` with nothing created. Current migrator rewrites `CREATE SCHEMA x;` to `CREATE SCHEMA IF NOT EXISTS x;` in the dump stream. (`CREATE EXTENSION` never needed this: pg_dump already emits it with `IF NOT EXISTS`.)

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

### "could not find a temporary directory"

This error comes from **Ruby**, not Bucardo. Ruby's `Dir.tmpdir`/`Dir.mktmpdir`/`Tempfile` **reject a world-writable temp dir that lacks the sticky bit** (a security check). A `chmod 777 /tmp` (instead of the normal `1777`) trips this. When it happens, the status server cannot read Bucardo status and the dashboard loses all replication visibility (all `bucardo.*` fields in `/status` come back `nil`).

Current migrator avoids this three ways: `/tmp` is created `1777` (sticky) in the [Dockerfile](Dockerfile); [entrypoint.sh](entrypoint.sh) exports `TMPDIR=$HOME/tmp` (a private, non-world-writable dir Ruby always accepts); and `get_bucardo_status` reads `bucardo status` via stdout capture rather than a temp file. If a user sees this on an older build, rebuild the image. Verify with `docker exec <c> ruby -rtmpdir -e 'Dir.mktmpdir{|d| puts d}'`.

### Stuck in `copying` while replication is actually running

Symptom: Bucardo logs show successful delta syncs (`conflicts=0`, `All databases committed`) and `bucardo status` shows `Onetimecopy : No`, but the dashboard never leaves `copying` and the deferred index rebuild never fires.

Root cause is almost always that `GET /status` returns `nil` for every `bucardo.*` field -- i.e. `get_bucardo_status` is failing (see the temp-directory error above), so the `copying → rebuilding_indexes/replicating` transition (guarded by `if bucardo_status`) never runs. Confirm by checking whether `bucardo.initial_copy_phase`/`current_state` in `/status` are populated. If they are `nil` while the `bucardo` CLI works inside the container, it's the temp-dir issue -- rebuild the image and restart.

Note on copy-completion detection: completion is inferred from Bucardo's `Onetimecopy` line. The parser (and `entrypoint.sh` resume check) treat **anything that is not an explicit `Yes` as finished** (mirroring `scripts/stat-bucardo-repl.sh`), so a `No`, an unexpected value, or a missing line all count as "copy done" rather than stranding the run.

### `bucardo delta` never drops to 0 (deltas not purged)

Symptom: after writes are frozen, the target is caught up (row counts match, `Last good` recent) but `bucardo delta` stays high and never reaches 0; the KID applies changes fine but delta records pile up.

Root cause: Bucardo's **VAC** daemon (which purges applied delta rows) is launched by the MCP **only at MCP startup, and only when a sync already exists then**. The migrator starts the MCP at container boot — before the sync is created (the sync appears when the user clicks Start Migration) — so on a fresh run the MCP boots with `Active syncs: 0` and never forks VAC. Replication still works (deltas are applied), but applied deltas are never purged, so `bucardo delta` only climbs. (A dyno/container restart *after* the sync exists incidentally fixes it, because the MCP then reboots with the sync present and starts VAC — which is why it can appear to "work sometimes.")

Confirm: `docker exec <c> sh -c 'ps -eo args | grep "[B]ucardo VAC"'` (no output = VAC not running), and the MCP log shows `Active syncs: 0` at the boot timestamp.

Fix: the entrypoint runs a **VAC watchdog** (polls every 10s) — once replication is steady (`phase` is `replicating` or `switched`, initial copy done, not paused), if no VAC process is running it issues one `bucardo restart`, which relaunches the MCP with the sync present and starts VAC. `onetimecopy` has reset by then, so this resumes delta replication without re-copying. The entrypoint also sets `vac_run=10 vac_sleep=5` so VAC purges every ~10s (the purge interval is `vac_run`, default 30; `vac_sleep` is only the check granularity), draining deltas to 0 quickly after writes freeze. Manual one-off recovery is the same command: `docker exec <c> bucardo restart`.

### Track-table `txntime` indexes (added automatically during setup)

Replication setup runs `scripts/add-track-indexes.sh` against the **source**, between `bucardo add sync` (which creates the `bucardo.track_*` change-tracking tables) and `bucardo reload` (which starts the sync). It creates `dex4_<makername> ON bucardo.track_<makername> (txntime)` on every track table.

Bucardo only indexes track tables as `(target text_pattern_ops, txntime)`, but `bucardo.bucardo_delta_check()` anti-joins on `txntime` alone, so that index cannot serve it. Without a `txntime`-leading index the check degrades to a full scan of the track table per delta row, which on a large migration means delta replication stalls after the initial copy and cannot be recovered by restart or pause/resume.

The step runs while the track tables are still empty, so it is instant and takes no lock that affects application traffic (source writes only touch `bucardo.delta_*`). It is idempotent, and **fails closed** -- if it cannot index every track table, setup exits non-zero and the migration lands in `error` / `setup_failed` rather than starting a copy that would stall later. `DROP SCHEMA bucardo CASCADE` at cleanup removes these indexes along with the tables, so nothing is left behind.

Check whether a source is covered (should return no rows):

```sql
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'bucardo' AND c.relkind IN ('r','p') AND left(c.relname, 6) = 'track_'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i JOIN pg_class ci ON ci.oid = i.indexrelid
    JOIN pg_am am ON am.oid = ci.relam
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
    WHERE i.indrelid = c.oid AND a.attname = 'txntime' AND am.amname = 'btree'
      AND i.indisvalid AND i.indpred IS NULL AND i.indexprs IS NULL);
```

To report coverage without changing anything: `sh /opt/bucardo/scripts/add-track-indexes.sh --primary "$HEROKU_URL" --verify-only`.

### Switch Traffic didn't stop writes

The switch runs `REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA <s> FROM <role>` once per migrated schema (see "What gets replicated"), so a source with app tables outside `public` is fully frozen. **A `REVOKE` cannot constrain a Postgres SUPERUSER** -- superusers bypass all privilege checks -- and table **owners** retain implicit rights too. So if the connection role is a superuser (very common when testing locally as `postgres`), the REVOKE reports success but writes keep working. On Heroku this is a non-issue: `DATABASE_URL` connects as a non-superuser app role, so the REVOKE genuinely blocks writes. To block writes locally, connect the app/migrator as a non-superuser, non-owner role.

### "Cannot resume: target is missing schema(s)"

On resume after a restart (e.g. phase persisted as `copying`), the migrator reconfigures Bucardo with `--skip-schema` -- it assumes the schema is already on the target. If the target is missing a schema present on the source (it was never fully copied, or the target was reset), `bucardo add sync` fails with `Could not find schema "<name>" in database "planetscale"`. Resume cannot recover this on its own; the user must **start a fresh migration** against a clean target so the full schema copy re-runs. (The entrypoint surfaces this as a clear `error` phase rather than crash-looping -- earlier a `cmd | tee` pipeline masked the failure, after which `bucardo kick` aborted the container under `set -e`.)

## Pause/Resume safety

The dashboard exposes **Pause Sync** in both the `copying` and `replicating` phases. Pause behaves very differently in each:

- **Phase `copying` (initial copy in progress, dashboard title "Copying data to PlanetScale"):** Warn users before they pause. Bucardo's `onetimecopy` cannot be resumed mid-table -- `bucardo pause` stops the in-flight `COPY` and `bucardo resume` restarts the initial copy from the beginning. All progress on the current table (and subsequent tables in the run) is lost. If a user needs to reduce load during the initial copy, the safer options are: wait for the copy to finish, resize to a larger Heroku Postgres plan, or **Abort Migration** and restart later.
- **Phase `replicating` with `bucardo.initial_copy_phase === "finished"` (dashboard title "Your databases are in sync"):** Pause is safe. Writes continue to be tracked in `bucardo_delta` and drain on Resume. The longer the pause, the larger the queue.
- Triggers remain active in both cases -- pause does not reduce write-side trigger overhead. Only **Abort Migration** removes triggers.

When triaging "my database is overloaded" reports, check `bucardo.initial_copy_phase` in `/status` before recommending Pause.

## Restart recovery

`entrypoint.sh` resumes automatically after a dyno/container restart, using the phase persisted in `_ps_migrator.migration_state`. For a `copying` restart it inspects Bucardo's `Onetimecopy`: if the initial copy was already done it resumes in delta mode (`--no-initial-copy`); otherwise the full copy restarts. Either way it lands the run back in the `copying` phase (not straight to `replicating`) so the status server can run its copy-complete logic -- including any **pending deferred index rebuild** -- before promoting to `replicating`. Jumping directly to `replicating` would skip the rebuild and leave the target missing those indexes.

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
- `bucardo.initial_copy_phase` -- `in-progress`, `finished`, or `unknown`. Derived from Bucardo's `Onetimecopy` line; anything other than an explicit `Yes` is treated as `finished`. If all `bucardo.*` fields are `nil`, the server failed to read Bucardo status (see "could not find a temporary directory").
- `bucardo.last_good_sync` -- Timestamp of last successful sync
- `bucardo.last_error` -- Last Bucardo error string (may be stale)
- `rebuild_config` -- Index-rebuild settings: `workers`, `workers_default`, `parallel_maintenance_workers`, `maintenance_work_mem`, `max_workers`, and `deferral_disabled` (true when `DISABLE_INDEX_DEFERRAL=true`).
- `index_rebuild` -- Live rebuild progress (`rebuildable`, `done`, `building`, `failed`, `skipped`, `failed_objects`) when present.
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
| `rebuilding_indexes` | Initial copy done; deferred indexes rebuilding (delta apply paused). | Wait. Skipped if `DISABLE_INDEX_DEFERRAL=true`. |
| `index_rebuild_failed` | One or more indexes failed to rebuild; replication paused. | Fix the issue and Retry Failed Indexes, or Proceed Anyway. |
| `replicating` | Initial copy done, real-time replication active. | Verify data, then click Switch Traffic when ready. |
| `switched` | Writes blocked on Heroku. | Optionally run **Verify Migration** (source is now frozen), update app's DATABASE_URL to PlanetScale, verify the app, then Complete or Revert. |
| `completed` | Migration done, triggers removed. | Delete the migration app. |
| `error` | Something failed. | Check error message and logs. Click Retry or Abort. |

### Cutover readiness levels

- **blocked** -- Hard blockers present (e.g., initial copy not finished, Bucardo status unavailable). Cannot proceed.
- **warning** -- Soft blockers present (e.g., replication health check failing due to stale error). Can override with the Switch Traffic button, which shows a confirmation modal.
- **ready** -- All checks pass. Safe to switch.

## Post-cutover verification

After Switch Traffic, the dashboard offers an **optional** **Verify Migration** button (`POST /verify`, polled via `GET /verify-output`) that runs [scripts/verify-migration.sh](scripts/verify-migration.sh) to compare source and target. It is **not required**, but it is the most reliable confidence check: it only runs in the `switched`/`cleaning_up`/`completed` phases, because the Heroku source must be frozen (writes revoked) for exact counts to match. Running it earlier returns 409. It is read-only — it modifies neither database — so users can re-run it freely. It usually completes in under a minute.

What it checks (high level), excluding migrator/Bucardo objects (`bucardo`, `_ps_migrator`, `pscale_extensions` schemas and `_ps_migration_state`):

- **Connections** to both databases and their server versions.
- **Tables, columns, indexes, constraints (PK/FK/UNIQUE/CHECK), sequences** -- all source objects present and matching on the target.
- **Extensions** -- present and same version.
- **Row counts** -- exact `COUNT(*)` on a **random sample of up to 10 tables under 10 GB**, each with a 60s statement timeout (so it never hangs or overloads the databases). Tables ≥10 GB are skipped by design. Estimate-based comparison (`pg_class.reltuples`) was intentionally removed: estimates can differ widely even on a correct migration and falsely alarmed users.

Result line and exit code: `ALL CHECKS PASSED` (0), `VERIFIED WITH WARNINGS` (1), or `FAILED` (2). Warnings come from extra tables/indexes on the target, an extension version mismatch, or a sampled `COUNT(*)` timing out. `FAILED` means a missing table/column/index/constraint or a real exact-count difference -- investigate before **Complete Migration**. (If a user somehow ran it before the source was fully frozen, an exact-count diff can be replication lag -- have them re-run once quiet.)

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
