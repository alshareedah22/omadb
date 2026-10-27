#!/bin/bash

# End-to-end tests for dbctl: every engine, native and Docker.
#
#   tests/test-dbctl.sh [native|docker|all] [engine...]
#
# Creates servers named zt-*, checks them from the host over TCP with the
# native clients, and removes them again. Native engines are downloaded on
# first use (~1.8 GB for all six); Docker images are pulled as needed.

set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
DBCTL="$here/dbctl"
ENGINES_DIR="${OMADBNGIN_HOME:-$HOME/.local/share/omadbngin}/engines"
PASS='p@ss#9!'
MODES=${1:-all}
shift || true
ENGINES=("$@")
((${#ENGINES[@]})) || ENGINES=(postgresql postgis mysql mariadb redis valkey mongodb)
declare -A LINE=([postgresql]=17 [postgis]=18-3.6 [mysql]=8.4 [mariadb]=11.8 [redis]=7 [valkey]=9 [mongodb]=8)

passed=0
failed=0
failures=()

ok() { passed=$((passed + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad() { failed=$((failed + 1)); failures+=("$1"); printf '  \e[31m✗ %s\e[0m\n' "$1"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
refute() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
eventually() { local i; for i in $(seq 1 90); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

# Shim: capture what dbctl would open in a terminal instead of opening it.
SHIM=$(mktemp -d)
cat >"$SHIM/omarchy" <<EOF
#!/bin/bash
# omarchy launch tui --app-id=<id> <command...>
printf '%s\n' "\${@: -1}" >"$SHIM/launched"
printf '%q ' "\${@:4}" >"$SHIM/launched-argv"
EOF
chmod +x "$SHIM/omarchy"

cleanup() {
  local n
  for n in $("$DBCTL" state 2>/dev/null | jq -r '.services[].name | select(startswith("zt-"))'); do
    "$DBCTL" remove "$n" >/dev/null 2>&1
  done
  rm -rf "$SHIM" "${OMADBNGIN_HOME:-$HOME/.local/share/omadbngin}"/servers/zt-*.removed-*
}
trap cleanup EXIT

engine_bin() { echo "$(ls -d "$ENGINES_DIR/$1/${LINE[$1]}".* 2>/dev/null | sort -V | tail -1)/bin/$2"; }
with_compat() {
  local base
  base=$(dirname "$(dirname "$1")")
  LD_LIBRARY_PATH="$base/compat" "$@"
}

# connect <engine> <port> <user> <pass>: authenticate over TCP and run a query
connect() {
  local engine=${1/postgis/postgresql} port=$2 user=$3 pass=$4
  case $engine in
  postgresql) PGPASSWORD="$pass" "$(engine_bin postgresql psql)" -h 127.0.0.1 -p "$port" -U "$user" -d postgres -w -tAc 'select 1' | grep -qx 1 ;;
  mysql | mariadb)
    MYSQL_PWD=$pass with_compat "$(engine_bin "$engine" "$engine")" -h127.0.0.1 -P"$port" -u"$user" -NBe 'select 1' 2>/dev/null | grep -qx 1
    ;;
  redis | valkey)
    local a=()
    [[ -n $user && $user != default ]] && a+=(--user "$user")
    REDISCLI_AUTH=$pass "$(engine_bin "$engine" "$engine-cli")" -p "$port" "${a[@]}" --no-auth-warning ping 2>&1 | grep -qx PONG
    ;;
  mongodb)
    local auth=""
    [[ -n $user ]] && auth="$(jq -rn --arg s "$user" '$s|@uri'):$(jq -rn --arg s "$pass" '$s|@uri')@"
    "$(engine_bin mongodb mongosh)" --quiet "mongodb://${auth}127.0.0.1:$port/admin" \
      --eval 'db.adminCommand({listDatabases: 1}).ok' 2>/dev/null | grep -qx 1
    ;;
  esac
}

# write / read a marker value through the engine
data() {
  local op=$1 engine=${2/postgis/postgresql} port=$3 user=$4 pass=$5
  case $engine in
  postgresql)
    local sql="select x from omadb_t"
    [[ $op == write ]] && sql="create table omadb_t(x int); insert into omadb_t values (42); $sql"
    PGPASSWORD="$pass" "$(engine_bin postgresql psql)" -h 127.0.0.1 -p "$port" -U "$user" -d postgres -w -tAc "$sql" | grep -qx 42
    ;;
  mysql | mariadb)
    local sql="select x from omadb.t"
    [[ $op == write ]] && sql="create database omadb; create table omadb.t(x int); insert into omadb.t values (42); $sql"
    MYSQL_PWD=$pass with_compat "$(engine_bin "$engine" "$engine")" -h127.0.0.1 -P"$port" -u"$user" -NBe "$sql" 2>/dev/null | grep -qx 42
    ;;
  redis | valkey)
    local a=()
    [[ -n $user && $user != default ]] && a+=(--user "$user")
    export REDISCLI_AUTH=$pass
    [[ $op == write ]] && "$(engine_bin "$engine" "$engine-cli")" -p "$port" "${a[@]}" --no-auth-warning set omadb 42 >/dev/null
    "$(engine_bin "$engine" "$engine-cli")" -p "$port" "${a[@]}" --no-auth-warning get omadb | grep -qx 42
    ;;
  mongodb)
    local auth="" js='db.t.findOne().x'
    [[ -n $user ]] && auth="$(jq -rn --arg s "$user" '$s|@uri'):$(jq -rn --arg s "$pass" '$s|@uri')@"
    [[ $op == write ]] && js="db.t.insertOne({x: 42}); $js"
    "$(engine_bin mongodb mongosh)" --quiet "mongodb://${auth}127.0.0.1:$port/omadb?authSource=admin" --eval "$js" 2>/dev/null | grep -qx 42
    ;;
  esac
}

