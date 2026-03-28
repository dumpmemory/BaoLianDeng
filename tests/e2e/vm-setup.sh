#!/bin/bash
# One-time VM setup for BaoLianDeng E2E tests
# Creates a macOS VM and guides through manual configuration steps
set -e

VM_BASE_NAME="bld-e2e-base"
DISK_SIZE_GB=60

echo "=== BaoLianDeng E2E VM Setup ==="
echo ""

# Step 1: Check dependencies
echo "--- Step 1: Checking dependencies ---"
if ! command -v tart &>/dev/null; then
    echo "Installing tart..."
    brew install cirruslabs/cli/tart
else
    echo "tart: $(tart --version 2>&1 | head -1)"
fi

if ! command -v ssserver &>/dev/null; then
    echo "Installing shadowsocks-rust..."
    brew install shadowsocks-rust
else
    echo "ssserver: $(ssserver --version 2>&1 | head -1)"
fi

# Step 2: Check if base VM already exists
if tart list 2>/dev/null | grep -q "$VM_BASE_NAME"; then
    echo ""
    echo "VM '$VM_BASE_NAME' already exists."
    echo "To recreate, run: tart delete $VM_BASE_NAME"
    echo "Then re-run this script."
    exit 0
fi

# Step 3: Create VM from IPSW
echo ""
echo "--- Step 2: Creating VM from latest macOS IPSW ---"
echo "This downloads ~14GB and takes several minutes..."
echo "Note: host macOS version must be >= the IPSW version."
tart create "$VM_BASE_NAME" --from-ipsw latest --disk-size "$DISK_SIZE_GB"

# Step 4: First boot — Setup Assistant + SSH
echo ""
echo "--- Step 3: First boot (Setup Assistant + SSH) ---"
echo ""
echo "  The VM will open in a GUI window. Complete these steps:"
echo ""
echo "  1. Complete the macOS Setup Assistant"
echo "     - Username: admin"
echo "     - Password: admin"
echo "     - Skip Apple ID, Screen Time, Analytics, etc."
echo ""
echo "  2. Enable Remote Login (SSH)"
echo "     - System Settings > General > Sharing > Remote Login > ON"
echo "     - Allow access for: All users"
echo ""
echo "  3. Shut down the VM from the Apple menu"
echo ""
echo "Press Enter to boot the VM..."
read -r

tart run "$VM_BASE_NAME"

# Step 5: Disable SIP via recovery mode
echo ""
echo "--- Step 4: Disable SIP (recovery mode) ---"
echo ""
echo "  The VM will boot into recovery mode:"
echo ""
echo "  1. Utilities > Terminal"
echo "  2. Run: csrutil disable"
echo "  3. Confirm with 'y' if prompted"
echo "  4. Run: reboot"
echo ""
echo "Press Enter to boot into recovery mode..."
read -r

tart run "$VM_BASE_NAME" --recovery

# Step 6: Configure auto-login, sudo, and SSH key
echo ""
echo "--- Step 5: Configuring auto-login and SSH ---"
echo "Booting VM headlessly..."
tart run "$VM_BASE_NAME" --vnc-experimental --no-graphics &
SETUP_PID=$!

# Wait for VM IP
echo "Waiting for VM IP..."
VM_IP=""
for i in $(seq 1 60); do
    VM_IP=$(tart ip "$VM_BASE_NAME" 2>/dev/null || true)
    if [ -n "$VM_IP" ]; then
        echo "VM IP: $VM_IP"
        break
    fi
    sleep 2
done

if [ -z "$VM_IP" ]; then
    echo "ERROR: Could not get VM IP"
    kill $SETUP_PID 2>/dev/null || true
    exit 1
fi

# Wait for SSH
echo "Waiting for SSH..."
for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 admin@"$VM_IP" "echo ok" &>/dev/null; then
        echo "SSH ready"
        break
    fi
    sleep 2
done

# Copy SSH key
echo ""
echo "Copying SSH key... (password is 'admin')"
ssh-copy-id -o StrictHostKeyChecking=no admin@"$VM_IP"

# Enable passwordless sudo
echo "Setting up passwordless sudo..."
ssh -t -o StrictHostKeyChecking=no admin@"$VM_IP" \
    "echo 'admin' | sudo -S sh -c 'echo \"admin ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/admin && chmod 440 /etc/sudoers.d/admin' 2>/dev/null && echo 'Done'"

# Enable auto-login
echo "Enabling auto-login..."
ssh -o StrictHostKeyChecking=no admin@"$VM_IP" \
    "sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser admin"

# Create kcpassword (XOR-obfuscated "admin")
ssh -o StrictHostKeyChecking=no admin@"$VM_IP" \
    'sudo sh -c "printf \"\\x1c\\xed\\x3f\\x4a\\xbc\\xbc\\x43\\xb4\\x59\\x33\\xb1\" > /etc/kcpassword && chmod 600 /etc/kcpassword"'
echo "Auto-login configured"

# Stop VM
tart stop "$VM_BASE_NAME" 2>/dev/null || true
wait $SETUP_PID 2>/dev/null || true

# Step 7: Approve system extension
echo ""
echo "--- Step 6: Approve system extension ---"
echo ""
echo "  The VM will open with a GUI. You need to:"
echo ""
echo "  1. Open BaoLianDeng from /Applications"
echo "     (if not already installed, copy it first)"
echo "  2. When prompted, open System Settings"
echo "  3. Go to: General > Login Items & Extensions > Network Extensions"
echo "  4. Toggle ON the BaoLianDeng extension"
echo "  5. Optionally in Terminal: sudo systemextensionsctl developer on"
echo "  6. Shut down the VM"
echo ""
echo "Press Enter to boot the VM..."
read -r

tart run "$VM_BASE_NAME"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Base VM '$VM_BASE_NAME' is ready."
echo "Run the E2E tests with: make e2e-test"
