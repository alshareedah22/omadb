#!/bin/bash

# Fast tests for dbctl: no Docker, no downloads, no real services. A fake native server in a
# temporary OMADBNGIN_HOME, and shims for docker, systemctl, wl-copy and hyprctl.
#
#   tests/test-fast.sh

set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
DBCTL="$here/dbctl"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export OMADBNGIN_HOME="$T/home"
export OMADBNGIN_BACKUP_DIR="$T/backups"
export OMADBNGIN_BINDINGS="$T/bindings.lua"
mkdir -p "$T/bin" "$OMADBNGIN_HOME/servers" "$OMADBNGIN_BACKUP_DIR"

cat >"$T/bin/docker" <<'EOF'
#!/bin/bash
exit 1
EOF
cat >"$T/bin/systemctl" <<EOF
#!/bin/bash
# is-active fails (no Docker); show reports every unit as active with a control group
case "\$*" in
*is-active*) exit 1 ;;
*show*)
  for u in "\${@: -\$((\$# - 3))}"; do
    printf 'Id=%s\nActiveState=active\nUnitFileState=enabled\nMemoryCurrent=1048576\nActiveEnterTimestamp=\nControlGroup=/fake/%s\n\n' "\$u" "\$u"
  done ;;
*) echo "\$*" >>"$T/systemctl.log" ;;
esac
EOF
cat >"$T/bin/wl-copy" <<EOF
#!/bin/bash
cat >"$T/clipboard"
EOF
cat >"$T/bin/hyprctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