# drop the marker value written by `data write`
forget() {
  local engine=${1/postgis/postgresql} port=$2 user=$3 pass=$4
  case $engine in
  postgresql) PGPASSWORD="$pass" "$(engine_bin postgresql psql)" -h 127.0.0.1 -p "$port" -U "$user" -d postgres -w -qc 'drop table omadb_t' ;;
  mysql | mariadb) MYSQL_PWD=$pass with_compat "$(engine_bin "$engine" "$engine")" -h127.0.0.1 -P"$port" -u"$user" -e 'drop database omadb' 2>/dev/null ;;
  redis | valkey) REDISCLI_AUTH=$pass "$(engine_bin "$engine" "$engine-cli")" -p "$port" --user "$user" --no-auth-warning del omadb | grep -qx 1 ;;
  esac
}

free_port() { local p; for p in $(seq 56100 56199); do port_open "$p" || { echo "$p"; return; }; done; }

field() { "$DBCTL" state | jq -r --arg n "$1" ".services[] | select(.name == \$n) | .$2"; }
port_open() { ss -ltnH "sport = :$1" | grep -q .; }

# ---- Validation --------------------------------------------------------------

echo "Validation"
refute "rejects a name with spaces" "$DBCTL" create redis 7 "Bad Name"
refute "rejects an unknown engine" "$DBCTL" create oracle 1 zt-x
refute "rejects an unsupported version" "$DBCTL" create redis 5 zt-x
refute "rejects a port below 1024" "$DBCTL" create redis 7 zt-x 80
refute "rejects a port in use" "$DBCTL" create redis 7 zt-x "$(ss -ltnH | awk '{print $4}' | grep -oE '127\.0\.0\.1:[0-9]+$' | head -1 | cut -d: -f2)"
refute "rejects an unknown mode" "$DBCTL" create redis 7 zt-x "" off podman
refute "rejects a bad username" "$DBCTL" create redis 7 zt-x "" off native "bad user"
refute "rejects a password with \$" "$DBCTL" create redis 7 zt-x "" off native app 'a$b'
refute "rejects a password with a space" "$DBCTL" create redis 7 zt-x "" off native app 'a b'
refute "rejects a MongoDB user without password" "$DBCTL" create mongodb 8 zt-x "" off native app ""
refute "rejects actions on unknown servers" "$DBCTL" stop zt-nope
refute "PostGIS is refused natively" "$DBCTL" create postgis 18-3.6 zt-x "" off native
refute "PostGIS has no native download" "$DBCTL" install postgis 18-3.6
refute "rejects a PostGIS version it does not offer" "$DBCTL" create postgis 13-3.5 zt-x
check "state is valid JSON" bash -c "'$DBCTL' state | jq -e '.engines | length == 7'"
check "state marks PostGIS as Docker only" bash -c "'$DBCTL' state | jq -e '[.engines[] | select(.dockerOnly) | .id] == [\"postgis\"]'"
refute "nothing was created by bad input" bash -c "'$DBCTL' state | jq -e '.services[] | select(.name == \"zt-x\")'"

