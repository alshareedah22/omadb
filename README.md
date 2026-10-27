# OmaDBngin: local database servers for Omarchy

![OmaDBngin: local database servers, one click away in the Omarchy bar](preview.png)

A DBngin-style database manager for the Omarchy bar. Click the 󰆼 icon to:

- **Create** a server: choose how it runs (**native engine** or **Docker
  container**), an engine (PostgreSQL, PostGIS, MySQL, MariaDB, Redis, Valkey, MongoDB),
  a version, a name, a port, and the **username and password** to use. A free port is suggested
  automatically, so several versions of the same engine run side by side.
- **Start / stop** it with the switch
- **See** its username and password (󰌆), **copy** its connection URL with them (󰆏), open its **CLI client** in a terminal (),
  follow its **logs** (󰦪)
- Make it **start with the system** (󰐥)
- **Open** it in [OmaTablePlus](https://github.com/alshareedah22/omatableplus) (, when OmaTablePlus is installed)
- **Delete** it and its data (󰆴, click twice)

Each running server shows its uptime, memory and data size; a failed one shows the
last error from its log. The  button opens its tools:

- **Back up** every database to `~/Downloads/<name>-<date>.sql` (Redis/Valkey: an
  `.rdb` snapshot). MongoDB backups are made in OmaTablePlus (*Database ▾ → Back up*).
- **Restore** one of the listed backups (click twice). SQL dumps run against the server;
  an RDB snapshot replaces the Redis/Valkey data.
- **Move to port**: the server gets a new port and restarts if it was running (Docker
  servers are recreated on the same volume, so the data stays).

The bar shows how many servers are running; hover for the list.

## Native or Docker

**Native engine** (default) works like DBngin: no Docker, no root, no system
packages.

- The first server of a version downloads the official build once, into
  `~/.local/share/omadbngin/engines/<engine>/<version>/` (versions marked 󰇚 in the
  panel are not downloaded yet). Later servers of that version reuse it.
- Each server gets its own data directory in `~/.local/share/omadbngin/servers/<name>/`
  and runs as the systemd user service `omadbngin-<name>.service`.
  *Start with system* enables that service (it starts when you log in), and
  logs come from `journalctl --user -u omadbngin-<name>`.

| Engine     | Native build                                       |
|------------|----------------------------------------------------|
| PostgreSQL | [theseus-rs/postgresql-binaries](https://github.com/theseus-rs/postgresql-binaries) (relocatable upstream builds) |
| MySQL      | Official `minimal` tarball (glibc 2.28; glibc 2.17 for 8.0) |
| MariaDB    | Official `linux-systemd-x86_64` tarball              |
| Redis      | Built from the official source release (about a minute) |
| Valkey     | Official prebuilt release                            |
| MongoDB    | Official Ubuntu tarball (24.04; 22.04 for 7.0), plus `mongosh` |

**Pinned and verified.** Every build is pinned in [`engines.lock`](engines.lock):
exact version, download URL and SHA-256, taken from what each upstream publishes
(GitHub release digests, MariaDB's API, MongoDB's `full.json`, `redis-hashes`,
Valkey's `.sha256` files; MySQL publishes no SHA-256, so those are hashed when the
lock is made). OmaDBngin never downloads anything that isn't in the lock, and nothing is
unpacked, built or run unless its checksum matches; a mismatch stops the install and
leaves nothing behind. New versions arrive with plugin updates; maintainers
regenerate the lock with `tools/update-engines-lock native` and review the diff.

**Docker container** runs the official image as a container named `omadbngin-<name>`,
labelled `omadbngin.managed=1`, with its data in the volume `omadbngin-<name>`.
*Start with system* sets its restart policy to `unless-stopped`.

**Images pinned by digest.** Docker servers don't run a bare tag such as `postgres:17`,
which upstream can move at any time. The `docker` section of [`engines.lock`](engines.lock)
pins every engine version to its repository, tag and the SHA-256 digest of the tag's
multi-arch index, and dbctl runs `<repository>:<tag>@sha256:<digest>`, so Docker refuses
anything that doesn't match. A version without a pin is refused, the same as a native build
missing from the lock. Moving a server to another port or restoring a Redis/Valkey snapshot
keeps the exact image the container was made with; containers made before 1.6.1 (tag only)
keep the image they already run, now named by its digest. New image digests arrive with
plugin updates; maintainers refresh them with `tools/update-engines-lock docker`
(`native` for the native builds only, no argument for both) and review the diff.

**PostGIS** is Docker only (the native PostgreSQL builds have no PostGIS). It runs the
official [`postgis/postgis`](https://hub.docker.com/r/postgis/postgis) image, PostgreSQL
18, 17, 16, 15 or 14 with PostGIS 3.6 (versions `18-3.6` … `14-3.6`), with the extension
already on in the `postgres` database. Everything else treats it as PostgreSQL: the
connection URL, the `psql` client, backups and restores, and OmaTablePlus.

Either way, servers listen on `127.0.0.1` only, stop and start keep the data,
and only Delete removes it. Servers OmaDBngin did not create are never touched.

## Username and password

Leave them empty for the usual passwordless development defaults, or set your own:

| Engine          | Default user         | What a username / password does |
|-----------------|----------------------|---------------------------------|
| PostgreSQL / PostGIS | `postgres`      | That user is the superuser; a password turns on `scram-sha-256` auth |
| MySQL / MariaDB | `root`               | Another name creates that user with all privileges; a password is also set on `root` |
| Redis / Valkey  | `default`            | A password sets `requirepass`; another name creates an ACL user with full access and turns `default` off |
| MongoDB         | none (no auth)       | Creates a `root` user in `admin` and turns on auth; needs a password |

Passwords can use any characters except spaces, quotes, backslashes and `$`.
The 󰌆 button shows them, the copied URL includes them (URL-encoded), and the CLI
client logs in with them. They are kept with the server (`server.json`, mode 600, for
native; container labels for Docker), so this is for local development, not secrets.

Other local accounts never see them: dbctl hands passwords to the engines' tools through
the environment, stdin or mode-600 files, never on a command line (where `ps` shows them
to everyone), and the test suite watches every command line on the machine to make sure.
Users are set up before a server listens on TCP: MySQL/MariaDB with networking off, and
MongoDB with auth on from the start, on a private socket, so nobody can slip in first.
From a script, give `dbctl create` the password in `OMADBNGIN_PASSWORD` rather than as an
argument.

Servers listen on `127.0.0.1` only.

## Requirements

- Omarchy 4 (the Quickshell-based `omarchy-shell` bar)
- `curl`, `jq`, `ss`, `wl-copy`, `make` and `gcc`, which ship with Omarchy
- For Docker mode only: Docker, running, with your user in the `docker` group
  (`omarchy install docker`)

## Coming from OmaDB

This plugin used to be called OmaDB (`blackcode.omadb`). Install OmaDBngin, remove the old plugin
(`omarchy plugin remove blackcode.omadb`) and open the panel: the first run moves everything over once.

- Native servers: `~/.local/share/omadb` becomes `~/.local/share/omadbngin` (engines and data), and each
  `omadb-<name>.service` is replaced by `omadbngin-<name>.service`, keeping autostart and whether it was running.
- Docker servers: each `omadb-<name>` container is recreated as `omadbngin-<name>` from the same image, with its
  data copied into a new `omadbngin-<name>` volume. The old volume is kept until you remove it
  (`docker volume rm omadb-<name>`); dbctl prints the command.

## Install

From git:

```bash
omarchy plugin add https://github.com/alshareedah22/omadbngin.git --enable
```

Or from a local copy:

```bash
mkdir -p ~/.config/omarchy/plugins/blackcode.omadbngin
cp manifest.json Panel.qml DbState.qml qmldir dbctl engines.lock icon.svg LICENSE ~/.config/omarchy/plugins/blackcode.omadbngin/
omarchy plugin enable blackcode.omadbngin --section right
```

## Command line

```bash
dbctl state                                  # JSON: docker status, engines, servers
dbctl create postgresql 17 app-db 5433 on native app s3cret   # or docker; empty port = next free one
dbctl install mysql 8.4                      # download a native engine ahead of time
dbctl start|stop|restart app-db
dbctl url app-db                             # postgresql://postgres@127.0.0.1:5433/postgres
dbctl client app-db
dbctl backup app-db [file]                   # default ~/Downloads/app-db-<date>.sql
dbctl restore app-db ~/Downloads/app-db-20261026-101500.sql
dbctl backups app-db                         # JSON list of its backups, newest first
dbctl set-port app-db 5440
dbctl remove app-db [--keep-data]
```

## Tests

```bash
tests/test-dbctl.sh                 # every engine, native and Docker (~15 min)
tests/test-dbctl.sh native redis    # one mode, chosen engines
tests/test-migration.sh             # moving native and Docker servers over from OmaDB
```

Creates throwaway `zt-*` servers and checks, from the host over TCP: the right
password works and wrong or missing ones are refused, data survives stop/start
and restart, autostart, the URL, the CLI client and logs, port allocation,
ordering, input validation, that every native build and Docker image is pinned in
`engines.lock` (and that an unpinned one is refused), and that delete leaves nothing behind.

## Remove

Removing the plugin does not stop your database servers: native servers are systemd user
services and Docker servers restart on their own, and both keep their data. So delete them
first, while `dbctl` is still installed (in the panel, or for all of them at once):

```bash
D=~/.config/omarchy/plugins/blackcode.omadbngin/dbctl
for s in $("$D" state | jq -r '.services[].name'); do "$D" remove "$s"; done
omarchy plugin remove blackcode.omadbngin
```

Then, if you want the disk space back (this deletes all server data and backups made with
"keep data"):

```bash
rm -rf ~/.local/share/omadbngin          # downloaded engines, servers, *.removed-<date> folders
docker ps -a --filter label=omadbngin.managed=1   # should be empty
docker volume ls --filter name=omadbngin-          # remove any left with: docker volume rm <name>
docker volume ls --filter name=omadb-              # volumes kept from the 1.x migration
```

Backups you exported stay in `~/Downloads`. If you removed the plugin first, the servers keep
running from `~/.local/share/omadbngin`; stop each native one with
`systemctl --user disable --now omadbngin-<name>.service` (then delete its file in
`~/.config/systemd/user/`) and each Docker one with `docker rm -f <container>`.

Passwords are stored for the panel and OmaTablePlus: in each server's `server.json` (mode 600)
and, for Docker servers, as a container label that members of the `docker` group can read.
