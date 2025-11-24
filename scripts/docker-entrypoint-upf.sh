#!/bin/bash
#
# Docker Entrypoint for PicoUP UPF
#
# This script sets up the TUN interface and starts the UPF.
# It's designed to run inside a Docker container with NET_ADMIN capability.
#

set -e

# Configuration - these should match src/types.zig N6 constants
TUN_DEVICE="upf0"
UPF_IP="10.45.0.1"
UE_SUBNET="10.45.0.0/16"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup function for graceful shutdown
cleanup() {
    log_info "Shutting down PicoUP..."
    if [ -n "$UPF_PID" ]; then
        kill $UPF_PID 2>/dev/null || true
        wait $UPF_PID 2>/dev/null || true
    fi

    log_info "Cleaning up TUN interface..."
    ip link delete "$TUN_DEVICE" 2>/dev/null || true

    log_info "Cleanup complete"
    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

log_info "Starting PicoUP Docker Container"
log_info "=================================="

# Check if we have NET_ADMIN capability
if ! ip link add dummy0 type dummy 2>/dev/null; then
    log_error "Missing NET_ADMIN capability. Add '--cap-add=NET_ADMIN' to docker run"
    exit 1
fi
ip link delete dummy0 2>/dev/null || true

# Load TUN module if not already loaded
if ! lsmod | grep -q "^tun"; then
    log_info "Loading tun kernel module..."
    modprobe tun || log_warn "Could not load tun module (might already be loaded)"
fi

# Check if device already exists and remove it
if ip link show "$TUN_DEVICE" &>/dev/null; then
    log_warn "TUN device $TUN_DEVICE already exists, removing..."
    ip link delete "$TUN_DEVICE" 2>/dev/null || true
fi

# Create TUN device (in Docker, we run as root so no need for user parameter)
log_info "Creating TUN device: $TUN_DEVICE"
ip tuntap add dev "$TUN_DEVICE" mode tun

# Configure IP address
log_info "Configuring IP address: $UPF_IP/16"
ip addr add "$UPF_IP/16" dev "$TUN_DEVICE"

# Bring up the interface
log_info "Bringing up TUN interface"
ip link set "$TUN_DEVICE" up

# Enable IP forwarding
log_info "Enabling IP forwarding"
echo 1 > /proc/sys/net/ipv4/ip_forward

# Add route for UE subnet
log_info "Adding route for UE subnet: $UE_SUBNET"
ip route add "$UE_SUBNET" dev "$TUN_DEVICE" 2>/dev/null || log_warn "Route already exists"

# Note: In Docker with host network mode, we typically don't need iptables rules
# as the host handles NAT. If you need NAT inside the container, uncomment below:
#
# EXTERNAL_IF=$(ip route | grep default | awk '{print $5}')
# if [ -n "$EXTERNAL_IF" ]; then
#     log_info "Setting up NAT masquerade via $EXTERNAL_IF"
#     iptables -t nat -A POSTROUTING -s "$UE_SUBNET" -o "$EXTERNAL_IF" -j MASQUERADE
#     iptables -A FORWARD -i "$TUN_DEVICE" -j ACCEPT
#     iptables -A FORWARD -o "$TUN_DEVICE" -j ACCEPT
# fi

log_info "TUN interface setup complete"
log_info ""
log_info "Network Configuration:"
ip addr show "$TUN_DEVICE"
log_info ""
log_info "Starting PicoUP..."
log_info "=================================="
log_info ""

# Start PicoUP in background so we can handle signals
/app/zig-out/bin/picoupf &
UPF_PID=$!

# Wait for UPF to exit or receive signal
wait $UPF_PID
EXIT_CODE=$?

log_info "PicoUP exited with code $EXIT_CODE"
cleanup