# ---- Pinned downloads -----------------------------------------------------------

echo
echo "Pinned downloads"
check "every engine line is pinned with a SHA-256" bash -c "
  for e in postgresql mysql mariadb redis valkey mongodb; do
    for l in \$(sed -n '/^ENGINES=(/,/^)/p' '$DBCTL' | grep \"\\\"\$e|\" | cut -d'|' -f4 | tr -d '\"'); do
      jq -e --arg e \$e --arg l \$l '.engines[\$e][\$l].sha256 | test(\"^[0-9a-f]{64}\$\")' '$here/engines.lock' >/dev/null || exit 1
    done
  done"
check "extras are pinned" jq -e '.extras.mongosh.sha256 and .extras["libxcrypt-compat"].sha256' "$here/engines.lock"
check "every pinned URL is reachable" bash -c "jq -r '.. | .urls? // empty | .[0]' '$here/engines.lock' | while read -r u; do curl -fsIL -o /dev/null --max-time 20 \"\$u\" || { echo \"\$u\"; exit 1; }; done"
# A tampered checksum must stop the install before anything is unpacked.
tamper=$(mktemp -d)
cp "$DBCTL" "$tamper/dbctl"
jq '.engines.valkey["8"].sha256 = ("0" * 64)' "$here/engines.lock" >"$tamper/engines.lock"
# An empty OMADBNGIN_HOME, so the check runs even when valkey 8 is installed for real.
export_home="$tamper/home"
refute "a checksum mismatch refuses the install" env OMADBNGIN_HOME="$export_home" "$tamper/dbctl" install valkey 8
check "and leaves nothing installed" bash -c "! ls -d '$export_home'/engines/valkey/* 2>/dev/null"
check "the error says why" bash -c "OMADBNGIN_HOME='$export_home' '$tamper/dbctl' install valkey 8 2>&1 | grep -q 'checksum mismatch'"
rm -rf "$tamper"

# ---- Pinned Docker images ---------------------------------------------------------

echo
echo "Pinned Docker images"
check "every Docker version is pinned by digest" bash -c "
  sed -n '/^ENGINES=(/,/^)/p' '$DBCTL' | grep -oE '\"[a-z]+\\|[^\"]+\"' | tr -d '\"' | while IFS='|' read -r e _t _p lines _o; do
    for l in \$lines; do
      jq -e --arg e \$e --arg l \$l '.docker[\$e][\$l] | (.tag == \$l) and (.image | length > 0) and (.digest | test(\"^sha256:[0-9a-f]{64}\$\"))' '$here/engines.lock' >/dev/null || { echo \"\$e \$l\"; exit 1; }
    done
  done"
check "and nothing else" bash -c "[[ \$(jq '[.docker[] | keys[]] | length' '$here/engines.lock') == \$(sed -n '/^ENGINES=(/,/^)/p' '$DBCTL' | grep -oE '\"[a-z]+\\|[^\"]+\"' | cut -d'|' -f4 | wc -w) ]]"
check "PostGIS is pinned to the postgis/postgis repository" jq -e '[.docker.postgis[].image] | unique == ["postgis/postgis"]' "$here/engines.lock"
# A version with no pin must be refused before anything is made.
tamper=$(mktemp -d)
cp "$DBCTL" "$tamper/dbctl"
jq 'del(.docker.postgis["18-3.6"])' "$here/engines.lock" >"$tamper/engines.lock"
refute "an unpinned Docker version is refused" env OMADBNGIN_HOME="$tamper/home" "$tamper/dbctl" create postgis 18-3.6 zt-unpinned "" off docker
check "the error says why" bash -c "OMADBNGIN_HOME='$tamper/home' '$tamper/dbctl' create postgis 18-3.6 zt-unpinned '' off docker 2>&1 | grep -q 'no pinned Docker image for postgis 18-3.6'"
refute "and nothing was created" docker inspect omadbngin-zt-unpinned
refute "not even a volume" docker volume inspect omadbngin-zt-unpinned
jq '.docker.redis["7"].digest = "latest"' "$here/engines.lock" >"$tamper/engines.lock"
refute "a malformed digest is refused" env OMADBNGIN_HOME="$tamper/home" "$tamper/dbctl" create redis 7 zt-unpinned "" off docker
refute "and nothing was created" docker volume inspect omadbngin-zt-unpinned
rm -rf "$tamper"

# pinned_ref <engine> <version>: what dbctl must run for it
pinned_ref() { jq -r --arg e "$1" --arg l "$2" '.docker[$e][$l] | "\(.image):\(.tag)@\(.digest)"' "$here/engines.lock"; }

# ---- Per engine, per mode ------------------------------------------------------

run_mode() {
  local mode=$1 engine=$2 version=${LINE[$2]} n="zt-$2-$1" user=app
  echo
  echo "$engine ($mode)"
  if ! OMADBNGIN_PASSWORD=$PASS "$DBCTL" create "$engine" "$version" "$n" "" off "$mode" "$user" 2>/tmp/omadbngin-test-err; then
    bad "$engine $mode: create ($(tail -1 /tmp/omadbngin-test-err))"
    return
  fi
  ok "create with user $user and a password"
  local port
  port=$(field "$n" port)
  check "state lists it as $mode, running" bash -c "[[ \$('$DBCTL' state | jq -r --arg n $n '.services[] | select(.name == \$n) | \"\(.mode) \(.state)\"') == '$mode running' ]]"
  export EXPECT="$user $PASS" # in the environment: a command line would show it to everyone
  check "state shows the username and password" bash -c "[[ \$('$DBCTL' state | jq -r --arg n $n '.services[] | select(.name == \$n) | \"\(.user) \(.password)\"') == \"\$EXPECT\" ]]"
  check "connects with the right password" eventually connect "$engine" "$port" "$user" "$PASS"
  refute "refuses a wrong password" connect "$engine" "$port" "$user" "wrong"
  refute "refuses no password" connect "$engine" "$port" "$user" ""
  check "listens on 127.0.0.1 only" bash -c "ss -ltnH 'sport = :$port' | grep -q '127.0.0.1:$port' && ! ss -ltnH 'sport = :$port' | grep -qE '(0\.0\.0\.0|\*|\[::\]):$port'"

  local url
  url=$("$DBCTL" url "$n")
  check "URL carries the encoded credentials" grep -q "app:p%40ss%239%21@127.0.0.1:$port" <<<"$url"
  [[ $engine == postgresql || $engine == postgis ]] && check "URL connects" "$(engine_bin postgresql psql)" "$url" -tAc 'select 1'
  if [[ $engine == postgis ]]; then
    check "state reports it as PostgreSQL, flavor postgis" bash -c "[[ \$('$DBCTL' state | jq -r --arg n $n '.services[] | select(.name == \$n) | \"\(.engine) \(.flavor)\"') == 'postgresql postgis' ]]"
    check "PostGIS is on in the postgres database" bash -c "'$(engine_bin postgresql psql)' '$url' -tAc 'select postgis_lib_version()' | grep -qx '3\.6\..*'"
    check "geometry works" bash -c "'$(engine_bin postgresql psql)' '$url' -tAc \"select ST_AsText(ST_Buffer(ST_MakePoint(0,0), 1, 1)) like 'POLYGON%'\" | grep -qx t"
    check "it runs the postgis/postgis image" bash -c "[[ \$(docker inspect -f '{{.Config.Image}}' omadbngin-$n) == postgis/postgis:${LINE[postgis]}@sha256:* ]]"
  fi
  local image=""
  if [[ $mode == docker ]]; then
    image=$(docker inspect -f '{{.Config.Image}}' "omadbngin-$n")
    check "it runs the image pinned by digest" bash -c "[[ '$image' == *@sha256:* && '$image' == '$(pinned_ref "$engine" "$version")' ]]"
  fi

  check "writes data" data write "$engine" "$port" "$user" "$PASS"
  check "stop" "$DBCTL" stop "$n"
  check "stopped: state says exited" bash -c "[[ \$('$DBCTL' state | jq -r --arg n $n '.services[] | select(.name == \$n) | .state') == exited ]]"
  check "stopped: port closed" eventually bash -c "! ss -ltnH 'sport = :$port' | grep -q ."
  check "start" "$DBCTL" start "$n"
  check "data survives stop and start" eventually data read "$engine" "$port" "$user" "$PASS"
  check "restart" "$DBCTL" restart "$n"
  check "data survives restart" eventually data read "$engine" "$port" "$user" "$PASS"

  if [[ $engine == mongodb ]]; then
    refute "backup points MongoDB to OmaTablePlus" "$DBCTL" backup "$n"
  else
    local bk
    bk=$(mktemp -d)
    check "backup to a file" "$DBCTL" backup "$n" "$bk/dump"
    check "the backup is private and not empty" bash -c "[[ -s '$bk/dump' && \$(stat -c %a '$bk/dump') == 600 ]]"
    refute "backup will not overwrite a file" "$DBCTL" backup "$n" "$bk/dump"
    check "no partial file is left" bash -c "! ls '$bk'/*.part-* 2>/dev/null"
    check "forget the data" forget "$engine" "$port" "$user" "$PASS"
    refute "the data is gone" data read "$engine" "$port" "$user" "$PASS"
    check "restore" "$DBCTL" restore "$n" "$bk/dump"
    check "the restore brings the data back" eventually data read "$engine" "$port" "$user" "$PASS"
    refute "restore refuses a missing file" "$DBCTL" restore "$n" "$bk/nope"
    local def
    def=$("$DBCTL" backup "$n")
    check "a backup without a file goes to ~/Downloads" bash -c "[[ '$def' == '$HOME/Downloads/$n-'* && -s '$def' ]]"
    check "backups lists it" bash -c "'$DBCTL' backups $n | jq -e --arg f '$def' '.[0].path == \$f and .[0].bytes > 0'"
    rm -rf "$bk" "$def"

    local np
    np=$(free_port)
    check "set-port moves it to $np" "$DBCTL" set-port "$n" "$np"
    check "state shows the new port" bash -c "[[ \$('$DBCTL' state | jq -r --arg n $n '.services[] | select(.name == \$n) | .port') == $np ]]"
    check "the data answers on the new port" eventually data read "$engine" "$np" "$user" "$PASS"
    check "the old port is closed" eventually bash -c "! ss -ltnH 'sport = :$port' | grep -q ."
    refute "set-port refuses a port below 1024" "$DBCTL" set-port "$n" 80
    [[ $mode == docker ]] && check "set-port keeps the same pinned image" bash -c "[[ \$(docker inspect -f '{{.Config.Image}}' omadbngin-$n) == '$image' ]]"
    port=$np
  fi

  check "autostart on" "$DBCTL" autostart "$n" on
  check "state says autostart" bash -c "[[ \$('$DBCTL' state | jq -r --arg n $n '.services[] | select(.name == \$n) | .autostart') == true ]]"
  check "autostart off" "$DBCTL" autostart "$n" off
  check "state says no autostart" bash -c "[[ \$('$DBCTL' state | jq -r --arg n $n '.services[] | select(.name == \$n) | .autostart') == false ]]"

  check "client command opens" env PATH="$SHIM:$PATH" "$DBCTL" client "$n"
  local cmd launcher
  launcher=$(cat "$SHIM/launched")
  cmd="bash $launcher"
  refute "the terminal's command line has no password" grep -qF -- "$PASS" "$SHIM/launched-argv"
  check "the client launcher is private" bash -c "[[ \$(stat -c %a '$launcher') == 600 && \$(stat -c %a '$(dirname "$launcher")') == 700 ]]"
  case $engine in
  postgresql | postgis) check "client logs in" bash -c "$cmd -tAc 'select current_user' | grep -qx $user" ;;
  mysql | mariadb) check "client logs in" bash -c "$cmd -NBe 'select current_user()' 2>/dev/null | grep -q '^$user@'" ;;
  redis | valkey) check "client logs in" bash -c "$cmd ping | grep -qx PONG" ;;
  mongodb) check "client logs in" bash -c "$cmd --eval 'db.runCommand({connectionStatus: 1}).authInfo.authenticatedUsers[0].user' </dev/null | grep -qx $user" ;;
  esac
  refute "the launcher deletes itself" test -e "$launcher"
  check "logs command opens" env PATH="$SHIM:$PATH" "$DBCTL" logs "$n"
  check "logs command shows output" bash -c "eval \"timeout 5 \$(sed 's/ -f / /' '$SHIM/launched-argv')\" | grep -q ."

  check "remove" "$DBCTL" remove "$n"
  refute "gone from state" bash -c "'$DBCTL' state | jq -e --arg n $n '.services[] | select(.name == \$n)'"
  if [[ $mode == native ]]; then
    refute "unit file removed" test -e "$HOME/.config/systemd/user/omadbngin-$n.service"
    refute "data removed" test -e "${OMADBNGIN_HOME:-$HOME/.local/share/omadbngin}/servers/$n"
  else
    refute "container removed" docker inspect "omadbngin-$n"
    refute "volume removed" docker volume inspect "omadbngin-$n"
  fi
}

