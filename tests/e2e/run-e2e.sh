#!/bin/bash
# BaoLianDeng E2E Test Runner (host side)
# Builds app, boots macOS VM with SIP disabled, installs, starts VPN, verifies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VM_BASE_NAME="bld-e2e-base"
VM_NAME="bld-e2e-run-$$"
SS_PID=""
VM_PID=""

source "$SCRIPT_DIR/lib/vm-helpers.sh"

# --- Cleanup trap ---
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    [ -n "$SS_PID" ] && kill "$SS_PID" 2>/dev/null && echo "Stopped ssserver (PID $SS_PID)"
    vm_stop "$VM_NAME" 2>/dev/null
    [ -n "$VM_PID" ] && wait "$VM_PID" 2>/dev/null || true
    vm_delete "$VM_NAME" 2>/dev/null
}
trap cleanup EXIT

echo "=== BaoLianDeng E2E Test ==="
echo "Project: $PROJECT_DIR"
echo "VM: $VM_NAME (cloned from $VM_BASE_NAME)"
echo ""

# --- Phase 1: Check prerequisites ---
echo "--- Phase 1: Prerequisites ---"

if ! command -v tart &>/dev/null; then
    echo "ERROR: tart not found. Run: brew install cirruslabs/cli/tart"
    exit 1
fi

if ! command -v ssserver &>/dev/null; then
    echo "ERROR: ssserver not found. Run: brew install shadowsocks-rust"
    exit 1
fi

if ! tart list 2>/dev/null | grep -q "$VM_BASE_NAME"; then
    echo "ERROR: Base VM '$VM_BASE_NAME' not found."
    echo "Run the setup script first: ./tests/e2e/vm-setup.sh"
    exit 1
fi

echo "Prerequisites OK"

# --- Phase 2: Build on host ---
echo ""
echo "--- Phase 2: Build on host ---"
cd "$PROJECT_DIR"

SKIP_BUILD="${SKIP_BUILD:-}"
if [ -z "$SKIP_BUILD" ]; then
    echo "Building framework..."
    make framework

    echo "Building app (Debug)..."
    rm -rf ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*
    xcodebuild build \
        -project BaoLianDeng.xcodeproj \
        -scheme BaoLianDeng \
        -configuration Debug \
        -destination 'platform=macOS' 2>&1 | tail -5
else
    echo "Skipping build (SKIP_BUILD set)"
fi

# Locate built .app
APP_BUILD_PATH=$(find ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug -name "BaoLianDeng.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_BUILD_PATH" ]; then
    echo "ERROR: Could not find built BaoLianDeng.app in DerivedData"
    exit 1
fi
echo "Built app: $APP_BUILD_PATH"

# --- Phase 3: Start Shadowsocks server ---
echo ""
echo "--- Phase 3: Start Shadowsocks server ---"
ssserver -c "$SCRIPT_DIR/config/ssserver-config.json" &
SS_PID=$!
sleep 1

# Verify ssserver is listening
if lsof -i :18388 -sTCP:LISTEN &>/dev/null; then
    echo "ssserver listening on port 18388 (PID $SS_PID)"
else
    echo "ERROR: ssserver not listening on port 18388"
    exit 1
fi

# --- Phase 4: Boot VM ---
echo ""
echo "--- Phase 4: Boot VM ---"

echo "Cloning base VM..."
tart clone "$VM_BASE_NAME" "$VM_NAME"

vm_start "$VM_NAME"

echo "Getting VM IP..."
VM_IP=$(vm_ip "$VM_NAME" 60)
echo "VM IP: $VM_IP"

wait_for_ssh "$VM_IP" 120
wait_for_gui "$VM_IP" 90

# Discover host IP from VM's perspective
HOST_IP=$(host_ip_for_vm "$VM_IP")
echo "Host IP (from VM): $HOST_IP"

if [ -z "$HOST_IP" ]; then
    echo "ERROR: Could not determine host IP from VM"
    exit 1
fi

# --- Phase 5: Install app and config in VM ---
echo ""
echo "--- Phase 5: Install in VM ---"

echo "Copying app to VM..."
vm_copy_to "$VM_IP" "$APP_BUILD_PATH" "/Applications/"

echo "Copying test config to VM..."
vm_copy_to "$VM_IP" "$SCRIPT_DIR/config/test-config.yaml" "/tmp/e2e-test-config.yaml"

echo "Copying test script to VM..."
vm_copy_to "$VM_IP" "$SCRIPT_DIR/vm-test.sh" "/tmp/vm-test.sh"
vm_exec "$VM_IP" "chmod +x /tmp/vm-test.sh"

# --- Phase 6: Run tests in VM ---
echo ""
echo "--- Phase 6: Run tests ---"
echo ""

vm_exec "$VM_IP" "/tmp/vm-test.sh $HOST_IP"
TEST_EXIT=$?

# --- Done ---
echo ""
if [ "$TEST_EXIT" -eq 0 ]; then
    echo "=== E2E TEST PASSED ==="
else
    echo "=== E2E TEST FAILED ==="
fi

exit $TEST_EXIT
