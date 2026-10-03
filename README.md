# SafeGrd Backup action

Backs up a database, a folder or a mailbox from a GitHub Actions runner with
[SafeGrd](https://safegrd.dev), and restores the backup to test it. It backs up
PostgreSQL, MySQL, MariaDB, MongoDB and SQLite databases, and the folders and
mailboxes a SafeGrd config describes. The backup is encrypted on the runner
before it is uploaded, and the backup and every drill are reported to SafeGrd,
where the console shows them.

It suits a database with no server of your own beside it, such as Supabase or
another managed database: the runner is the host.

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

   To back up a folder or a mailbox, add its surface to `safegrd.yaml` first
   ([below](#folders-and-mailboxes)).

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

## MySQL, MariaDB, MongoDB and SQLite

`database-url` picks the engine by its scheme, as the CLI does:

| Scheme | Engine | Dump tool | Sandbox |
| :-- | :-- | :-- | :-- |
| `postgres://`, `postgresql://` | PostgreSQL | `pg_dump`, `postgres-version` or newer | a PostgreSQL database, created if missing |
| `mysql://`, `mariadb://` | MySQL or MariaDB | `mysqldump` or `mariadb-dump` | a MySQL or MariaDB database, created if missing |
| `mongodb://`, `mongodb+srv://` | MongoDB | `mongodump` and `mongorestore` | a MongoDB database, created by the drill |
| `sqlite:` | SQLite | none | a path to a file that does not exist yet |

When the runner has no dump tool for the engine, the action installs one:
`mysql-client` from the runner's apt sources (`mariadb-client` for a
`mariadb://` URL), or `mongodb-database-tools` from MongoDB's signed apt
repository. Any version will do, as for the CLI. On a runner without
`apt-get`, install the tool in an earlier step; the action finds it on `PATH`.

A drill job for MySQL. Use the image your server runs, `mariadb:11.4` for
MariaDB:

```yaml
  drill:
    runs-on: ubuntu-24.04
    services:
      sandbox:
        image: mysql:8.4
        env:
          MYSQL_ROOT_PASSWORD: sandbox
        ports:
          - 3306:3306
        options: >-
          --health-cmd "mysqladmin ping -h 127.0.0.1 -psandbox" --health-interval 5s
          --health-timeout 5s --health-retries 24
    steps:
      - uses: safegrd/backup-action@v1
        with:
          config: ${{ secrets.SAFEGRD_CONFIG }}
          database-url: ${{ secrets.DATABASE_URL }}
          drill: true
          sandbox-url: mysql://root:sandbox@127.0.0.1:3306/drill
```

For MongoDB, the sandbox is a `mongo` service and the URL names the database
to restore into:

```yaml
    services:
      sandbox:
        image: mongo:8
        ports:
          - 27017:27017
        options: >-
          --health-cmd "mongosh --quiet --eval 'db.runCommand({ ping: 1 })'"
          --health-interval 5s --health-timeout 5s --health-retries 24
    steps:
      - uses: safegrd/backup-action@v1
        with:
          config: ${{ secrets.SAFEGRD_CONFIG }}
          database-url: ${{ secrets.DATABASE_URL }}
          drill: true
          sandbox-url: mongodb://127.0.0.1:27017/drill
```

## Folders and mailboxes

`surface` backs up one surface of the config, the way `safegrd backup
--surface` does on a host. Set `surface` or `database-url`, not both. Add the
surface to `safegrd.yaml` before you store it as the `SAFEGRD_CONFIG` secret.

A folder of the repository, or a volume a self-hosted runner mounts:

```yaml
surfaces:
  - id: uploads
    type: files
    format: tar
    roots: [uploads]
```

```yaml
    steps:
      - uses: actions/checkout@v4
      - uses: safegrd/backup-action@v1
        with:
          config: ${{ secrets.SAFEGRD_CONFIG }}
          surface: uploads
          drill: true
```

`roots` are paths on the runner. A relative root is read from the workspace,
where `actions/checkout` puts the repository.

On a GitHub-hosted runner, each job starts with no SafeGrd state. A
`format: repo` surface keeps the list of what it uploaded in that state, so
there it uploads every file on every run, as `format: tar` does. Use `tar` on
GitHub-hosted runners, and `repo` on a self-hosted runner that keeps
`~/.safegrd` between jobs.

A mailbox:

```yaml
surfaces:
  - id: support-inbox
    type: email
    host: imap.example.com
    username: support@example.com
    credential: {from: safegrd}
```

With `from: safegrd`, SafeGrd holds the mailbox's password, encrypted, and
gives it only to this host when it backs up. The workflow needs no secret for
it. The first run registers the surface with SafeGrd and fails, because
SafeGrd holds no password for it yet. Hand the password over in the console
under **Nodes**, **Credential**, and the next run backs the mailbox up.

To keep the password in GitHub instead, name a variable in the config and set
it on the step:

```yaml
    credential: {from: env, name: SUPPORT_IMAP_PASSWORD}
```

```yaml
      - uses: safegrd/backup-action@v1
        env:
          SUPPORT_IMAP_PASSWORD: ${{ secrets.SUPPORT_IMAP_PASSWORD }}
        with:
          config: ${{ secrets.SAFEGRD_CONFIG }}
          surface: support-inbox
```

A folder or a mailbox has no sandbox. With `drill: true`, its drill reads the
whole snapshot back on the runner and checks every file or message against
the manifest written at backup time. Leave out `sandbox-url`; the action
refuses it before backing up.

## Inputs

| Input | Default | What it is |
| :-- | :-- | :-- |
| `config` | required | The host's config file, written by `safegrd enroll --config`. Pass it from a secret. |
| `database-url` | the config's | Connection string of the database to back up. Pass it from a secret. |
| `surface` | none | ID of a surface in the config to back up instead: a folder, a mailbox or a database. |
| `drill` | `false` | `true` restores the new backup and checks it. |
| `sandbox-url` | none | With `drill: true`, an empty database of the same engine to restore into. Without it, the drill restores in memory. |
| `private-key` | none | The Age identity, for a key you hold. Only the drill uses it. |
| `postgres-version` | `17` | For PostgreSQL, the major version of the server. `none` uses the runner's own client. |
| `version` | `latest` | SafeGrd CLI release to install, such as `v0.0.4`. |

## Outputs

| Output | What it is |
| :-- | :-- |
| `snapshot-id` | The ID of the snapshot this run took. |

## What it does

1. **Install SafeGrd** from the [safegrd/cli](https://github.com/safegrd/cli/releases)
   release, after checking the archive against the release's `checksums.txt`.
   A release with no checksum for the archive is refused. `latest` asks the
   GitHub API with the job's token.
2. **Write the config** to `$RUNNER_TEMP/safegrd/safegrd.yaml`, readable only by
   the job's user. The runner empties `$RUNNER_TEMP` when the job ends.
3. **Install the database client** the backup needs, read from the surface's
   type or the URL's scheme. Inputs that cannot work together, such as a
   `sandbox-url` of another engine, fail here, before anything is backed up.
   For PostgreSQL, `pg_dump` must be the server's major version or newer. When
   the runner has none that new, the action installs
   `postgresql-client-<postgres-version>` from apt.postgresql.org. That needs a
   Linux runner with `apt-get`; elsewhere, install the client in an earlier
   step and set `postgres-version: none`.
4. **Back up** with `safegrd backup`, or `safegrd backup --surface`, and set
   `snapshot-id`.
5. **Drill**, with `drill: true`: `safegrd verify` restores that snapshot into
   `sandbox-url`, or in memory. When `sandbox-url` names a PostgreSQL, MySQL or
   MariaDB database that does not exist yet, the action creates it first and
   waits up to 60 seconds for the server to accept connections.

`database-url`, `private-key` and a password set on the step's `env` reach
the CLI through the environment, not the command line, and the action prints
none of them. `sandbox-url` is passed on the command line, because it names a database
that exists for one job; the action gives its password to the MySQL client in
a file only the job's user can read.

A backup or drill that worked but that the remote server did not record is
shown as a warning on the run, with the reason in the log. The console will not
show that run. The runner keeps nothing after the job, so the record is not
sent again later.

## Versions

`@v1` moves to each compatible release of this action. To pin exactly, use a
commit SHA. `version` pins the SafeGrd CLI separately.
