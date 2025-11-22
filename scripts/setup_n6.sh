#!/bin/bash
#
# PicoUP N6 Interface Setup Script
#
# This script sets up the TUN interface and routing for N6 (data network) connectivity.
# Run this script before starting PicoUP to enable actual N6 packet forwarding.
#
# Usage: sudo ./scripts/setup_n6.sh [setup|teardown|status]
#
# Default action is 'setup'
#

set -e

# Configuration - these should match src/types.zig N6 constants
TUN_DEVICE="upf0"
UPF_IP="10.45.0.1"
UE_SUBNET="10.45.0.0/16"
EXTERNAL_IF="${EXTERNAL_IF:-eth0}"  # Can be overridden via environment variable

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

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_tun_module() {
    if ! lsmod | grep -q "^tun"; then
        log_info "Loading tun kernel module..."
        modprobe tun
    fi
}

setup_tun() {
    log_info "Setting up TUN interface: $TUN_DEVICE"

    # Check if device already exists
    if ip link show "$TUN_DEVICE" &>/dev/null; then
        log_warn "TUN device $TUN_DEVICE already exists, recreating..."
        ip link delete "$TUN_DEVICE" 2>/dev/null || true
    fi

    # Create TUN device
    # Note: We set the owner to the current SUDO_USER so the UPF can access it
    REAL_USER="${SUDO_USER:-$USER}"
    ip tuntap add dev "$TUN_DEVICE" mode tun user "$REAL_USER"

    # Configure IP address
    ip addr add "$UPF_IP/16" dev "$TUN_DEVICE"

    # Bring up the interface
    ip link set "$TUN_DEVICE" up

    log_info "TUN interface $TUN_DEVICE created with IP $UPF_IP"
}

setup_routing() {
    log_info "Setting up routing and NAT..."

    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    log_info "IP forwarding enabled"

    # Add route for UE subnet (if not already present)
    if ! ip route show | grep -q "$UE_SUBNET.*$TUN_DEVICE"; then
        ip route add "$UE_SUBNET" dev "$TUN_DEVICE" 2>/dev/null || true
    fi

    # Setup MASQUERADE for outgoing traffic from UE subnet
    # This allows UEs to access the internet through the UPF
    if ! iptables -t nat -C POSTROUTING -s "$UE_SUBNET" -o "$EXTERNAL_IF" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$UE_SUBNET" -o "$EXTERNAL_IF" -j MASQUERADE
        log_info "NAT MASQUERADE rule added for $UE_SUBNET -> $EXTERNAL_IF"
    else
        log_warn "NAT MASQUERADE rule already exists"
    fi

    # Allow forwarding for the TUN interface
    if ! iptables -C FORWARD -i "$TUN_DEVICE" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "$TUN_DEVICE" -j ACCEPT
    fi
    if ! iptables -C FORWARD -o "$TUN_DEVICE" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -o "$TUN_DEVICE" -j ACCEPT
    fi

    log_info "Routing and firewall rules configured"
}

teardown() {
    log_info "Tearing down N6 interface..."

    # Remove iptables rules
    iptables -t nat -D POSTROUTING -s "$UE_SUBNET" -o "$EXTERNAL_IF" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$TUN_DEVICE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$TUN_DEVICE" -j ACCEPT 2>/dev/null || true

    # Remove TUN device
    if ip link show "$TUN_DEVICE" &>/dev/null; then
        ip link delete "$TUN_DEVICE"
        log_info "TUN device $TUN_DEVICE removed"
    fi

    log_info "N6 interface teardown complete"
}

status() {
    echo "=== PicoUP N6 Interface Status ==="
    echo ""

    # Check TUN device
    if ip link show "$TUN_DEVICE" &>/dev/null; then
        echo -e "TUN Device: ${GREEN}$TUN_DEVICE (UP)${NC}"
        ip addr show "$TUN_DEVICE" | grep -E "inet |link/"
    else
        echo -e "TUN Device: ${RED}$TUN_DEVICE (NOT FOUND)${NC}"
    fi
    echo ""

    # Check IP forwarding
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        echo -e "IP Forwarding: ${GREEN}Enabled${NC}"
    else
        echo -e "IP Forwarding: ${RED}Disabled${NC}"
    fi
    echo ""

    # Check NAT rules
    echo "NAT Rules:"
    iptables -t nat -L POSTROUTING -n -v | grep -E "$UE_SUBNET|Chain" || echo "  No rules found"
    echo ""

    # Check routes
    echo "Routes for $UE_SUBNET:"
    ip route show | grep "$TUN_DEVICE" || echo "  No routes found"
    echo ""

    echo "==================================="
}

usage() {
    echo "PicoUP N6 Interface Setup Script"
    echo ""
    echo "Usage: sudo $0 [setup|teardown|status]"
    echo ""
    echo "Commands:"
    echo "  setup     - Create TUN interface and configure routing (default)"
    echo "  teardown  - Remove TUN interface and routing rules"
    echo "  status    - Show current N6 interface status"
    echo ""
    echo "Environment Variables:"
    echo "  EXTERNAL_IF  - External interface for NAT (default: eth0)"
    echo ""
    echo "Example:"
    echo "  sudo EXTERNAL_IF=enp0s3 $0 setup"
}

# Main
case "${1:-setup}" in
    setup)
        check_root
        check_tun_module
        setup_tun
        setup_routing
        echo ""
        log_info "N6 interface setup complete!"
        log_info "You can now start PicoUP: ./zig-out/bin/picoupf"
        echo ""
        status
        ;;
    teardown)
        check_root
        teardown
        ;;
    status)
        status
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
