#!/bin/sh
# Container integration test harness for Bifrost (PLAN section 17.2).
#
# Topology (RFC 5737 documentation prefixes only):
#   bifrost-it-wan-<id> (198.51.100.0/24): headscale (.10), router (.20), peer (.30)
#   bifrost-it-lan-<id> (192.0.2.0/24):    router (.1), lan-host (.10)
#
# Stage A (always runs): verifies container runtime (NET_ADMIN, /dev/net/tun,
#   iptables), headscale v0.29.7 pre-auth key minting, fake software center,
#   LAN echo server, and official tailscale v1.104.7 peer login.
# Stage B (runs when core/build.sh and P1-P3 libs exist, or with --full):
#   builds native test core, builds real web/dist, packages Bifrost, installs
#   via real install.sh, and runs tests/container/suite.sh (login, status,
#   3 SNAT modes, local_access, fw_clear, watchdog, core update failures &
#   rollback, logout keeping settings, uninstall).
#
# Usage:
#   tests/container/run.sh [--smoke-only | --full]
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

# Digest-pinned images (multi-arch manifests supporting linux/amd64 and linux/arm64).
HEADSCALE_IMG="ghcr.io/juanfont/headscale:v0.29.7@sha256:11f81665e842809db9fe3006a38c56a66e968baa5abd4bac498e86445572b970"
TAILSCALE_IMG="tailscale/tailscale:v1.104.7@sha256:72c1e19e0aedca96b8533bbb0b4368564410ff20b17e53b804eb6c1f04a31be4"
ALPINE_IMG="alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
ROUTER_IMG="bifrost-it-router:1"

mode="auto"
while [ $# -gt 0 ]; do
    case "$1" in
        --smoke-only) mode="smoke"; shift ;;
        --full) mode="full"; shift ;;
        -h | --help)
            echo "Usage: tests/container/run.sh [--smoke-only | --full]"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# Verify docker + NET_ADMIN + /dev/net/tun before creating any resources.
if ! type docker >/dev/null 2>&1; then
    echo "error: docker not found" >&2
    exit 1
fi
if ! docker run --rm --cap-add=NET_ADMIN --device /dev/net/tun "$ALPINE_IMG" \
    sh -c '[ -c /dev/net/tun ]' >/dev/null 2>&1; then
    echo "error: docker runtime does not support --cap-add=NET_ADMIN with /dev/net/tun" >&2
    exit 1
fi

RUN_ID="$$-$(date +%s)"
WAN_NET="bifrost-it-wan-${RUN_ID}"
LAN_NET="bifrost-it-lan-${RUN_ID}"
HS_CTR="bifrost-it-hs-${RUN_ID}"
ROUTER_CTR="bifrost-it-router-${RUN_ID}"
PEER_CTR="bifrost-it-peer-${RUN_ID}"
LAN_CTR="bifrost-it-lan-${RUN_ID}"

