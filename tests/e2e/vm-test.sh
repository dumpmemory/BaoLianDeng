#!/bin/bash
# In-VM test script for BaoLianDeng E2E tests
# This script runs inside the macOS VM via SSH
# Usage: vm-test.sh <host_ip>
set -e

HOST_IP="${1:?Usage: vm-test.sh <host_ip>}"

VPN_NAME="BaoLianDeng"
APP_PATH="/Applications/BaoLianDeng.app"
CONFIG_DIR="$HOME/Library/Application Support/BaoLianDeng/mihomo"
LOG_DIR="$HOME/Library/Containers/io.github.baoliandeng.macos.PacketTunnel/Data/Library/Application Support/BaoLianDeng"
BUNDLE_ID="io.github.baoliandeng.macos"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

pass() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $1"
}

fail() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
}

echo "=== BaoLianDeng E2E Test (in-VM) ==="
echo "Host IP: $HOST_IP"
echo ""

# --- Step 1: Configure ---
echo "--- Step 1: Write config ---"
mkdir -p "$CONFIG_DIR"
sed "s/__HOST_IP__/$HOST_IP/g" /tmp/e2e-test-config.yaml > "$CONFIG_DIR/config.yaml"
echo "Config written to $CONFIG_DIR/config.yaml"

# --- Step 2: Set UserDefaults ---
echo "--- Step 2: Set UserDefaults ---"
defaults write "$BUNDLE_ID" proxyMode -string "global"
defaults write "$BUNDLE_ID" selectedNode -string "e2e-ss"
echo "Proxy mode: global, node: e2e-ss"

# --- Step 3: Launch app ---
echo "--- Step 3: Launch app ---"
# Requires a GUI session (auto-login must be configured in the VM)
open "$APP_PATH" 2>&1 || true
sleep 5
if pgrep -x BaoLianDeng >/dev/null; then
    echo "App is running"
else
    echo "ERROR: App failed to launch. Is auto-login configured?"
    exit 1
fi

# --- Step 4: Wait for VPN configuration to register ---
echo "--- Step 5: Wait for VPN config ---"
# The app activates the system extension, then saves NETunnelProviderManager.
# With SIP disabled, extension activation should be automatic.
# This can take 15-30s on first launch.
VPN_REGISTERED=false
for i in $(seq 1 90); do
    NC_OUTPUT=$(scutil --nc list 2>/dev/null || true)
    if echo "$NC_OUTPUT" | grep -q "$VPN_NAME"; then
        echo "VPN config registered after ${i}s"
        VPN_REGISTERED=true
        break
    fi
    if [ $((i % 15)) -eq 0 ]; then
        echo "Still waiting for VPN config... ${i}s"
        echo "scutil output: $(echo "$NC_OUTPUT" | grep -c VPN) VPN entries"
        systemextensionsctl list 2>/dev/null | grep -i bao || true
    fi
    sleep 1
done
if [ "$VPN_REGISTERED" = false ]; then
    echo "ERROR: VPN configuration not found after 90s"
    echo "scutil --nc list:"
    scutil --nc list 2>/dev/null || true
    echo "System extensions:"
    systemextensionsctl list 2>/dev/null || true
    echo "App logs:"
    log show --last 1m --predicate 'subsystem == "io.github.baoliandeng.macos"' 2>/dev/null | tail -20 || true
    exit 1
fi

# --- Step 5: Start VPN ---
echo "--- Step 6: Start VPN ---"
scutil --nc start "$VPN_NAME" || true

VPN_CONNECTED=false
for i in $(seq 1 30); do
    status=$(scutil --nc status "$VPN_NAME" 2>&1 || true)
    status=$(echo "$status" | head -1)
    if [ "$status" = "Connected" ]; then
        echo "VPN connected after ${i}s"
        VPN_CONNECTED=true
        break
    fi
    sleep 1
done
if [ "$VPN_CONNECTED" = false ]; then
    echo "ERROR: VPN did not connect after 30s"
    echo "Status: $status"
    exit 1
fi

# --- Step 6: Wait for engine ---
echo "--- Step 7: Wait for engine ---"
LOG_FILE="$LOG_DIR/rust_bridge.log"
ENGINE_READY=false
for i in $(seq 1 30); do
    if [ -f "$LOG_FILE" ] && \
       grep -q "engine started successfully" "$LOG_FILE" 2>/dev/null && \
       grep -q "packet_thread: entering main loop" "$LOG_FILE" 2>/dev/null; then
        echo "Engine ready after ${i}s"
        ENGINE_READY=true
        sleep 3  # Extra wait for SOCKS5 listener
        break
    fi
    sleep 1
done
if [ "$ENGINE_READY" = false ]; then
    echo "WARNING: Engine readiness signals not found after 30s"
    echo "Log file exists: $([ -f "$LOG_FILE" ] && echo yes || echo no)"
    if [ -f "$LOG_FILE" ]; then
        echo "Last 10 log lines:"
        tail -10 "$LOG_FILE"
    fi
fi

# --- Step 7: Run verifications ---
echo ""
echo "=== Verification ==="

# Test 1: SOCKS5 proxy
echo "--- Test: SOCKS5 proxy ---"
SOCKS_STATUS=$(curl -s --connect-timeout 10 --max-time 15 --socks5 127.0.0.1:7890 -o /dev/null -w "%{http_code}" http://httpbin.org/ip 2>/dev/null || echo "000")
if [ "$SOCKS_STATUS" = "200" ]; then
    pass "SOCKS5 proxy (HTTP $SOCKS_STATUS)"
else
    fail "SOCKS5 proxy (HTTP $SOCKS_STATUS)"
fi

# Test 2: TUN tunnel (curl without explicit proxy — traffic goes through TUN)
echo "--- Test: TUN tunnel ---"
TUN_STATUS=$(curl -s --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" http://httpbin.org/ip 2>/dev/null || echo "000")
if [ "$TUN_STATUS" = "200" ]; then
    pass "TUN tunnel routing (HTTP $TUN_STATUS)"
else
    fail "TUN tunnel routing (HTTP $TUN_STATUS)"
fi

# Test 3: Traffic stats via external controller
echo "--- Test: Traffic stats ---"
TRAFFIC=$(curl -s --connect-timeout 5 http://127.0.0.1:9090/traffic 2>/dev/null | head -1)
if [ -n "$TRAFFIC" ]; then
    pass "Traffic stats endpoint responding ($TRAFFIC)"
else
    fail "Traffic stats endpoint not responding"
fi

# Test 4: TUN interface exists
echo "--- Test: TUN interface ---"
UTUN=$(ifconfig 2>/dev/null | grep -c "utun" || echo "0")
if [ "$UTUN" -gt 0 ]; then
    pass "TUN interface exists (utun count: $UTUN)"
else
    fail "No TUN interface found"
fi

# Test 5: DNS resolution via tunnel
echo "--- Test: DNS resolution ---"
DNS_RESULT=$(nslookup example.com 2>/dev/null || true)
if echo "$DNS_RESULT" | grep -q "Address"; then
    pass "DNS resolution works through tunnel"
else
    fail "DNS resolution failed"
fi

# --- Step 8: Stop VPN ---
echo ""
echo "--- Cleanup: Stop VPN ---"
scutil --nc stop "$VPN_NAME" 2>/dev/null || true
sleep 1

# --- Results ---
echo ""
echo "================================"
echo "  Results: $TESTS_PASSED/$TESTS_TOTAL passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "  $TESTS_FAILED FAILED"
    echo "================================"
    exit 1
else
    echo "  All tests passed!"
    echo "================================"
    exit 0
fi