run_defaults() {
  local mode=$1 engine=$2 n="zt-$2-$1-d"
  if ! "$DBCTL" create "$engine" "${LINE[$engine]}" "$n" "" off "$mode" 2>/tmp/omadbngin-test-err; then
    bad "$engine $mode: create with defaults ($(tail -1 /tmp/omadbngin-test-err))"
    return
  fi
  local user
  user=$(field "$n" user)
  check "default user ($user, no password) connects" eventually connect "$engine" "$(field "$n" port)" "$user" ""
  check "--keep-data keeps the data" "$DBCTL" remove "$n" --keep-data
  if [[ $mode == native ]]; then
    check "kept data directory exists" bash -c "ls -d '${OMADBNGIN_HOME:-$HOME/.local/share/omadbngin}'/servers/$n.removed-* >/dev/null"
  else
    check "kept volume exists" docker volume inspect "omadbngin-$n"
    docker volume rm "omadbngin-$n" >/dev/null 2>&1
  fi
}

echo
echo "Every native engine line installs (OMADBNGIN_TEST_ALL_LINES=1)"
# Opt-in: downloads every pinned build (several GB). OMADBNGIN_TEST_ALL_LINES=1 tests/test-dbctl.sh
if [[ $MODES != docker && ${OMADBNGIN_TEST_ALL_LINES:-0} == 1 ]]; then
  for e in postgresql mysql mariadb redis valkey mongodb; do
    for l in $(sed -n '/^ENGINES=(/,/^)/p' "$DBCTL" | grep "\"$e|" | cut -d'|' -f4 | tr -d '"'); do
      check "$e $l" "$DBCTL" install "$e" "$l"
    done
  done
