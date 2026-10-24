#!/usr/bin/env bash
# Run with: env -i PATH="$PATH" bash tests/local-import.sh
# Optional: MIHOMO_TEST_BIN=/path/to/mihomo to validate generated configs.
set -e

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/vpn-local-import.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export MIHOMO_DIR="$test_dir/data"
source "$repo_dir/vpn.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
started=0
restarts=0
downloads=0
_vpn_mihomo_running() { [ "$started" = 1 ]; }
_vpn_sub_restart() { restarts=$((restarts + 1)); }
_vpn_start_mihomo() {
    if [ -n "${MIHOMO_TEST_BIN:-}" ]; then
        "$MIHOMO_TEST_BIN" -t -d "$MIHOMO_DIR" || return 1
    fi
    started=1
}
curl() { fail "offline import attempted a network request"; }

cat > "$test_dir/local config.yaml" <<'EOF'
mixed-port: 12345
proxies:
  - name: offline-node
    type: socks5
    server: 127.0.0.1
    port: 9999
proxy-groups:
  - name: Local
    type: select
    proxies:
      - offline-node
rules:
  - MATCH,Local
EOF
cp "$test_dir/local config.yaml" "$test_dir/original.yaml"
if vpn sub import; then fail "missing file argument accepted"; fi
if vpn sub import "$test_dir/missing.yaml"; then fail "missing file accepted"; fi
touch "$test_dir/empty.yaml"
if vpn sub import "$test_dir/empty.yaml"; then fail "empty file accepted"; fi

vpn sub import "$test_dir/local config.yaml" "Offline Config" || fail "offline import failed"
[ "$(cat "$SUBS_ACTIVE")" = sub_1 ] || fail "first import was not activated"
cmp -s "$test_dir/local config.yaml" "$test_dir/original.yaml" || fail "source file was modified"
grep -q 'offline-node' "$SUBS_DIR/sub_1.yaml" || fail "imported nodes missing"
grep -q 'mixed-port: 7890' "$CONFIG_FILE" || fail "existing base settings changed"
awk -F '\t' '$1 == "sub_1" && $2 == "Offline Config" && $3 == "local" {found=1} END {exit !found}' \
    "$SUBS_LIST" || fail "local subscription not registered"
vpn on || fail "imported subscription could not start"
[ "$started" = 1 ] || fail "proxy did not start"
[ "$https_proxy" = http://127.0.0.1:7890 ] || fail "terminal proxy not enabled"
update_rc=0
_vpn_sub_update_one sub_1 || update_rc=$?
[ "$update_rc" = 2 ] || fail "local import should skip remote updates"

printf 'rules:\n  - MATCH,DIRECT\n' > "$test_dir/no-nodes.yaml"
if vpn sub import "$test_dir/no-nodes.yaml"; then fail "config without nodes accepted"; fi
[ "$(wc -l < "$SUBS_LIST")" = 1 ] || fail "failed import changed registry"
[ "$(cat "$SUBS_ACTIVE")" = sub_1 ] || fail "failed import changed active subscription"

# Once connected, online subscriptions can use the enabled terminal proxy.
curl() {
    downloads=$((downloads + 1))
    [ "$https_proxy" = http://127.0.0.1:7890 ] || fail "download lost terminal proxy"
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then cp "$test_dir/original.yaml" "$2"; return; fi
        shift
    done
    return 1
}
vpn sub add https://subscription.invalid/sub Online || fail "online subscription failed"
[ "$downloads" = 1 ] || fail "online subscription was not downloaded"
[ "$(cat "$SUBS_ACTIVE")" = sub_1 ] || fail "adding a subscription changed active import"
vpn sub use Online || fail "switch to online subscription failed"
[ "$(cat "$SUBS_ACTIVE")" = sub_2 ] || fail "online subscription was not selected"
[ "$restarts" = 1 ] || fail "switch did not restart running proxy"
vpn sub import "$test_dir/original.yaml" Another || fail "second import failed"
[ "$(cat "$SUBS_ACTIVE")" = sub_2 ] || fail "second import changed active subscription"
[ "$restarts" = 1 ] || fail "inactive import restarted the proxy"

echo "PASS: offline import, startup, invalid files, local updates, and online subscription switch"
