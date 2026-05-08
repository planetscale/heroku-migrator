# Heroku Migration Field Notes

These notes collect production cutover issues that are easy to miss when moving
an application from Heroku Postgres to PlanetScale Postgres with the migrator.
They are not required for every migration, but they are worth reviewing before a
production cutover.

## Heroku DATABASE_URL can be an attachment alias

On Heroku apps with a Heroku Postgres add-on, `DATABASE_URL` may be owned by the
add-on attachment. In that state it is not a normal config var, and this command
can fail:

```bash
heroku config:set DATABASE_URL="postgresql://..." -a your-app-name
```

Error:

```text
Cannot overwrite attachment values DATABASE_URL.
```

Before cutover, check the app's add-ons and attachment names:

```bash
heroku addons -a your-app-name
```

If `DATABASE_URL` is still owned by the Heroku Postgres add-on, preserve access
to the old database under another attachment name before replacing
`DATABASE_URL`. The exact attachment name can vary by app, but the flow is:

```bash
# Keep an alternate URL for the old Heroku Postgres database.
heroku addons:attach <heroku-postgres-addon-name> --as HEROKU_POSTGRESQL_OLD -a your-app-name

# Detach the attachment that owns DATABASE_URL, often named DATABASE.
heroku addons:detach <database-attachment-name> -a your-app-name

# Now set DATABASE_URL to PlanetScale.
heroku config:set DATABASE_URL="postgresql://..." -a your-app-name
```

Do not discover this during the write-blocked cutover window. Rehearse the
attachment plan before clicking **Switch Traffic**.

## Use maintenance mode during cutover

The migrator's **Switch Traffic** action blocks writes on the Heroku source by
revoking write privileges. It does not update your app config, restart dynos, or
verify that all app processes are using PlanetScale.

For production apps, use maintenance mode around the handoff:

```bash
heroku maintenance:on -a your-app-name
# Click Switch Traffic in the migrator.
# Update DATABASE_URL and any database-specific config.
heroku restart -a your-app-name
# Run app smoke tests.
heroku maintenance:off -a your-app-name
```

This avoids user traffic hitting an app that is between database configs.

## Test application drivers, not only psql

PlanetScale Postgres connection strings can include libpq-style SSL query
parameters:

```text
sslmode=verify-full
sslrootcert=...
sslnegotiation=direct
```

libpq-based clients such as `psql` and psycopg understand these parameters.
Other drivers may not. For example, apps using `asyncpg` through SQLAlchemy can
fail if the same URL is converted to `postgresql+asyncpg://` without also
translating SSL configuration:

```text
TypeError: connect() got an unexpected keyword argument 'sslmode'
```

Before cutover, run smoke tests through every app database path:

- web requests
- worker jobs
- sync code paths
- async code paths
- migration or admin commands

If one driver cannot parse the PlanetScale URL, either switch that code path to
a libpq-compatible driver or translate the SSL configuration into the format the
driver expects.

## Heroku CA bundle path

`sslrootcert=system` can work in one client and fail in another, depending on
the libpq or driver version bundled with the runtime.

On Debian-based Heroku runtimes, this explicit CA bundle path is often safer for
application config:

```text
sslrootcert=/etc/ssl/certs/ca-certificates.crt
```

## Prefer pooled app connections after cutover

PlanetScale direct Postgres connections have a connection ceiling. Production
apps with multiple web dynos, worker dynos, and ORM pools can exhaust direct
connections quickly after cutover.

Use the pooled PgBouncer connection string for runtime app traffic when
available. Keep direct connections for migrations and administrative workflows
that are not compatible with PgBouncer.

Watch app logs for:

```text
too many clients
remaining connection slots are reserved
```

If these appear, reduce app pool sizes and move runtime traffic to the pooled
URL.

## Clean up old source database objects

Bucardo setup inspects database objects before it can replicate them. Old
schemas and stale tables can block setup even if the current app no longer uses
them.

Before starting setup, inspect non-system schemas:

```sql
SELECT nspname
FROM pg_namespace
WHERE nspname NOT LIKE 'pg_%'
  AND nspname <> 'information_schema'
ORDER BY nspname;
```

Clean up abandoned temporary schemas only after confirming they are truly not needed.

If stale schemas or tables cause setup to fail, aborting may leave the migration 
in a stuck state. After cleanup, start the next attempt with a fresh PlanetScale target
if the previous target was partially written.

If setup fails during table validation or row inspection, also check old temp or
staging tables for invalid encoding. Bad bytes in rarely used tables can still
break Bucardo validation. (e.g. Bucardo's validate_goat fails on Latin-1 bytes)

## Verify schema-dependent application objects

The migrator copies schema with `pg_dump --schema-only`, so ordinary schema
objects should come across during setup. Still, verify application-critical
objects on PlanetScale before cutover, especially if setup was retried, run with
`--skip-schema`, or affected by extension compatibility.

Examples to verify:

- user-defined functions used by app queries
- views used by app queries
- sequences expected by app code
- generated columns
- extension-backed objects

For functions:

```sql
SELECT n.nspname, p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n.nspname, p.proname;
```

If a runtime query depends on a function such as `some_custom_function()`, confirm it
exists and behaves the same on PlanetScale before switching traffic.

## Generated columns

This migrator includes generated-column handling for
PostgreSQL `GENERATED ALWAYS AS ... STORED` columns.