fi

# Every command line on the machine, sampled all through the engine tests: the test password
# must never show up in one (other local accounts can read them with ps).
leaks=$(mktemp)
pattern=$(mktemp)
printf '%s\n' "$PASS" >"$pattern"
(while :; do ps -eo args=; sleep 0.05; done | grep --line-buffered -F -f "$pattern" >>"$leaks") &
sampler=$!

for engine in "${ENGINES[@]}"; do
  for mode in native docker; do
    [[ $MODES == all || $MODES == "$mode" ]] || continue
    [[ $mode == native && $engine == postgis ]] && continue # Docker only
    if [[ $mode == docker ]] && ! docker info >/dev/null 2>&1; then
      echo "  (skipping docker: not running)"
      continue
    fi
    run_mode "$mode" "$engine"
    run_defaults "$mode" "$engine"
  done
done

pkill -P "$sampler" 2>/dev/null
kill "$sampler" 2>/dev/null
echo
echo "Passwords"
check "no command line ever carried the password" test ! -s "$leaks"
[[ -s $leaks ]] && sort -u "$leaks" | cut -c1-200 | sed 's/^/    /'
rm -f "$leaks"

echo
echo "Upgrade from a Redis container with its password in the command line"
# 1.5.0 and older put Redis/Valkey passwords in the container's command line; the first dbctl
# run after the update makes such containers again. The old dbctl comes from git history.
if [[ $MODES != native ]] && docker info >/dev/null 2>&1 && git -C "$here" cat-file -e eab5fe8:dbctl 2>/dev/null; then
  old=$(mktemp -d)
  git -C "$here" show eab5fe8:dbctl >"$old/dbctl"
  git -C "$here" show eab5fe8:engines.lock >"$old/engines.lock"
  chmod +x "$old/dbctl"
  upgrade_home=$(mktemp -d)
  OMADBNGIN_HOME=$upgrade_home "$old/dbctl" create redis 7 zt-upgrade "" off docker app "$PASS" >/dev/null 2>&1
  export REDISCLI_AUTH=$PASS
  eventually docker exec -e REDISCLI_AUTH omadbngin-zt-upgrade redis-cli --user app --no-auth-warning set omadb 42
  check "the old container has the password in its command line" bash -c "docker inspect -f '{{json .Config.Cmd}}' omadbngin-zt-upgrade | grep -qF -f '$pattern'"
  old_image=$(docker inspect -f '{{.Config.Image}} {{.Image}}' omadbngin-zt-upgrade)
  check "the old container names its image by tag only" bash -c "[[ '${old_image%% *}' == redis:7 ]]"
  check "a dbctl run upgrades it" env OMADBNGIN_HOME="$upgrade_home" "$DBCTL" state
  check "it is made again from the very image it ran, now named by digest" bash -c "
    read -r ref id < <(docker inspect -f '{{.Config.Image}} {{.Image}}' omadbngin-zt-upgrade)
    [[ \$ref == redis:7@sha256:* && \$id == '${old_image#* }' ]]"
  refute "its command line no longer has the password" bash -c "docker inspect -f '{{json .Config.Cmd}}' omadbngin-zt-upgrade | grep -qF -f '$pattern'"
  check "the data is still there, behind the password" eventually bash -c "docker exec -e REDISCLI_AUTH omadbngin-zt-upgrade redis-cli --user app --no-auth-warning get omadb | grep -qx 42"
  check "it still refuses no password" bash -c "docker exec omadbngin-zt-upgrade redis-cli ping 2>&1 | grep -q NOAUTH"
  check "the upgrade runs once" test -e "$upgrade_home/.redis-cmdline-upgraded"
  OMADBNGIN_HOME=$upgrade_home "$DBCTL" remove zt-upgrade >/dev/null 2>&1
  rm -rf "$old" "$upgrade_home"
