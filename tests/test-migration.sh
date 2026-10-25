#!/bin/bash
# Moving from OmaDB: the pre-rename dbctl (from git) creates a native Valkey and
# a Docker Redis server with data; the current dbctl must take both over with
# their data, ports, passwords and running state.
#
#   tests/test-migration.sh        (needs git, network or a cached Valkey 9 build, Docker for the Docker half)

set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
DBCTL="$here/dbctl"
tmp=$(mktemp -d)
pass=0 fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

old_rev=$(git -C "$here" log --format=%H -1 --grep='Color database icon')
git -C "$here" show "$old_rev:dbctl" >"$tmp/old-dbctl" && chmod +x "$tmp/old-dbctl"
git -C "$here" show "$old_rev:engines.lock" >"$tmp/engines.lock"
export OMADB_HOME="$tmp/legacy" OMADBNGIN_HOME="$tmp/new" OMADBNGIN_LEGACY_HOME="$tmp/legacy"
mkdir -p "$OMADB_HOME"
# Reuse downloaded engines instead of fetching them again.
for d in "$HOME/.local/share/omadbngin/engines" "$HOME/.local/share/omadb/engines"; do
  [[ -d $d ]] && { ln -s "$d" "$OMADB_HOME/engines"; break; }
done

cleanup() {
  OMADBNGIN_HOME="$tmp/new" "$DBCTL" remove zt-mig >/dev/null 2>&1
  OMADBNGIN_HOME="$tmp/new" "$DBCTL" remove zt-migd >/dev/null 2>&1
  OMADB_HOME="$tmp/legacy" "$tmp/old-dbctl" remove zt-mig >/dev/null 2>&1
  docker rm -f omadb-zt-migd >/dev/null 2>&1
  docker volume rm omadb-zt-migd >/dev/null 2>&1
  rm -f "$tmp/new/engines" "$tmp/legacy/engines"
  rm -rf "$tmp"
}
trap cleanup EXIT

cli() { "$(ls -d "$OMADBNGIN_HOME"/engines/valkey/9*/bin | head -1)/valkey-cli" -p 55491 --user default --pass pw --no-auth-warning "$@"; }

echo "Native"
"$tmp/old-dbctl" create valkey 9 zt-mig 55491 on native default pw || { echo "old dbctl could not create"; exit 1; }
"$(ls -d "$OMADB_HOME"/engines/valkey/9*/bin | head -1)/valkey-cli" -p 55491 --user default --pass pw --no-auth-warning set kept yes >/dev/null
check "old service runs" systemctl --user is-active omadb-zt-mig.service

docker_ok=0
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  docker_ok=1
  "$tmp/old-dbctl" create redis 8 zt-migd 55492 off docker default pw >/dev/null || { bad "old dbctl docker create"; docker_ok=0; }
  if ((docker_ok)); then
    for _ in $(seq 1 30); do docker exec omadb-zt-migd redis-cli -a pw --no-auth-warning set kept yes 2>/dev/null | grep -q OK && break; sleep 1; done
    docker exec omadb-zt-migd redis-cli -a pw --no-auth-warning save >/dev/null
    docker stop omadb-zt-migd >/dev/null   # stopped servers stay stopped
  fi
fi

state=$("$DBCTL" state)
check "legacy directory moved" test ! -e "$tmp/legacy"
check "new directory has the server" test -f "$tmp/new/servers/zt-mig/server.json"
check "old unit gone" test ! -e "$HOME/.config/systemd/user/omadb-zt-mig.service"
check "new unit runs" systemctl --user is-active omadbngin-zt-mig.service
check "autostart kept" systemctl --user is-enabled omadbngin-zt-mig.service
check "config points at the new data directory" grep -q "$tmp/new/servers/zt-mig/data" "$tmp/new/servers/zt-mig/valkey.conf"
for _ in $(seq 1 20); do cli ping 2>/dev/null | grep -q PONG && break; sleep 0.5; done
check "data and password kept" bash -c "$(declare -f cli); OMADBNGIN_HOME='$OMADBNGIN_HOME'; cli get kept | grep -qx yes"
check "state lists it as running" bash -c "jq -e '.services[] | select(.name == \"zt-mig\" and .running and .mode == \"native\")' <<<'$state'"
check "running twice changes nothing" "$DBCTL" state

if ((docker_ok)); then
  echo "Docker"
  check "old container gone" bash -c "! docker inspect --type container omadb-zt-migd"
  check "new container exists" docker inspect omadbngin-zt-migd
  check "new labels" bash -c "[[ \$(docker inspect -f '{{index .Config.Labels \"omadbngin.port\"}}' omadbngin-zt-migd) == 55492 ]]"
  check "still stopped" bash -c "[[ \$(docker inspect -f '{{.State.Running}}' omadbngin-zt-migd) == false ]]"
  check "old volume kept" docker volume inspect omadb-zt-migd
  "$DBCTL" start zt-migd
  for _ in $(seq 1 30); do docker exec omadbngin-zt-migd redis-cli -a pw --no-auth-warning ping 2>/dev/null | grep -q PONG && break; sleep 1; done
  check "data and password kept" bash -c "docker exec omadbngin-zt-migd redis-cli -a pw --no-auth-warning get kept | grep -qx yes"
fi

echo "$pass passed, $fail failed"
((fail == 0))