WORK=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() {
    docker rm -fv "$PEER_CTR" "$ROUTER_CTR" "$LAN_CTR" "$HS_CTR" >/dev/null 2>&1 || true
    docker network rm "$WAN_NET" "$LAN_NET" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# 1. Build router test image from a clean temp context (no host bind-mounts).
echo "==> Building router test image ($ROUTER_IMG)..."
ctx="$WORK/router-ctx"
mkdir -p "$ctx/mock/bin"
cp "$SCRIPT_DIR/Dockerfile.router" "$ctx/Dockerfile"
cp "$REPO_ROOT/tests/shell/mock/base.sh" "$ctx/mock/base.sh"
for f in dbus nvram cru logger service; do
    cp "$REPO_ROOT/tests/shell/mock/bin/$f" "$ctx/mock/bin/$f"
done
# Alpine's busybox lives at /bin/busybox (not /opt/bb125/busybox).
cat >"$ctx/router-uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -m ] && [ -f "${MOCK_STATE:-/var/lib/bifrost-mock}/uname_m" ]; then
    cat "${MOCK_STATE:-/var/lib/bifrost-mock}/uname_m"
    exit 0
fi
exec /bin/busybox uname "$@"
EOF
docker build -q -t "$ROUTER_IMG" "$ctx" >/dev/null

# 2. Create isolated WAN and LAN networks.
echo "==> Creating isolated Docker networks..."
docker network create --subnet=198.51.100.0/24 --gateway=198.51.100.254 "$WAN_NET" >/dev/null
docker network create --subnet=192.0.2.0/24 --gateway=192.0.2.254 "$LAN_NET" >/dev/null

# 3. Start headscale v0.29.7 (config copied via docker cp to avoid host bind-mounts).
echo "==> Starting headscale v0.29.7..."
mkdir -p "$WORK/hs-etc/headscale" "$WORK/hs-var/lib/headscale" "$WORK/hs-var/run/headscale"
cp "$SCRIPT_DIR/headscale.yaml" "$WORK/hs-etc/headscale/config.yaml"
cp "$SCRIPT_DIR/derp.yaml" "$WORK/hs-etc/headscale/derp.yaml"
docker create --name "$HS_CTR" \
    --network "$WAN_NET" --ip 198.51.100.10 \
    "$HEADSCALE_IMG" serve >/dev/null
docker cp "$WORK/hs-etc/headscale" "$HS_CTR:/etc/"
docker cp "$WORK/hs-var/lib/headscale" "$HS_CTR:/var/lib/"
docker cp "$WORK/hs-var/run/headscale" "$HS_CTR:/var/run/"
docker start "$HS_CTR" >/dev/null

HS_URL="http://198.51.100.10:8080"

# 4. Start LAN host (192.0.2.10) echoing client source IP on TCP 18080.
# Reuse $ROUTER_IMG so socat and iproute2 are already installed (zero runtime apk needed).
echo "==> Starting LAN target host (192.0.2.10)..."
docker run -d --name "$LAN_CTR" \
    --cap-add=NET_ADMIN \
    --network "$LAN_NET" --ip 192.0.2.10 \
    "$ROUTER_IMG" sh -c '
        ip route replace 100.64.0.0/10 via 192.0.2.1 &&
        exec socat TCP4-LISTEN:18080,reuseaddr,fork SYSTEM:"printenv SOCAT_PEERADDR"
    ' >/dev/null

# 5. Start router container on WAN (.20) and LAN (.1).
echo "==> Starting Bifrost router container..."
docker run -d --name "$ROUTER_CTR" \
    --cap-add=NET_ADMIN \
    --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    --network "$WAN_NET" --ip 198.51.100.20 \
    "$ROUTER_IMG" >/dev/null
docker network connect --ip 192.0.2.1 "$LAN_NET" "$ROUTER_CTR"

# 6. Wait for headscale readiness, create user and mint pre-auth key.
echo "==> Waiting for headscale readiness..."
i=0
while [ "$i" -lt 30 ]; do
    if docker exec "$ROUTER_CTR" curl -fsS --max-time 2 "${HS_URL}/health" >/dev/null 2>&1; then
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ "$i" -ge 30 ]; then
    echo "error: headscale did not become healthy" >&2
    sh "$SCRIPT_DIR/diagnostics.sh" "$HS_CTR" >&2 || true
    exit 1
fi

user_id=$(docker exec "$HS_CTR" headscale users create bifrost-test -o json | jq -r '.id')
AUTHKEY=$(docker exec "$HS_CTR" headscale preauthkeys create -u "$user_id" --reusable -e 1h -o json | jq -r '.key')
if [ -z "$AUTHKEY" ] || [ "$AUTHKEY" = null ]; then
    echo "error: failed to mint headscale pre-auth key" >&2
    exit 1
fi
echo "PASS [stage-a] headscale v0.29.7 ready & pre-auth key minted (user=$user_id)"

# 7. Verify router container environment (TUN, iptables, mock software center, LAN reachability).
docker exec "$ROUTER_CTR" sh -eu -c '
    [ -c /dev/net/tun ]
    # One command per line: sh -e ignores a failure early in an && list.
    iptables -N BIFROST_SMOKE
    iptables -A BIFROST_SMOKE -j MARK --set-xmark 0x40000/0xff0000
    iptables -F BIFROST_SMOKE
    iptables -X BIFROST_SMOKE
    iptables -t nat -S >/dev/null
    ip6tables -S >/dev/null
    dbus set bifrost_smoke=ok
    [ "$(dbus get bifrost_smoke)" = ok ]
    dbus remove bifrost_smoke
    [ "$(nvram get lan_ipaddr)" = 192.0.2.1 ]
    [ "$(uname -m)" = aarch64 ]
    . /koolshare/scripts/base.sh
    echo_date "fake-sc-ok" >/dev/null