passed=0
failed=0
ok() { passed=$((passed + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '  \e[31m✗ %s\e[0m\n' "$1"; }
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2], want [$3]"; fi; }
has() { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1: [$2] lacks [$3]"; fi; }
fails() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

server() { # name engine port user password
  mkdir -p "$OMADBNGIN_HOME/servers/$1/data"
  jq -n --arg n "$1" --arg e "$2" --argjson p "$3" --arg u "$4" --arg pw "$5" \
    '{name: $n, engine: $e, version: "x", exact: "x.1", port: $p, user: $u, password: $pw, mode: "native", created: "2026-10-29T10:00:00Z"}' \
    >"$OMADBNGIN_HOME/servers/$1/server.json"
}
server pg postgresql 5432 postgres "s3'cr et"
server my mysql 3306 root ""
server rd redis 6379 default "pw"
server mq mariadb 3307 app "it's"

echo "Connection formats"
eq "url" "$("$DBCTL" conn pg url)" "postgresql://postgres:s3%27cr%20et@127.0.0.1:5432/postgres"
eq "env" "$("$DBCTL" conn pg env)" "DATABASE_URL=postgresql://postgres:s3%27cr%20et@127.0.0.1:5432/postgres"
has "laravel pgsql" "$("$DBCTL" conn pg laravel)" "DB_CONNECTION=pgsql"
has "laravel password" "$("$DBCTL" conn pg laravel)" "DB_PASSWORD=s3'cr et"
has "laravel mysql" "$("$DBCTL" conn my laravel)" "DB_CONNECTION=mysql"
has "laravel redis" "$("$DBCTL" conn rd laravel)" "REDIS_PASSWORD=pw"
has "django" "$("$DBCTL" conn pg django)" '"ENGINE": "django.db.backends.postgresql"'
has "django redis" "$("$DBCTL" conn rd django)" "RedisCache"
eq "jdbc" "$("$DBCTL" conn my jdbc)" "jdbc:mysql://127.0.0.1:3306/?user=root"
eq "cli quotes the password" "$("$DBCTL" conn pg cli)" "psql 'postgresql://postgres:s3%27cr%20et@127.0.0.1:5432/postgres'"
eq "cli mysql without password" "$("$DBCTL" conn my cli)" "mysql -h127.0.0.1 -P3306 -u'root'"
eq "env redis" "$("$DBCTL" conn rd env)" "REDIS_URL=redis://:pw@127.0.0.1:6379"
eq "cli escapes a quote in the password" "$("$DBCTL" conn mq cli)" "mariadb -h127.0.0.1 -P3307 -u'app' -p'it'\\''s'"
out=$(bash -c "set -- $("$DBCTL" conn mq cli); printf '%s|' \"\$@\"")
eq "the cli line parses back to the password" "$out" "mariadb|-h127.0.0.1|-P3307|-uapp|-pit's|"
for f in url env laravel django cli; do
  if "$DBCTL" conn rd "$f" >/dev/null 2>&1; then ok "conn rd $f exits 0"; else bad "conn rd $f exits non-zero"; fi
done
for f in url env laravel django jdbc cli; do
  if "$DBCTL" conn pg "$f" >/dev/null 2>&1; then ok "conn pg $f exits 0"; else bad "conn pg $f exits non-zero"; fi
done
: >"$T/clipboard"; "$DBCTL" copy rd laravel
has "copy laravel for default-user redis reaches the clipboard" "$(cat "$T/clipboard")" "REDIS_HOST=127.0.0.1"
if "$DBCTL" state >/dev/null && "$DBCTL" state --full >/dev/null && "$DBCTL" sizes >/dev/null; then ok "state, state --full and sizes exit 0"; else bad "state/sizes exit non-zero"; fi
fails "unknown format" "$DBCTL" conn pg nope
fails "no jdbc for redis" "$DBCTL" conn rd jdbc
fails "unknown server" "$DBCTL" conn nope url
"$DBCTL" copy my jdbc
eq "copy puts it on the clipboard" "$(cat "$T/clipboard")" "jdbc:mysql://127.0.0.1:3306/?user=root"

echo "Stacks"
"$DBCTL" stack add shop pg && "$DBCTL" stack add shop rd
eq "add" "$("$DBCTL" stack list)" '{"shop":["pg","rd"]}'
"$DBCTL" stack add other pg
eq "a server is in one stack" "$("$DBCTL" stack list)" '{"shop":["rd"],"other":["pg"]}'
"$DBCTL" stack remove pg
eq "remove drops empty stacks" "$("$DBCTL" stack list)" '{"shop":["rd"]}'
fails "bad stack name" "$DBCTL" stack add "a b" pg
fails "stack of an unknown server" "$DBCTL" stack add shop nope
: >"$T/systemctl.log"
"$DBCTL" stack stop shop
has "stack stop stops its servers" "$(cat "$T/systemctl.log")" "stop omadbngin-rd.service"
"$DBCTL" stack delete shop
eq "delete" "$("$DBCTL" stack list)" '{}'

echo "State"
"$DBCTL" stack add web my
state=$("$DBCTL" state)
eq "stack on each server" "$(jq -r '.services[] | select(.name == "my") | .stack' <<<"$state")" "web"
eq "stacks listed" "$(jq -c '.stacks' <<<"$state")" '["web"]'
eq "no stats without --full" "$(jq -r '.services[0] | has("cpuUsec")' <<<"$state")" "false"
eq "no size in state" "$(jq -r '[.services[] | has("size")] | any' <<<"$state")" "false"
eq "no internals leak" "$(jq -r '[.services[] | has("cgroup") or has("cid")] | any' <<<"$state")" "false"
full=$("$DBCTL" state --full)
eq "--full adds cpu and readiness" "$(jq -r '.services[0] | (has("cpuUsec") and has("ready"))' <<<"$full")" "true"
sizes=$("$DBCTL" sizes)
eq "sizes per native server" "$(jq -r 'has("pg") and has("my")' <<<"$sizes")" "true"
touch -d '10 minutes ago' "$OMADBNGIN_HOME/.sizes.json"
eq "sizes cache refreshes after 5 min" "$("$DBCTL" sizes | jq -r 'has("rd")')" "true"

mkdir -p "$OMADBNGIN_HOME/engines/redis/$(jq -r '.engines.redis["7"].version' "$here/engines.lock")"
eq "state works with only some engines installed" "$("$DBCTL" state | jq -c '.installed | map(.engine)')" '["redis"]'

echo "Ports and backups"
eq "port from a chosen start" "$("$DBCTL" port redis 7400)" "7400"
fails "bad port start ignored" test "$("$DBCTL" port redis abc)" = abc
touch "$OMADBNGIN_BACKUP_DIR/pg-20261029-100000.sql"
eq "backups read the backup folder" "$("$DBCTL" backups pg | jq -r '.[0].path')" "$OMADBNGIN_BACKUP_DIR/pg-20261029-100000.sql"

echo "Shortcut"
printf -- '-- mine\n' >"$OMADBNGIN_BINDINGS"
"$DBCTL" bind >/dev/null
has "bind adds the line" "$(cat "$OMADBNGIN_BINDINGS")" 'o.bind("SUPER + ALT + D", "OmaDBngin"'
has "bind twice" "$("$DBCTL" bind)" "already bound"
"$DBCTL" unbind >/dev/null
eq "unbind restores the file" "$(cat "$OMADBNGIN_BINDINGS")" "-- mine"
printf 'o.bind("SUPER + ALT + D", "Mine", "x")\n' >>"$OMADBNGIN_BINDINGS"
fails "bind refuses a taken key" "$DBCTL" bind

echo "First-run setup"
printf -- '-- mine\n' >"$OMADBNGIN_BINDINGS"
rm -f "$OMADBNGIN_HOME/.setup-done"
has "setup binds a free key" "$("$DBCTL" setup)" "bound: SUPER+ALT+D"
"$DBCTL" unbind >/dev/null
eq "setup runs once: after an unbind it adds nothing" "$("$DBCTL" setup)" "already set up"
eq "the file stays without the shortcut" "$(cat "$OMADBNGIN_BINDINGS")" "-- mine"
rm -f "$OMADBNGIN_HOME/.setup-done"
printf 'o.bind("SUPER + ALT + D", "Mine", "x")\n' >>"$OMADBNGIN_BINDINGS"
has "setup leaves a taken key alone" "$("$DBCTL" setup)" "is taken"
eq "and does not fail" "$("$DBCTL" setup >/dev/null; echo $?)" "0"

echo "Hyprland not answering"
H="$T/h2"; mkdir -p "$H/.config/hypr"; printf -- '-- mine\n' >"$H/.config/hypr/bindings.lua"
printf '#!/bin/bash\nexit 4\n' >"$T/bin/hyprctl"
out=$(HOME="$H" OMADBNGIN_HOME="$H/omadbngin" OMADBNGIN_BINDINGS="$H/.config/hypr/bindings.lua" "$DBCTL" setup 2>&1); rc=$?
eq "setup does not fail when hyprctl reload fails" "$rc" "0"
has "still binds" "$out" "bound: SUPER+ALT+D"
if [[ -e $H/omadbngin/.setup-done ]]; then ok "and marks it done"; else bad "and marks it done"; fi
printf '#!/bin/bash\nexit 0\n' >"$T/bin/hyprctl"

echo
echo "$passed passed, $failed failed"
((failed == 0))