fi

echo
echo "Ports"
if [[ $MODES != docker ]]; then
  "$DBCTL" create redis 7 zt-port-a "" off native >/dev/null 2>&1
  "$DBCTL" create redis 7 zt-port-b "" off native >/dev/null 2>&1
  check "two servers of one engine get different ports" bash -c "[[ \$('$DBCTL' state | jq '[.services[] | select(.name | startswith(\"zt-port\")) | .port] | unique | length') == 2 ]]"
  "$DBCTL" stop zt-port-a >/dev/null
  refute "a stopped server keeps its port reserved" bash -c "[[ \$('$DBCTL' port redis) == \$('$DBCTL' state | jq '.services[] | select(.name == \"zt-port-a\") | .port') ]]"
  refute "duplicate names are refused" "$DBCTL" create redis 7 zt-port-a "" off native
fi

if [[ $MODES == all ]] && docker info >/dev/null 2>&1; then
  echo
  echo "Ordering"
  "$DBCTL" create redis 7 zt-order-native "" off native >/dev/null 2>&1
  sleep 1
  "$DBCTL" create redis 7 zt-order-docker "" off docker >/dev/null 2>&1
  check "native and Docker servers list oldest first" bash -c "[[ \$('$DBCTL' state | jq -c '[.services[].name | select(startswith(\"zt-order\"))]') == '[\"zt-order-native\",\"zt-order-docker\"]' ]]"
fi

rm -f "$pattern"
echo
printf '%d passed, %d failed\n' "$passed" "$failed"
((failed == 0)) || { printf '  - %s\n' "${failures[@]}"; exit 1; }