' smoke 1
echo "PASS [stage-a] router container TUN, iptables, and fake software center verified"

# Wait for lan-host socat server to come up.
i=0
while [ "$i" -lt 30 ]; do
    lan_seen=$(docker exec "$ROUTER_CTR" sh -c 'nc -w 2 192.0.2.10 18080' 2>/dev/null | tr -d '\r\n' || true)
    [ "$lan_seen" = "192.0.2.1" ] && break
    sleep 1
    i=$((i + 1))
done
if [ "${lan_seen:-}" != "192.0.2.1" ]; then
    echo "error: router could not reach lan-host echo server (got '${lan_seen:-}')" >&2
    exit 1
fi
echo "PASS [stage-a] LAN target host echo server verified (saw $lan_seen)"

# 8. Start official tailscale v1.104.7 peer container and join headscale.
echo "==> Starting official tailscale v1.104.7 peer container..."
docker run -d --name "$PEER_CTR" \
    --cap-add=NET_ADMIN \
    --device /dev/net/tun \
    --network "$WAN_NET" --ip 198.51.100.30 \
    --entrypoint sh \
    "$TAILSCALE_IMG" -c '
        mkdir -p /var/run/tailscale /var/lib/tailscale
        exec tailscaled --statedir=/var/lib/tailscale --socket=/var/run/tailscale/tailscaled.sock --tun=tailscale0
    ' >/dev/null

i=0
while [ "$i" -lt 20 ]; do
    docker exec "$PEER_CTR" test -S /var/run/tailscale/tailscaled.sock && break
    sleep 1
    i=$((i + 1))
done
docker exec "$PEER_CTR" tailscale up \
    --login-server="$HS_URL" \
    --auth-key="$AUTHKEY" --timeout=45s \
    --hostname=test-peer \
    --accept-dns=false >/dev/null
peer_ip=$(docker exec "$PEER_CTR" tailscale ip -4 | head -n 1)
if [ -z "$peer_ip" ]; then
    echo "error: tailscale peer did not get a tailnet IP" >&2
    exit 1
fi
echo "PASS [stage-a] official tailscale v1.104.7 peer joined headscale ($peer_ip)"

# 9. Decide whether to run Stage B (full real-core + real-scripts integration suite).
has_real=1
for req in core/build.sh core/recipe.json web/package.json \
    plugin/bifrost/lib/daemon.sh \
    plugin/bifrost/lib/fw.sh \
    plugin/bifrost/lib/dns.sh \
    plugin/bifrost/lib/status.sh \
    plugin/bifrost/lib/login.sh \
    plugin/bifrost/lib/settings.sh \
    plugin/bifrost/lib/update.sh; do
    [ -f "$REPO_ROOT/$req" ] || has_real=0
done

if [ "$mode" = smoke ]; then
    echo "Container Stage A passed (--smoke-only; Stage B skipped)."
    exit 0
fi
if [ "$has_real" = 0 ]; then
    if [ "$mode" = full ]; then
        echo "error: --full requested but required core/web/plugin files are missing" >&2
        exit 1
    fi
    echo "Container Stage A passed (Stage B skipped: waiting for core/web/plugin files)."
    exit 0
fi

# Build from the current recipe, including when a previous run left an ELF in core/out/.
host_m=$(uname -m)
case "$host_m" in
    x86_64 | amd64) test_arch=amd64 ;;
    aarch64 | arm64) test_arch=arm64 ;;
    *) echo "error: unsupported host arch for test core: $host_m" >&2; exit 1 ;;
