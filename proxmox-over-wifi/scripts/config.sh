#!/bin/bash
# Shared settings. Edit these, then run the scripts in order.

# Wireless interface as named by the kernel (check: ip -br a)
IFACE="wlp3s0"

# Your Wi-Fi network. 5 GHz gives far better throughput if the card supports it.
SSID="YourSSID"

# ISO 3166-1 alpha-2 regulatory domain. Wrong value = missing channels.
COUNTRY="US"

# Address the host takes on the LAN, over Wi-Fi. Reserve it in your router's DHCP.
HOST_IP="192.168.0.100"
HOST_CIDR="24"
GATEWAY="192.168.0.1"

# Upstream resolvers. Do not point at the router unless it actually answers on :53.
DNS1="1.1.1.1"
DNS2="8.8.8.8"

# Private subnet for guests behind NAT. Must NOT overlap your LAN.
VM_SUBNET="10.10.10.0/24"
VM_GW="10.10.10.1"
VM_DHCP_START="10.10.10.50"
VM_DHCP_END="10.10.10.200"

# Wired interface, kept configured but unused after cutover.
ETH_IFACE="nic0"

WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"
