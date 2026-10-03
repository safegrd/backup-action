# SafeGrd Backup action

Backs up a PostgreSQL database from a GitHub Actions runner with
[SafeGrd](https://safegrd.dev), and restores the backup to test it. The dump is
encrypted on the runner before it is uploaded, and the backup and every drill
are reported to SafeGrd, where the console shows them.

It suits a database with no server of your own beside it, such as Supabase or
another managed Postgres: the runner is the host.

```yaml
- uses: safegrd/backup-action@v1
  with:
    config: ${{ secrets.SAFEGRD_CONFIG }}
    database-url: ${{ secrets.DATABASE_URL }}
```

## Setup

1. **Register the workflow as a host**, once, from your laptop. Create a token
   in the SafeGrd console under **Tokens**, then in an empty folder:

   ```sh
   safegrd enroll --config ./safegrd.yaml --token sg_pat_... --node-name ci-prod \
     --storage hosted --key-custody safegrd
   ```

   This writes `safegrd.yaml`, which holds the host's token and the public key,
   and the key itself to `keys/daemon.key`. The private key is never written to
   `safegrd.yaml`.

   `--key-custody` decides who holds the key that decrypts the backups:

   - `safegrd`: SafeGrd keeps your key sealed and releases it only to your
     enrolled hosts, so you can restore even after losing a host. The workflow
     needs no key of its own.
   - `local`: only you can decrypt these backups. The drill needs the key as
     a secret, and the backup never does. Keep a copy of `keys/daemon.key`
     somewhere safe.

   `--storage hosted` writes to SafeGrd's locked bucket. To use your own S3
   bucket with Object Lock, see [Storage and retention](https://safegrd.dev/docs/storage).

2. **Add the secrets**, with the [GitHub CLI](https://cli.github.com/):

   ```sh
   gh secret set SAFEGRD_CONFIG < safegrd.yaml
   gh secret set DATABASE_URL            # asks for the connection string
   gh secret set SAFEGRD_PRIVATE_KEY < keys/daemon.key   # only with --key-custody local
   ```

3. **Add a workflow** (below), and run it once from the **Actions** tab.

## Back up every night, drill every week

```yaml
name: Database backup

on:
  schedule:
    - cron: "17 3 * * *"   # backup, every day at 03:17 UTC
    - cron: "47 4 * * 1"   # drill, Mondays at 04:47 UTC
  workflow_dispatch:

concurrency:
  group: database-backup
  cancel-in-progress: false

jobs:
  backup:
    if: github.event.schedule != '47 4 * * 1'
    runs-on: ubuntu-24.04
    steps:
      - uses: safegrd/backup-action@v1
        with:
          config: ${{ secrets.SAFEGRD_CONFIG }}
          database-url: ${{ secrets.DATABASE_URL }}
          postgres-version: "17"

  drill:
    if: github.event.schedule == '47 4 * * 1'
    runs-on: ubuntu-24.04
    services:
      sandbox:
        image: postgres:17
        env:
          POSTGRES_PASSWORD: sandbox
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready --health-interval 5s --health-timeout 5s --health-retries 24
    steps:
      - uses: safegrd/backup-action@v1
        with:
          config: ${{ secrets.SAFEGRD_CONFIG }}
          database-url: ${{ secrets.DATABASE_URL }}
          postgres-version: "17"
          drill: true
          sandbox-url: postgres://postgres:sandbox@localhost:5432/drill?sslmode=disable
          # Only with a key you hold:
          # private-key: ${{ secrets.SAFEGRD_PRIVATE_KEY }}
```

The drill job backs up, then restores that backup into the `sandbox` service
and checks every table's row count against the manifest written at backup time.
The sandbox exists for this job only. Without `sandbox-url`, the drill restores
in memory and needs no service.

How often SafeGrd records a drill, and whether a drill may load a sandbox
database, depends on your plan ([pricing](https://safegrd.dev/pricing)). A drill
beyond that is run and reported as not recorded, so match the drill's schedule
to your plan.

For Supabase, see the [Supabase guide](https://safegrd.dev/guides/supabase-backup-github-actions):
its sandbox runs Supabase's own image.

## Inputs

| Input | Default | What it is |
| :-- | :-- | :-- |
| `config` | required | The host's config file, written by `safegrd enroll --config`. Pass it from a secret. |
| `database-url` | the config's | Connection string of the database to back up. Pass it from a secret. |
| `drill` | `false` | `true` restores the new backup and checks it. |
| `sandbox-url` | none | With `drill: true`, an empty PostgreSQL database to restore into. Without it, the drill restores in memory. |
| `private-key` | none | The Age identity, for a key you hold. Only the drill uses it. |
| `postgres-version` | `17` | Major version of the server you back up. `none` uses the runner's own client. |
| `version` | `latest` | SafeGrd CLI release to install, such as `v0.0.4`. |

## Outputs

| Output | What it is |
| :-- | :-- |
| `snapshot-id` | The ID of the snapshot this run took. |

## What it does

1. **Install the PostgreSQL client.** `pg_dump` must be the server's major
   version or newer. When the runner has none that new, the action installs
   `postgresql-client-<postgres-version>` from apt.postgresql.org. That needs a
   Linux runner with `apt-get`; elsewhere, install the client in an earlier
   step and set `postgres-version: none`.
2. **Install SafeGrd** from the [safegrd/cli](https://github.com/safegrd/cli/releases)
   release, after checking the archive against the release's `checksums.txt`.
   A release with no checksum for the archive is refused. `latest` asks the
   GitHub API with the job's token.
3. **Write the config** to `$RUNNER_TEMP/safegrd/safegrd.yaml`, readable only by
   the job's user. The runner empties `$RUNNER_TEMP` when the job ends.
4. **Back up** with `safegrd backup`, and set `snapshot-id`.
5. **Drill**, with `drill: true`: `safegrd verify` restores that snapshot into
   `sandbox-url`, or in memory. When `sandbox-url` names a database that does
   not exist yet, the action creates it first, connecting to the same server's
   `postgres` database, and waits up to 60 seconds for the server to accept
   connections.

`database-url` and `private-key` reach the CLI through the environment, not the
command line, and the action prints neither. `sandbox-url` is passed on the
command line, because it names a database that exists for one job.

A backup or drill that worked but that the remote server did not record is
shown as a warning on the run, with the reason in the log. The console will not
show that run.

## Versions

`@v1` moves to each compatible release of this action. To pin exactly, use a
commit SHA. `version` pins the SafeGrd CLI separately.
