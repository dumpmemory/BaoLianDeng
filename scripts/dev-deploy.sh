#!/bin/bash
# Build, install, and test BaoLianDeng with VPN toggle automation
set -e

VPN_NAME="BaoLianDeng"
APP_PATH="/Applications/BaoLianDeng.app"
PROJECT_DIR="/Volumes/DATA/workspace/BaoLianDeng"
LOG_DIR="$HOME/Library/Containers/io.github.baoliandeng.macos.PacketTunnel/Data/Library/Application Support/BaoLianDeng"

cd "$PROJECT_DIR"

echo "=== Step 1: Stop VPN ==="
scutil --nc stop "$VPN_NAME" 2>/dev/null || true
sleep 2

echo "=== Step 2: Quit app ==="
osascript -e 'tell application "BaoLianDeng" to quit' 2>/dev/null || true
sleep 1

echo "=== Step 3: Build framework ==="
make framework

echo "=== Step 4: Build app ==="
rm -rf ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'platform=macOS' 2>&1 | tail -3

echo "=== Step 5: Install ==="
rm -rf "$APP_PATH"
cp -R ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug/BaoLianDeng.app "$APP_PATH"

echo "=== Step 6: Launch app ==="
open "$APP_PATH"
sleep 2

echo "=== Step 7: Start VPN ==="
scutil --nc start "$VPN_NAME"
# Wait for VPN to connect (up to 15s)
for i in $(seq 1 15); do
    status=$(scutil --nc status "$VPN_NAME" 2>&1 | head -1)
    if [ "$status" = "Connected" ]; then
        echo "VPN connected after ${i}s"
        break
    fi
    sleep 1
done

echo "=== Step 8: Wait for tunnel + mihomo startup ==="
LOG_FILE="$LOG_DIR/rust_bridge.log"
for i in $(seq 1 30); do
    if grep -q "engine started successfully" "$LOG_FILE" 2>/dev/null && \
       grep -q "packet_thread: entering main loop" "$LOG_FILE" 2>/dev/null; then
        echo "Tunnel ready after ${i}s"
        # Extra wait for SOCKS5 listener to be ready
        sleep 3
        break
    fi
    sleep 1
done

# Verify mihomo SOCKS5 proxy is listening
echo "=== Step 9: Verify SOCKS5 proxy ==="
if curl -s --connect-timeout 3 --socks5 127.0.0.1:7890 http://www.baidu.com/ -o /dev/null -w "SOCKS5 proxy: HTTP %{http_code}\n"; then
    echo "SOCKS5 proxy OK"
else
    echo "SOCKS5 proxy NOT ready"
fi

echo "=== Step 10: Test curl ==="
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" --max-time 30 http://ipinfo.io/ || echo "curl failed"

echo "=== Step 11: Show logs ==="
echo "--- rust_bridge.log (STATS) ---"
grep "STATS" "$LOG_DIR/rust_bridge.log" 2>/dev/null | tail -3
echo "--- rust_bridge.log (TX DATA) ---"
grep "TX DATA" "$LOG_DIR/rust_bridge.log" 2>/dev/null | head -5
echo "--- rust_bridge.log (SOCKS5) ---"
grep "SOCKS5" "$LOG_DIR/rust_bridge.log" 2>/dev/null | tail -5
echo "--- rust_bridge.log (ERRORS) ---"
grep -i "MISS\|ORPHAN\|ERR\|FAIL\|can_send=false" "$LOG_DIR/rust_bridge.log" 2>/dev/null | head -10

echo "=== Done ==="
