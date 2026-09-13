# Proxmox Homelab Resources

Runbooks and scripts for a self-hosted Proxmox VE homelab. Each guide explains
the system as well as the steps — commands first, with collapsed sections
covering what the tools actually do and why each choice is made.

| Guide | What it covers |
|---|---|
| [proxmox-over-wifi](proxmox-over-wifi/) | Moving a node's uplink from Ethernet to Wi-Fi, with NAT so VMs and containers still reach the internet — plus the DNS, clock, and repository problems that break `apt` along the way. |
| [proxmox-storage](proxmox-storage/) | Adding disks, choosing between Directory / LVM-Thin / ZFS, understanding thin provisioning, and getting that space to your guests. |
| [proxmox-vm](proxmox-vm/) | Creating a VM: verifying an installer image, the wizard settings that aren't defaults, installing Debian, and publishing a NATed guest's services to your LAN. |

Each guide is self-contained: a README you can follow by hand, and numbered
scripts you can run instead. Read-only inspection scripts come first so you can
see what you're working with before changing anything.

> Homelab use, not production. Read the warnings at the top of each guide.
