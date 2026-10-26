# OmaDBngin: local database servers for Omarchy

![OmaDBngin: local database servers, one click away in the Omarchy bar](preview.png)

A DBngin-style database manager for the Omarchy bar. Click the 󰆼 icon to:

- **Create** a server: choose how it runs (**native engine** or **Docker
  container**), an engine (PostgreSQL, MySQL, MariaDB, Redis, Valkey, MongoDB),
  a version, a name, a port, and the **username and password** to use. A free port is suggested
  automatically, so several versions of the same engine run side by side.
- **Start / stop** it with the switch
- **See** its username and password (󰌆), **copy** its connection URL with them (󰆏), open its **CLI client** in a terminal (),
  follow its **logs** (󰦪)
- Make it **start with the system** (󰐥)
- **Open** it in [OmaTable](https://github.com/alshareedah22/omatable) (, when OmaTable is installed)
- **Delete** it and its data (󰆴, click twice)

Each running server shows its uptime, memory and data size; a failed one shows the
last error from its log. The  button opens its tools:

- **Back up** every database to `~/Downloads/<name>-<date>.sql` (Redis/Valkey: an
  `.rdb` snapshot). MongoDB backups are made in OmaTable (*Database ▾ → Back up*).
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
regenerate the lock with `tools/update-engines-lock` and review the diff.

**Docker container** runs the official image as a container named `omadbngin-<name>`,
labelled `omadbngin.managed=1`, with its data in the volume `omadbngin-<name>`.
*Start with system* sets its restart policy to `unless-stopped`.

Either way, servers listen on `127.0.0.1` only, stop and start keep the data,
and only Delete removes it. Servers OmaDBngin did not create are never touched.

## Username and password

Leave them empty for the usual passwordless development defaults, or set your own:

| Engine          | Default user         | What a username / password does |
|-----------------|----------------------|---------------------------------|
| PostgreSQL      | `postgres`           | That user is the superuser; a password turns on `scram-sha-256` auth |
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
ordering, input validation, and that delete leaves nothing behind.

## Remove

```bash
omarchy plugin remove blackcode.omadbngin
```

Servers keep running until you delete them, so delete them in the panel first.
Leftovers: `ls ~/.local/share/omadbngin/servers` (native) and
`docker ps -a --filter label=omadbngin.managed=1` (Docker). Downloaded engines live in
`~/.local/share/omadbngin/engines`.
