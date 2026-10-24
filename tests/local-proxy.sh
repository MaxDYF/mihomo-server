#!/usr/bin/env bash
# Run with: env -i PATH="$PATH" bash tests/local-proxy.sh
# Optional: MIHOMO_TEST_BIN=/path/to/mihomo to validate generated configs.
set -e

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/vpn-local-proxy.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export MIHOMO_DIR="$test_dir/data"
source "$repo_dir/vpn.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
running=0
restarts=0
_vpn_mihomo_running() { [ "$running" = 1 ]; }
_vpn_sub_restart() { restarts=$((restarts + 1)); }

# Capture curl's actual arguments and supply an offline subscription fixture.
cat > "$test_dir/sub.yaml" <<'EOF'
proxies:
  - name: test-node
    type: socks5
    server: 127.0.0.1
    port: 9999
EOF
curl() {
    curl_args=("$@")
    local out
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then out="$2"; break; fi
        shift
    done
    [ -n "$out" ] || return 1
    cp "$test_dir/sub.yaml" "$out"
}
assert_proxy_args() {
    local i
    for ((i = 0; i < ${#curl_args[@]}; i++)); do
        if [ "${curl_args[i]}" = --proxy ]; then
            [ "${curl_args[i+1]}" = "$1" ] || fail "wrong download proxy"
            [ "${curl_args[i+2]}" = --noproxy ] || fail "NO_PROXY override missing"
            [ -z "${curl_args[i+3]}" ] || fail "NO_PROXY must be cleared"
            return 0
        fi
    done
    fail "download proxy missing"
}
validate_config() {
    if [ -n "${MIHOMO_TEST_BIN:-}" ]; then
        "$MIHOMO_TEST_BIN" -t -d "$MIHOMO_DIR" || fail "invalid Mihomo config"
    fi
}

# Invalid input must fail immediately, including before the first subscription.
if vpn local-proxy on invalid://localhost:9632; then fail "invalid URL accepted"; fi
[ -z "$LOCAL_PROXY" ] || fail "invalid URL changed state"

vpn local-proxy on socks5://localhost:9632 || fail "setup requires subscription"
[ ! -s "$SUBS_ACTIVE" ] || fail "setup created a subscription"
[ ! -f "$CONFIG_FILE" ] || fail "setup generated an unusable config"
vpn local-proxy status | grep -Fq socks5://localhost:9632 || fail "wrong status"
vpn local-proxy off || fail "disable requires subscription"
[ -z "$LOCAL_PROXY" ] || fail "disable did not clear state"
vpn local-proxy on http://localhost:9632 || fail "HTTP proxy setup failed"
_vpn_sub_fetch https://subscription.invalid/sub "$test_dir/http.yaml" || fail "HTTP fetch failed"
assert_proxy_args http://localhost:9632

vpn local-proxy on socks5://localhost:9632 || fail "SOCKS5 proxy setup failed"
if vpn local-proxy on socks5://localhost:70000; then fail "bad port accepted"; fi
[ "$LOCAL_PROXY" = socks5://localhost:9632 ] || fail "invalid URL lost previous setting"
vpn sub add https://subscription.invalid/sub Test || fail "first subscription failed"
assert_proxy_args socks5h://localhost:9632
grep -q 'dialer-proxy: local-proxy' "$CONFIG_FILE" || fail "node chaining missing"
validate_config
update_rc=0
_vpn_sub_update_one sub_1 || update_rc=$?
[ "$update_rc" = 2 ] || fail "unchanged subscription update failed"
assert_proxy_args socks5h://localhost:9632

# Changing an active setup must still regenerate and restart a running instance.
running=1
vpn local-proxy on http://localhost:9633 || fail "active setup failed"
[ "$restarts" = 1 ] || fail "running instance was not restarted"
grep -q 'port: 9633' "$CONFIG_FILE" || fail "config was not regenerated"
validate_config
vpn local-proxy off || fail "active disable failed"
[ "$restarts" = 2 ] || fail "disable did not restart running instance"
if grep -q 'dialer-proxy:\|name: local-proxy' "$CONFIG_FILE"; then
    fail "disabled proxy remains in config"
fi
validate_config
_vpn_sub_fetch https://subscription.invalid/sub "$test_dir/direct.yaml" || fail "direct fetch failed"
for arg in "${curl_args[@]}"; do
    [ "$arg" != --proxy ] || fail "disabled proxy still used for downloads"
done

echo "PASS: local proxy bootstrap, downloads, updates, validation, and active reconfiguration"
