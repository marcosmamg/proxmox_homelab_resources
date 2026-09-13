# Proxmox Homelab Resources

Runbooks and scripts for a self-hosted Proxmox VE homelab.

| Guide | What it covers |
|---|---|
| [proxmox-over-wifi](proxmox-over-wifi/) | Moving a node's uplink from Ethernet to Wi-Fi, with NAT so VMs and containers still reach the internet — plus the DNS, clock, and repository problems that break `apt` along the way. |

Each guide is self-contained: a README you can follow by hand, and numbered
scripts you can run instead. Edit `scripts/config.sh` first — everything else
reads its settings from there.

> Homelab use, not production. Read the warnings at the top of each guide.
