# pg_cron for CloudNativePG

A container image that packages the [`pg_cron`](https://github.com/citusdata/pg_cron) PostgreSQL extension for use with [CloudNativePG](https://cloudnative-pg.io/) **image volume extensions**.

The image contains only the extension files (no OS, no PostgreSQL), taken from the official [PGDG](https://apt.postgresql.org/) `postgresql-18-cron` package. CloudNativePG mounts it into the Postgres pods as a read-only image volume, so you can add `pg_cron` to a cluster without building a custom PostgreSQL operand image.

## What's inside

| Component        | Version                                          |
| ---------------- | ------------------------------------------------ |
| PostgreSQL       | 18 (installed on `ghcr.io/cloudnative-pg/postgresql:18.7-minimal-trixie`) |
| pg_cron          | `1.6.8` (configurable via `PG_CRON_VERSION`)     |
| Architectures    | `linux/amd64`, `linux/arm64`                     |

Image layout, which follows the CloudNativePG extension image convention:

```
/
├── lib/
│   └── pg_cron.so
└── share/
    └── extension/
        ├── pg_cron.control
        └── pg_cron--*.sql
```

## Requirements

- CloudNativePG 1.27 or later (image volume extension support)
- PostgreSQL 18 operand image
- Kubernetes 1.33 or later with the `ImageVolume` feature enabled

## Building

```sh
docker build -t ghcr.io/tusk-contrib/pg_cron:v1.6.8-18.7-minimal-trixie .
docker push ghcr.io/tusk-contrib/pg_cron:v1.6.8-18.7-minimal-trixie
```

To build a different release, override the version:

```sh
docker build --build-arg PG_CRON_VERSION=1.6.8 -t ghcr.io/tusk-contrib/pg_cron:v1.6.8-18.7-minimal-trixie .
```

The version must be one the PGDG repository still has (`apt-cache madison postgresql-18-cron`). PGDG keeps only recent package versions, so older pins eventually stop building.

The build has two stages:

1. **builder**: starts from the CloudNativePG PostgreSQL 18 image, which already has the PGDG apt repository configured, installs `postgresql-18-cron=<PG_CRON_VERSION>-*`, and copies the `.so`, `.control`, and SQL files into the image volume layout.
2. **final**: a `scratch` image that holds only those files.

Nothing is compiled, so multi-arch builds under QEMU are fast.

### PostgreSQL minor version compatibility

The PGDG package is compiled against the latest PostgreSQL 18 minor release, and the resulting `pg_cron.so` can use server symbols that older minor releases lack. pg_cron 1.6.8 needs `heap_datum_check`, which first appears in 18.7, so on an 18.6 server it fails to load with `undefined symbol: heap_datum_check`. Because of this:

- The base image tag must be the latest PostgreSQL 18 minor release. If installing pg_cron would upgrade the `postgresql-18` package in the builder, the build fails with a message asking you to bump the base image.
- The operand image (`imageName`) must be **at least** the minor version in the extension image tag (e.g. `18.7` or later for `v1.6.8-18.7-minimal-trixie`).

`pg_cron.so` only links against `libpq`, `libc` and their dependencies, which are already present in the CloudNativePG operand image.

> The PostgreSQL major version (18) is hardcoded in the Dockerfile. To target another major version, change the base image tag, the `postgresql-18` / `postgresql-18-cron` package name, and the `/usr/lib/postgresql/<major>` and `/usr/share/postgresql/<major>` paths.

## Usage with CloudNativePG

pg_cron runs a background worker, so it **must be preloaded** through `shared_preload_libraries`. Changing that setting restarts the cluster. The worker runs in a single database, set by `cron.database_name` (default `postgres`), and the extension must be created in that same database.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-cron
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:18-minimal-trixie
  instances: 1
  storage:
    size: 1Gi
  postgresql:
    extensions:
      - name: pg_cron
        image:
          reference: ghcr.io/tusk-contrib/pg_cron:v1.6.8-18.7-minimal-trixie
    shared_preload_libraries:
      - pg_cron
    parameters:
      cron.database_name: app
      # Run jobs through background workers instead of libpq connections
      # (avoids needing pg_hba / password setup for localhost connections)
      cron.use_background_workers: "on"
      max_worker_processes: "20"
```

Create the extension in the `cron.database_name` database, either declaratively with a `Database` resource:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: cluster-cron-app
spec:
  name: app
  owner: app
  cluster:
    name: cluster-cron
  extensions:
    - name: pg_cron
```

or manually with SQL:

```sql
CREATE EXTENSION pg_cron;
```

To let a non-superuser (such as the `app` owner) schedule jobs:

```sql
GRANT USAGE ON SCHEMA cron TO app;
```

## Example

```sql
-- Delete old data every Saturday at 03:30 (GMT)
SELECT cron.schedule('nightly-vacuum', '30 3 * * 6', $$DELETE FROM events WHERE created_at < now() - interval '1 week'$$);

-- Run every 30 seconds
SELECT cron.schedule('heartbeat', '30 seconds', 'SELECT 1');

-- Inspect jobs and their runs
SELECT * FROM cron.job;
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- Remove a job
SELECT cron.unschedule('heartbeat');
```

See the [upstream pg_cron documentation](https://github.com/citusdata/pg_cron) for all functions and settings.

## Credits

- [pg_cron](https://github.com/citusdata/pg_cron) by Citus Data / Microsoft
- [CloudNativePG](https://cloudnative-pg.io/)