esac
test_bin="$REPO_ROOT/core/out/test/bifrostd-linux-${test_arch}"
echo "==> Building host-native test core (linux/$test_arch)..."
"$REPO_ROOT/core/build.sh" --test-arch "$test_arch"
[ -x "$test_bin" ] || { echo "error: test core missing: $test_bin" >&2; exit 1; }

# Read version and recipe metadata from core/recipe.json (never execute the
# Linux ELF test binary on a macOS host; Item 16).
ts_ver=$(jq -r '.tailscale.version' "$REPO_ROOT/core/recipe.json")
ts_commit=$(jq -r '.tailscale.commit' "$REPO_ROOT/core/recipe.json")
go_ver=$(jq -r '.go' "$REPO_ROOT/core/recipe.json")
omit_json=$(jq -c '.omit' "$REPO_ROOT/core/recipe.json")

# Wrap native Linux test core in a single-arch arm64 manifest (router container mocks uname -m = aarch64).
core_dir="$WORK/core"
mkdir -p "$core_dir"
gzip -9 -n -c "$test_bin" >"$core_dir/bifrost-core-${ts_ver}-1-linux-arm64.gz"
raw_sha=$(openssl dgst -sha256 -r "$test_bin" | cut -d ' ' -f 1)
raw_size=$(wc -c <"$test_bin" | tr -d ' ')
gz_sha=$(openssl dgst -sha256 -r "$core_dir/bifrost-core-${ts_ver}-1-linux-arm64.gz" | cut -d ' ' -f 1)
gz_size=$(wc -c <"$core_dir/bifrost-core-${ts_ver}-1-linux-arm64.gz" | tr -d ' ')
jq -n \
    --arg ver "$ts_ver" --arg go "$go_ver" --arg commit "$ts_commit" \
    --argjson omit "$omit_json" \
    --arg gz_sha "$gz_sha" --argjson gz_size "$gz_size" \
    --arg raw_sha "$raw_sha" --argjson raw_size "$raw_size" \
    '{
      schema: 1, serial: 1, tailscale: $ver, revision: 1,
      tag: ("core-" + $ver + "-1"), min_plugin: "0.1.0",
      build: { go: $go, commit: $commit, omit: $omit },
      assets: { arm64: {
        file: ("bifrost-core-" + $ver + "-1-linux-arm64.gz"),
        size: $gz_size, sha256: $gz_sha,
        raw_size: $raw_size, raw_sha256: $raw_sha
      } }
    }' >"$core_dir/core.json"

# With no --web-dist, packaging builds the current checkout's page.
ver=$(tr -d ' \t\r\n' <"$REPO_ROOT/plugin/bifrost/version")
"$REPO_ROOT/packaging/build.sh" --core-dir "$core_dir" --arch arm64 --out "$WORK/dist"
PKG_TAR="$WORK/dist/bifrost-${ver}-hnd-arm64.tar.gz"

# Exercise the release inventory check on a real packaged ELF. Drop one
# dependency row in a private copy to prove that a stale notice is rejected.
notice_check="$REPO_ROOT/packaging/gen-core-notices.py"
python3 "$notice_check" --check-package "$PKG_TAR"
notice_test="$WORK/notice-test"
mkdir "$notice_test"
tar -xzf "$PKG_TAR" -C "$notice_test" bifrost/bin/bifrostd.gz bifrost/THIRD_PARTY_NOTICES.core.md
notice="$notice_test/bifrost/THIRD_PARTY_NOTICES.core.md"
awk '/^\| `/ && !/Go standard library/ && !omitted { omitted=1; next } { print } END { exit !omitted }' \
    "$notice" >"$notice.tmp"
mv "$notice.tmp" "$notice"
tar -czf "$WORK/stale-notice.tar.gz" -C "$notice_test" bifrost
if python3 "$notice_check" --check-package "$WORK/stale-notice.tar.gz" >"$WORK/notice-error" 2>&1; then
    echo "error: stale module notice accepted" >&2
    exit 1
fi
grep -Fq "core module inventory differs" "$WORK/notice-error"
echo "PASS [packaging] real core notice verified, missing dependency rejected"

export HS_CTR ROUTER_CTR PEER_CTR LAN_CTR HS_URL AUTHKEY PKG_TAR
sh "$SCRIPT_DIR/suite.sh"
