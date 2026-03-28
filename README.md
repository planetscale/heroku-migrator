[![Deploy to Heroku](https://www.herokucdn.com/deploy/button.svg)](https://www.heroku.com/deploy?template=https://github.com/planetscale/heroku-migrator)

# Migrate from Heroku Postgres to PlanetScale

This tool helps you migrate your Heroku Postgres database to [PlanetScale](https://planetscale.com) with minimal downtime. It runs as a temporary Heroku app that copies your data and keeps both databases in sync until you're ready to cut over.

## How does it work?

This app uses [Bucardo](https://bucardo.org/Bucardo/), an open-source PostgreSQL replication tool, to copy your data and keep it in sync in real-time. When you're ready, you switch your app to PlanetScale and tear down the replication. The whole process is managed through a web dashboard.

## Before you start

There are a few things to prepare before deploying the migrator.

### 1. Get your Heroku database credentials

You'll need your Heroku Postgres connection URL. Run this command to get it:

```bash
heroku config:get DATABASE_URL -a your-app-name
```

It will look something like:

```
postgres://username:password@host:5432/dbname
```

Copy this value. You'll paste it as the `HEROKU_URL` when deploying the migrator.

### 2. Create your PlanetScale database and get credentials

Follow the [PlanetScale Postgres quickstart guide](https://planetscale.com/docs/postgres/tutorials/planetscale-postgres-quickstart) to create a database and generate a password. When creating the password, make sure you select the **Postgres** permission. Copy the Postgres connection string. This is your `PLANETSCALE_URL`.

### 3. Check your Heroku Postgres extensions

Bucardo replicates your data, but it doesn't install Postgres extensions. You'll need to make sure any extensions you use on Heroku are also enabled on PlanetScale **before** starting the migration.

Run this command to see which extensions your Heroku database uses:

```bash
heroku pg:psql -a your-app-name -c "SELECT extname, extversion FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;"
```

For each extension listed, enable it on your PlanetScale database before starting the migration. See the [PlanetScale Postgres extensions documentation](https://planetscale.com/docs/postgres/extensions) for supported extensions and how to enable them. If you need help, [contact us](https://planetscale.com/contact).

### 4. Check for blocking vacuum processes

Bucardo creates triggers on your Heroku tables to track changes. In rare cases, a long-running autovacuum process can block trigger creation, which can also block your application's queries. Before starting the migration, check for wraparound vacuum processes:

```bash
heroku pg:locks -a your-app-name
```

If you see any `VACUUM` queries with `(to prevent wraparound)` in the output, wait for them to finish before starting the migration.

### 5. Size your PlanetScale database

**Cluster size:** Choose a PlanetScale cluster with similar CPU and RAM to your Heroku Postgres plan. You don't need to get this exactly right. [Resizing in PlanetScale is an online operation](https://planetscale.com/docs/postgres/cluster-configuration) with no downtime, and you are only billed for the time you use.

**Storage:** Make sure your PlanetScale database has at least **twice the storage** that Heroku reports using. Bucardo is not very space-efficient during migration, and Postgres disk usage can vary significantly between providers. It's not uncommon for a database to use 50% more or less space on PlanetScale than on Heroku. Automatic vacuuming will reclaim the extra space over time after the migration completes.

To check your current Heroku storage usage:

```bash
heroku pg:info -a your-app-name
```

Look for the "Data Size" field. If your Heroku database uses 10 GB, provision at least 20 GB on PlanetScale.

You can adjust your PlanetScale storage at any time via the [Storage tab in Cluster Configuration](https://planetscale.com/docs/postgres/cluster-configuration/cluster-storage).

### 6. Consider your database size and performance

This tool uses **trigger-based replication**. When the migration starts, Bucardo installs triggers on your Heroku database tables. These triggers track every insert, update, and delete so changes can be replicated to PlanetScale.

What this means for your Heroku database:

- **Small to medium databases** (under 10 million rows): You likely won't notice any performance impact. The triggers add negligible overhead.
- **Large databases** (tens of millions to billions of rows): The initial data copy puts additional read load on your Heroku database. The triggers add a small amount of write overhead. For most workloads this is fine, but if your database is already under heavy load, consider:
  - **Upgrade your Heroku Postgres plan temporarily.** A larger plan gives your database more headroom during the migration. You can downgrade or remove it once you're done.
  - **Run the migration during off-peak hours.** Start the initial copy when your app has less traffic.
  - **Use the Pause button (with caveats).** The migration dashboard has a Pause Sync button that stops data transfer to PlanetScale. However, pausing does **not** remove Bucardo's triggers from your Heroku database. Every write still fires the trigger and records changes into tracking tables, so the per-write overhead remains. Pausing reduces the migrator's read load on Heroku but does not eliminate the write-side cost. If you need to fully remove the trigger overhead, use the **Abort Migration** button in the dashboard.

### 7. Heroku's 24-hour restart limit

Heroku restarts every dyno at least once every 24 hours. If a restart happens during the initial data copy, the copy starts over from the beginning.

Copy speed varies by database, but most users can expect around **100 GB per hour**. Actual throughput depends on the number and size of indexes, average row width, network conditions between Heroku and PlanetScale, and the configuration of the target database. A 500 GB database might finish in 5 hours or might take 8+, depending on these factors.

If your Heroku database is large enough that the initial copy could take close to or longer than 24 hours, **do not deploy this tool on Heroku**. Instead, run the container somewhere that won't force-restart it, such as an AWS EC2 instance, ECS task, or GCP VM. The container is standard Docker, so deploying elsewhere is just `docker run` with the same environment variables:

```bash
docker build -t heroku-migrator .
docker run -d \
  -e HEROKU_URL="postgres://..." \
  -e PLANETSCALE_URL="postgresql://..." \
  -e PASSWORD="your-password" \
  -p 8080:8080 \
  heroku-migrator
```

For databases under ~1 TB, Heroku is typically fine. For anything larger, use a host without forced restarts to avoid re-copying data.

### 8. Optional preflight SQL checks (recommended)

If you want extra confidence before cutover, run these checks on your source Heroku database:

```bash
# 1) Verify non-default extensions in use
heroku pg:psql -a your-app-name -c "SELECT extname, extversion FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;"
```

```bash
# 2) Verify the migrator role can read/write tables (for realistic validation runs)
heroku pg:psql -a your-app-name -c "SELECT table_name, has_table_privilege(current_user, format('public.%I', table_name), 'SELECT,INSERT,UPDATE,DELETE') FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name;"
```

```bash
# 3) Optional table sanity snapshot
heroku pg:psql -a your-app-name -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;"
```

If table privileges are missing for your chosen `HEROKU_URL` user, the migration setup may work but end-to-end validation can be incomplete.

## Deploy to Heroku

Click the button at the top of this page, or deploy manually:

1. Clone this repository:
   ```bash
   git clone https://github.com/planetscale/heroku-migrator.git
   cd heroku-migrator
   ```
2. Create a Heroku app with the container stack:
   ```bash
   heroku create my-migration --stack container
   ```
3. Set the required config vars:
   ```bash
   heroku config:set \
     HEROKU_URL="postgres://..." \
     PLANETSCALE_URL="postgresql://..." \
     PASSWORD="choose-a-password"
   ```
4. Deploy:
   ```bash
   git push heroku main
   ```
5. Resize the dyno (recommended for most migrations):
   ```bash
   heroku ps:resize web=standard-2x -a my-migration
   ```
6. Open the dashboard:
   ```bash
   heroku open
   ```

You'll be prompted for a password. Enter the `PASSWORD` you set above. The username is `admin`.

### Which dyno size should I use?

The migrator runs PostgreSQL and Bucardo inside the dyno, so it needs more memory than a typical web app. Memory usage scales with **write volume**, not just data size -- high-write databases produce more delta tracking data for Bucardo to process.

- **Standard-1x (512 MB)**: Small databases with low write volume (under 1 million rows, fewer than 20 tables).
- **Standard-2x (1 GB)**: Most migrations with moderate write volume.
- **Performance-M (2.5 GB)**: Large databases, high write throughput, many tables, or if you see R14 memory errors on Standard-2x.
- **Performance-L (14 GB)**: Very large databases (100+ GB) with high-write, high-contention tables. If your Heroku database is already under heavy load, start here.

This is a temporary app. You'll delete it after the migration is complete, so the cost is minimal. When in doubt, start with Performance-M.

**Watch for R14 memory errors.** If the migrator dyno runs out of memory, Bucardo can't keep up with replication, causing delays to grow and potentially cascading into performance issues on your Heroku database. Monitor with:

```bash
heroku logs --tail -a my-migration | grep R14
```

If you see R14 errors, resize immediately:

```bash
heroku ps:resize web=performance-l -a my-migration
```

## How the migration works

Once you open the dashboard and click **Start Migration**, the process follows these steps:

### Step 1: Setup

The migrator copies your database structure (tables, indexes, constraints) from Heroku to PlanetScale and configures Bucardo replication. This is fully automatic and typically takes a minute or two.

### Step 2: Data sync

All existing rows are copied from Heroku to PlanetScale (the "initial copy"). Once that finishes, Bucardo enters real-time replication mode. Every new write to your Heroku database is automatically replicated to PlanetScale.

Your Heroku app continues running normally throughout this entire process. You don't need to do anything until you're ready to switch.

For large databases, the initial copy can take hours. The dashboard shows progress and you can safely close the browser and come back later. If you need to reduce load on your Heroku database, use the **Pause Sync** button. This stops data transfer to PlanetScale, but Bucardo's triggers remain active on Heroku -- every write still has trigger overhead. Changes are tracked while paused and will catch up when you resume. If your database is severely impacted and you need to fully remove the triggers, use the **Abort Migration** button instead.

### Step 3: Switch traffic

When the dashboard shows your databases are in sync, you're ready to cut over. Click **Switch Traffic** to block writes on your Heroku database. This runs a SQL `REVOKE` command that removes `INSERT`, `UPDATE`, and `DELETE` privileges from your Heroku database user:

```sql
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM your_heroku_user;
```

After this, your app can still **read** from Heroku, but any **write** query will fail with a permission error. This ensures no new data is written to Heroku while you switch over.

Then update your app to use PlanetScale:

```bash
heroku config:set DATABASE_URL="your-planetscale-connection-string" -a your-app-name
```

Your app restarts and begins using PlanetScale. Test it to make sure everything works.

If something goes wrong, click **Revert Switch** in the dashboard. This runs the inverse `GRANT` command to restore write access to your Heroku database, so your app can write to Heroku again immediately.

During **Switch Traffic** or **Revert Switch**, you may see PostgreSQL warnings about `pg_stat_statements` privileges in the dashboard/API output. These warnings are expected on some Heroku Postgres setups and do not mean the switch or revert failed.

### Step 4: Complete

Once you've verified everything is working on PlanetScale, click **Complete Migration** in the dashboard. This removes Bucardo's replication triggers from your Heroku database.

After that:

1. Delete the migration app: `heroku apps:destroy my-migration`
2. Remove the Heroku Postgres add-on from your main app when you're confident everything is working.

## Running another migration (rerun)

If you want to run another migration test after finishing one:

1. Create a fresh PlanetScale target (database/branch and credentials) and use that as the new `PLANETSCALE_URL`.
2. Keep or reset `HEROKU_URL` depending on your source test dataset.
3. Update the migrator app config vars:
   ```bash
   heroku config:set \
     HEROKU_URL="postgres://..." \
     PLANETSCALE_URL="postgresql://..." \
     PASSWORD="your-password" \
     -a my-migration
   ```
4. Open the dashboard and start a new run.

Using a fresh PlanetScale target for each rerun keeps validation clean and avoids mixing data from previous migration attempts.

## Verify cleanup completed

After **Complete Migration**, you can confirm Bucardo objects were removed from the source:

```sql
SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'bucardo_%';
SELECT count(*) FROM pg_namespace WHERE nspname = 'bucardo';
```

Expected result for both queries: `0`.

## Expected warnings vs failures

Some output looks alarming but is expected:

- **Usually safe to ignore:** warnings about `pg_stat_statements` privileges during **Switch Traffic** / **Revert Switch**.
- **Requires action:** authentication failures, SSL/certificate errors, inability to find/start Bucardo sync, or repeated `phase=error` in dashboard status.

When in doubt, use the dashboard logs first, then verify current phase/state in the Details panel before retrying an action.

## Typical timing by phase

Actual durations depend on table count, row size, indexes, and source database load.

- **Setup (schema + Bucardo config):** often 30 seconds to a few minutes.
- **Initial copy:** from minutes to hours on large databases.
- **Validation checks:** sampled SQL checks and application smoke tests are recommended after initial copy and during replication.
- **Switch/Revert/Cleanup actions:** usually seconds to a minute.

Plan migration windows around the **initial copy** and your post-copy validation checklist.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `HEROKU_URL` | Yes | Heroku Postgres connection URL |
| `PLANETSCALE_URL` | Yes | PlanetScale Postgres connection URL |
| `PASSWORD` | Yes | Password to access the migration dashboard |
| `DISABLE_NOTIFICATIONS` | No | Set to `true` to disable migration progress notifications to PlanetScale (enabled by default) |

## What is Bucardo?

[Bucardo](https://bucardo.org/Bucardo/) is an open-source PostgreSQL replication system that uses triggers to track changes. When a row is inserted, updated, or deleted on the source database, Bucardo's triggers record the change and asynchronously replicate it to the target.

This approach is useful for migrations because:

- **No downtime during the copy phase.** Your app keeps running while data is being replicated.
- **Works with any PostgreSQL host.** Bucardo doesn't need special configuration on the source or target. It just needs standard PostgreSQL connections.
- **Handles large databases.** The initial copy runs in the background and ongoing replication handles the delta.

The trade-off is that triggers add a small amount of overhead to every write on your source database. For most workloads this is negligible, but for write-heavy databases under heavy load, you'll want to monitor performance. Note that pausing replication stops data transfer but does **not** remove the triggers -- every write still has trigger overhead while paused. If you need to fully stop the impact on your source database, use the **Abort Migration** button in the dashboard to remove all triggers.

## Can I connect this to a Heroku follower/replica?

No. The migrator must connect to your **primary** Heroku Postgres database.

Bucardo works by installing triggers on the source database tables. These triggers fire on every INSERT, UPDATE, and DELETE to record changes for replication. Installing triggers requires write access to the database (Bucardo also creates a `bucardo` schema and tracking tables on the source).

Heroku followers are read-only replicas. You cannot create triggers, schemas, or tables on them. If you point the migrator at a follower, the setup step will fail when it tries to install triggers.

Use the connection URL for your primary database (`DATABASE_URL`), not a follower.

## Need help?

We offer **complimentary hands-on migration assistance** for Heroku migrations on a case-by-case basis. [Reach out to learn more](https://planetscale.com/contact).

If you prefer to run Bucardo manually instead of using this tool, see the [migration scripts on GitHub](https://github.com/planetscale/migration-scripts).

## Local development

```bash
docker build -t heroku-migrator .
docker run -it \
  -e HEROKU_URL="postgres://user:pass@host:5432/dbname" \
  -e PLANETSCALE_URL="postgresql://user:pass@host:5432/dbname?sslmode=require" \
  -e PASSWORD="your-password" \
  -p 8080:8080 \
  heroku-migrator
```
