# OmaDB: local database servers for Omarchy

![OmaDB panel open from the bar](preview.png)

A DBngin-style database manager for the Omarchy bar. Click the 󰆼 icon to:

- **Create** a server: choose how it runs (**native engine** or **Docker
  container**), an engine (PostgreSQL, MySQL, MariaDB, Redis, Valkey, MongoDB),
  a version, a name, a port, and the **username and password** to use. A free port is suggested
  automatically, so several versions of the same engine run side by side.
- **Start / stop** it with the switch
- **See** its username and password (󰌆), **copy** its connection URL with them (󰆏), open its **CLI client** in a terminal (),
  follow its **logs** (󰦪)
- Make it **start with the system** (󰐥)
- **Delete** it and its data (󰆴, click twice)

The bar shows how many servers are running; hover for the list.

## Native or Docker

**Native engine** (default) works like DBngin: no Docker, no root, no system
packages.

- The first server of a version downloads the official build once, into
  `~/.local/share/omadb/engines/<engine>/<version>/` (versions marked 󰇚 in the
  panel are not downloaded yet). Later servers of that version reuse it.
- Each server gets its own data directory in `~/.local/share/omadb/servers/<name>/`
  and runs as the systemd user service `omadb-<name>.service`.
  *Start with system* enables that service (it starts when you log in), and
  logs come from `journalctl --user -u omadb-<name>`.

| Engine     | Native build                                       |
|------------|----------------------------------------------------|
| PostgreSQL | [theseus-rs/postgresql-binaries](https://github.com/theseus-rs/postgresql-binaries) (relocatable upstream builds) |
| MySQL      | Official `linux-glibc2.28-x86_64-minimal` tarball    |
| MariaDB    | Official `linux-systemd-x86_64` tarball              |
| Redis      | Built from the official source release (about a minute) |
| Valkey     | Official prebuilt release (built from source if missing) |
| MongoDB    | Official `ubuntu2404` tarball, plus `mongosh`        |

**Docker container** runs the official image as a container named `omadb-<name>`,
labelled `omadb.managed=1`, with its data in the volume `omadb-<name>`.
*Start with system* sets its restart policy to `unless-stopped`.

Either way, servers listen on `127.0.0.1` only, stop and start keep the data,
and only Delete removes it. Servers OmaDB did not create are never touched.

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

Servers listen on `127.0.0.1` only.

## Requirements

- Omarchy 4 (the Quickshell-based `omarchy-shell` bar)
- `curl`, `jq`, `ss`, `wl-copy`, `make` and `gcc`, which ship with Omarchy
- For Docker mode only: Docker, running, with your user in the `docker` group
  (`omarchy install docker`)

## Install

From git:

```bash
omarchy plugin add https://github.com/alshareedah22/omadb.git --enable
```

Or from a local copy:

```bash
mkdir -p ~/.config/omarchy/plugins/blackcode.omadb
cp manifest.json Panel.qml dbctl LICENSE ~/.config/omarchy/plugins/blackcode.omadb/
omarchy plugin enable blackcode.omadb --section right
```

## Command line

```bash
dbctl state                                  # JSON: docker status, engines, servers
dbctl create postgresql 17 app-db 5433 on native app s3cret   # or docker; empty port = next free one
dbctl install mysql 8.4                      # download a native engine ahead of time
dbctl start|stop|restart app-db
dbctl url app-db                             # postgresql://postgres@127.0.0.1:5433/postgres
dbctl client app-db
dbctl remove app-db [--keep-data]
```

## Remove

```bash
omarchy plugin remove blackcode.omadb
```

Servers keep running until you delete them, so delete them in the panel first.
Leftovers: `ls ~/.local/share/omadb/servers` (native) and
`docker ps -a --filter label=omadb.managed=1` (Docker). Downloaded engines live in
`~/.local/share/omadb/engines`.
