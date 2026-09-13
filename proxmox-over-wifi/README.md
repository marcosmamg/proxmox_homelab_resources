# 📶 Proxmox over Wi-Fi — Runbook

Moving a Proxmox VE node's uplink from Ethernet to Wi-Fi, with NAT so VMs and
containers still reach the internet.

Built from an actual migration on Proxmox VE 9.2.2 (Debian 13 "trixie"), and it
covers three things that bite you *before* you ever get to the Wi-Fi part: a
router that doesn't answer DNS, a drifted clock, and subscription-only repos.

Structure and approach owe a lot to
[ThomasRives/Proxmox-over-wifi](https://github.com/ThomasRives/Proxmox-over-wifi).
Where this runbook diverges, the reasons are in
[Differences from the original guide](#differences-from-the-original-guide).

---

## ⚠️ Warnings and risks

- **Proxmox VE does not officially support Wi-Fi.** This is a homelab
  workaround. On anything you care about, run a cable.
- **Wi-Fi cannot be bridged.** 802.11 drops frames whose source MAC isn't the
  associated client's, so guests can't sit on your LAN the way they do with a
  wired bridge. They go behind NAT instead — reachable *out*, not *in*.
- **A kernel or driver update can break networking**, and after cutover Wi-Fi is
  your only way in. Keep a monitor and keyboard available.
- **Do the cutover at the physical console.** Everything up to that point is
  safe to run over SSH; step 4 is not.

## 🛠️ Prerequisites

- Proxmox VE 8 or 9 on bare metal, root shell access.
- **Temporary Ethernet.** Every package here is installed while wired. If you
  have no cable at all, see the original guide's USB `.deb` method.
- Physical console access for the cutover and first reboot.
- Wi-Fi credentials, and a free static IP outside your router's DHCP pool.

---

## Quick start

```bash
git clone https://github.com/marcosmamg/proxmox_homelab_resources.git
cd proxmox_homelab_resources/proxmox-over-wifi/scripts
nano config.sh          # set IFACE, SSID, COUNTRY, HOST_IP, GATEWAY

./00-preflight.sh       # read-only: what is broken right now?
./01-fix-dns-and-clock.sh
./02-fix-repos.sh
./03-wifi-connect.sh    # safe over SSH: associates only, no routing change
./04-cutover-nat.sh     # PHYSICAL CONSOLE: moves the uplink, enables NAT
./99-verify.sh          # read-only: did it all work?
```

Every script is idempotent, backs up what it touches, and can be re-run.

### What each script does

| Script | Safe over SSH? | Changes |
|---|---|---|
| `00-preflight.sh` | yes | nothing (read-only) |
| `01-fix-dns-and-clock.sh` | yes | `/etc/resolv.conf`, chrony, RTC |
| `02-fix-repos.sh` | yes | `/etc/apt/sources.list.d/*.sources` |
| `03-wifi-connect.sh` | yes | wpa_supplicant config + service |
| `04-cutover-nat.sh` | **no** | `/etc/network/interfaces`, sysctl, dnsmasq |
| `99-verify.sh` | yes | nothing (read-only) |
| `rollback.sh` | **no** | restores pre-cutover networking |

---

## Variables

All of these live in `scripts/config.sh`.

| Variable | Description | Example |
|---|---|---|
| `IFACE` | Wi-Fi interface name (`ip -br a`) | `wlp3s0` |
| `SSID` | Wi-Fi network name | `YourSSID` |
| `COUNTRY` | ISO 3166-1 alpha-2 regulatory domain | `NI` |
| `HOST_IP` | Host's LAN address, over Wi-Fi | `192.168.0.100` |
| `GATEWAY` | Router | `192.168.0.1` |
| `DNS1` / `DNS2` | Upstream resolvers | `1.1.1.1` / `8.8.8.8` |
| `VM_SUBNET` | Private subnet for guests — must **not** overlap the LAN | `10.10.10.0/24` |
| `VM_GW` | Host's address on the NAT bridge | `10.10.10.1` |
| `ETH_IFACE` | Wired NIC, kept configured but unused | `nic0` |

Two networks are in play throughout:

- **Home network** — where your laptop, phone, and the Proxmox UI live.
- **VM network** — the private NAT subnet where guests live, invisible to the LAN.

---

## 🔍 Phase 0: Preflight

```bash
./00-preflight.sh
```

Checks gateway, internet-by-IP, DNS, clock sync, wireless hardware, and whether
`apt update` is clean. Fix anything it flags before continuing — a broken
resolver or clock will make later steps fail in confusing ways.

## 🌐 Phase 1: DNS and clock

Skip only if preflight passed both.

**Why this matters.** These two failures cascade in a way that's genuinely hard
to read:

```
router refuses :53
    └─> chrony can't resolve its NTP pool at boot, silently keeps zero sources
            └─> clock drifts hours
                    └─> apt rejects signatures: "Not live until 2026-09-12T19:48Z"
                            └─> "The repository is not signed"
```

That last error looks like a repo or GPG problem. It isn't. It's the clock.

```bash
./01-fix-dns-and-clock.sh
```

Diagnosing by hand:

```bash
dig +short deb.debian.org @192.168.0.1    # your router
dig +short deb.debian.org @1.1.1.1        # public
```

`connection refused` from the router means nothing is listening on :53 — plenty
of ISP routers route fine but run no resolver. Point the node at a public one.

> ⚠️ Make it permanent in the UI at **System → DNS**. Editing `/etc/resolv.conf`
> alone gets overwritten on reboot.

Then confirm chrony actually has sources — an empty list means it resolved
nothing at boot and a restart is what fixes it:

```bash
chronyc sources -v      # want ^* on one server
chronyc tracking        # want "Leap status: Normal"
```

## 📦 Phase 2: Repositories

A stock install points at `enterprise.proxmox.com`, which returns **401** without
a paid subscription.

```bash
./02-fix-repos.sh
```

Or in the UI: **Updates → Repositories** → select `pve-enterprise` → **Disable**
(same for enterprise `ceph-*`) → **Add** → `No-Subscription`.

```bash
apt update && apt full-upgrade
```

> Use `full-upgrade`, not `upgrade` — Proxmox package transitions need to add and
> remove packages, which plain `upgrade` refuses to do.

## 📡 Phase 3: Connect Wi-Fi

Still wired. This only associates the radio; routing is untouched, so you cannot
lock yourself out here.

```bash
./03-wifi-connect.sh
```

It installs `wpasupplicant`, `wireless-regdb`, `iw`, and `rfkill`; clears any
rfkill block; writes a hashed-PSK config; and enables `wpa_supplicant@IFACE`.

Success looks like:

```
Connected to aa:bb:cc:dd:ee:ff (on wlp3s0)
        SSID: YourSSID
        signal: -40 dBm
        rx bitrate: 270.0 MBit/s
```

The resulting `/etc/wpa_supplicant/wpa_supplicant-wlp3s0.conf`:

```txt
ctrl_interface=/run/wpa_supplicant
update_config=1
country=US

network={
	ssid="YourSSID"
	psk=7f3c9e1a2b...64 hex chars...d8
}
```

The script deletes the `#psk="..."` comment that `wpa_passphrase` emits, so your
plaintext password never lands on disk.

> ⚠️ The bare `psk=<64 hex>` line is what authenticates you. If it's missing or
> commented out, wpa_supplicant logs `Successfully initialized` and then does
> nothing at all — no error, no association. This is the single most common
> failure here.

Prove the radio has a real path out, without disturbing the live default route:

```bash
ip route add 1.1.1.1/32 via 192.168.0.1 dev wlp3s0
ping -c3 -I wlp3s0 1.1.1.1
ip route del 1.1.1.1/32
```

> `ping -I wlp3s0 1.1.1.1` on its own will fail at this stage, and that's
> expected — Wi-Fi has no default route yet. The temporary host route is what
> makes the test meaningful.

## 🔀 Phase 4: Cutover to Wi-Fi + NAT for guests

> ⚠️ **Physical console.** This moves the default route and reconfigures vmbr0.

```bash
./04-cutover-nat.sh
```

Resulting `/etc/network/interfaces`:

```txt
auto lo
iface lo inet loopback

iface nic0 inet manual

auto wlp3s0
iface wlp3s0 inet static
        address 192.168.0.100/24
        gateway 192.168.0.1

auto vmbr0
iface vmbr0 inet static
        address 10.10.10.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o wlp3s0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o wlp3s0 -j MASQUERADE

source /etc/network/interfaces.d/*
```

The important bits:

- `bridge-ports none` — vmbr0 stops being tied to the NIC and becomes a pure
  virtual switch. Guests keep attaching to `vmbr0` exactly as before.
- **Exactly one `gateway` line** in the whole file, on the Wi-Fi interface.
- Proxmox's web UI parser is strict: **no inline comments, no stray blank lines.**

DHCP for guests, at `/etc/dnsmasq.d/vmbr0.conf`:

```txt
interface=vmbr0
bind-dynamic
listen-address=10.10.10.1
no-dhcp-interface=wlp3s0
dhcp-range=10.10.10.50,10.10.10.200,12h
dhcp-option=option:router,10.10.10.1
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
```

> ⚠️ `bind-dynamic`, not `bind-interfaces`. vmbr0 has no carrier until a guest
> attaches, and `bind-interfaces` in that state can end up bound to your
> **LAN-facing** address — an open DNS resolver on your home network. Check with
> `ss -lnup | grep :53`: you want `10.10.10.1` and loopback, never `192.168.0.100`.

Then verify and unplug:

```bash
./99-verify.sh
# 'default route on wlp3s0' -> pull the Ethernet cable
./99-verify.sh
```

### Optional: static leases for guests

`/etc/dnsmasq.d/static-ips.conf`:

```txt
dhcp-host=52:54:00:12:34:56,10.10.10.50,my-ubuntu-vm
```

### Optional: expose a guest to the LAN

Guests behind NAT aren't reachable from your home network. Forward individual
ports instead — this example maps host `:8080` to a guest's web server:

```bash
iptables -t nat -A PREROUTING -i wlp3s0 -p tcp --dport 8080 -j DNAT --to 10.10.10.50:80
```

Add it as another `post-up` line on vmbr0 to make it survive reboots. If you want
guests to hold real LAN addresses instead, the original guide's Phase 4 covers a
`NETMAP` approach — it's considerably more fragile.

## ✅ Phase 5: Verify

```bash
./99-verify.sh
```

Checks association, boot-persistence of `wpa_supplicant@`, routing, whether the
cable is actually out, connectivity, NAT, DHCP scoping, clock, repos, and the UI
listener. Clean run:

```
=== result ===
  passed: 16   failed: 0
  ALL CHECKS PASS
```

### Migrating existing guests

Guests with a **static** LAN address are stranded after cutover — that subnet
now lives on Wi-Fi, not on vmbr0. Switch them to DHCP or to `10.10.10.x` with
gateway `10.10.10.1`.

Containers, from the host:

```bash
pct set <CTID> -net0 name=eth0,bridge=vmbr0,ip=dhcp
```

VMs: change it inside the guest OS.

Watch a lease land:

```bash
journalctl -fu dnsmasq          # DHCPDISCOVER -> DHCPOFFER -> DHCPREQUEST -> DHCPACK
cat /var/lib/misc/dnsmasq.leases
```

### First reboot

Wi-Fi is now the only way in.

```bash
systemctl is-enabled wpa_supplicant@wlp3s0    # must say 'enabled' BEFORE you reboot
```

Reboot with a monitor attached, then run `./99-verify.sh` again. A kernel upgrade
carries a small risk of a wireless driver regression.

---

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Temporary failure resolving` | No working resolver | `./01-fix-dns-and-clock.sh` |
| `dig @router` → `connection refused` | Router runs no DNS | Use `1.1.1.1` (System → DNS) |
| `Not live until <future date>` | Clock behind | `chronyc makestep; hwclock --systohc` |
| `The repository is not signed` | Same clock issue | Fix the clock, not the repo |
| `401 Unauthorized` on proxmox.com | Enterprise repo, no subscription | `./02-fix-repos.sh` |
| wpa_supplicant: `Successfully initialized`, then silence | No active `psk=` line | Regenerate with `wpa_passphrase` |
| Interface stays `DOWN` | rfkill block | `rfkill list`, `rfkill unblock wifi` |
| SSID missing from scan | Missing regdb, or 5 GHz-only card limits | `apt install wireless-regdb`; check `iw dev IFACE scan` |
| `failed to load regulatory.db` | `wireless-regdb` missing | `apt install wireless-regdb` |
| `Not connected` after reboot | Unit not enabled | `systemctl enable wpa_supplicant@IFACE` |
| Guests get an IP, no internet | Forwarding or NAT rule | `sysctl net.ipv4.ip_forward`; `iptables -t nat -S POSTROUTING` |
| Guests get no IP | dnsmasq not bound to vmbr0 | `bind-dynamic`; `journalctl -u dnsmasq` |
| `:53` on your LAN address | `bind-interfaces` with no carrier | Use `bind-dynamic` + `listen-address` |
| `/var/log/syslog` missing | Debian 13 dropped rsyslog | `journalctl -fu <unit>` |
| `vmbr0 DOWN` / route `linkdown` | Bridge has no carrier | Normal with no guests running |

### Useful commands

```bash
iw dev wlp3s0 link                            # association state
iw dev wlp3s0 scan | grep -i 'SSID:' | sort -u
wpa_cli -i wlp3s0 status
journalctl -u wpa_supplicant@wlp3s0 -n 40 --no-pager
iptables -t nat -L POSTROUTING -n -v
ss -lnup | grep :53
ip route get 1.1.1.1                          # which interface really carries traffic
```

### Rollback

```bash
./rollback.sh        # restores /etc/network/interfaces.pre-cutover
```

Plug the cable back in first. Manually:

```bash
cp /etc/network/interfaces.pre-cutover /etc/network/interfaces
ifreload -a
```

---

## Differences from the original guide

| Topic | Original | Here | Why |
|---|---|---|---|
| Wi-Fi address | DHCP | Static | Management UI keeps a stable address |
| Supplicant | `wpa-conf` in `interfaces` | `wpa_supplicant@IFACE` unit | ifupdown2 handles `wpa-conf` poorly on PVE 8/9 |
| Config filename | `wpa_supplicant.conf` | `wpa_supplicant-IFACE.conf` | Required by the `@` unit; scales to multiple radios |
| dnsmasq | edits `dnsmasq.conf` | drop-in `dnsmasq.d/vmbr0.conf` | Survives package upgrades |
| dnsmasq binding | `except-interface` | `bind-dynamic` + `listen-address` | Avoids an open resolver on the LAN |
| Host IP | On the VM subnet | On the LAN via Wi-Fi | UI stays reachable from your normal network |
| IP forwarding | `post-up echo 1 > ...` | `/etc/sysctl.d/99-nat.conf` | Applies before interfaces come up |
| DNS / clock / repos | not covered | Phases 1–2 | These broke `apt` before Wi-Fi was even in play |
| Verification | manual | `00-preflight.sh`, `99-verify.sh` | Repeatable, especially after reboots |

## Final disclaimer

Homelab use. Not for production. Wi-Fi uplink means lower throughput, higher
latency, and a dependency on your AP staying up — for a hypervisor running
several guests that's a real downgrade from a cable. If Ethernet is physically
possible where the box lives, use it.
