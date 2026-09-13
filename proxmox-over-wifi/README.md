# 📶 Proxmox over Wi-Fi

Moving a Proxmox VE node's uplink from Ethernet to Wi-Fi, with NAT so VMs and
containers still reach the internet.

This is written to be **learned from, not just executed**. Every phase has the
commands you need up front, followed by a collapsed section explaining what the
tools actually do and why the step is shaped the way it is. Expand them if you
want to understand the system; skip them if you just want it working.

Tested on Proxmox VE 9.2.2 (Debian 13 "trixie"), kernel 6.14, on a Realtek
8822CE PCIe card.

---

## ⚠️ Warnings and risks

- **Proxmox VE does not officially support Wi-Fi.** This is a homelab
  workaround. On anything you care about, run a cable.
- **Wi-Fi cannot be bridged.** Guests go behind NAT — reachable *out*, not *in*.
  ([Why](#why-cant-wi-fi-be-bridged))
- **A kernel or driver update can break networking**, and after cutover Wi-Fi is
  your only way in. Keep a monitor and keyboard available.
- **Do the cutover at the physical console.** Everything before it is safe over
  SSH; step 4 is not.

## 🛠️ Prerequisites

- Proxmox VE 8 or 9 on bare metal, root shell access.
- **Temporary Ethernet.** Every package here gets installed while wired.
- Physical console access for the cutover and the first reboot after it.
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

## The shape of the problem

Before any commands, it's worth seeing why this is four jobs rather than one.

A Proxmox host on Ethernet has a **bridge** (`vmbr0`) that holds the host's IP
and has the physical NIC as a member port. Guests attach to that bridge and land
directly on your LAN — they get addresses from your router, and other machines
on the network can reach them. The bridge behaves like an unmanaged switch.

Wi-Fi breaks that model completely, so you end up with:

1. **Get the host online reliably** — which in practice means fixing DNS and the
   clock first, because a broken resolver takes `apt` down with it.
2. **Associate the Wi-Fi card** — a userspace daemon, not just an interface.
3. **Move the default route** to Wi-Fi without locking yourself out.
4. **Rebuild guest networking** around NAT, since bridging is off the table.

<details>
<summary><b>📚 Why can't Wi-Fi be bridged?</b></summary>

A normal Ethernet frame has two MAC addresses: source and destination. A switch
(or a Linux bridge) forwards frames based on them, and a single port happily
carries traffic for many different source MACs — that's exactly what lets ten VMs
share one NIC.

802.11 frames have **three** address fields, because a frame traveling between
two wireless clients passes through the access point: it needs the transmitter,
the receiver, *and* the eventual destination. When your host associates to an AP,
the AP learns exactly one MAC for that association and expects every frame from
that client to carry it.

So when a bridged VM sends a frame with **its own** MAC as the source, the AP
sees a source address it has no association for and drops it. Even if it went
out, return traffic has nowhere to come back to — the AP has no entry mapping
that MAC to your radio.

There is a fourth address field (WDS / "4-address mode") designed for exactly
this, but both ends must support and enable it. Consumer APs essentially never
do, and `rtw88` and most client drivers don't expose it either.

The workaround is to stop trying to put guests on the LAN. Give them a private
subnet on a bridge with no physical port, and have the host **translate** their
traffic so everything leaving the radio carries the host's own MAC and IP. That's
NAT, and it's what Phase 4 builds.

</details>

<details>
<summary><b>📚 Two networks, and why they must not overlap</b></summary>

Throughout this guide:

- **Home network** — where your laptop, phone, router, and the Proxmox UI live.
  In the examples, `192.168.0.0/24`.
- **VM network** — a private subnet where guests live, invisible to the LAN.
  In the examples, `10.10.10.0/24`.

They have to be different subnets. Routing decisions are made by matching a
destination address against the routing table, longest prefix first. If both
networks were `192.168.0.0/24`, the host couldn't tell "send this to the router"
from "send this to a guest" — the same prefix would match two different
interfaces, and traffic would go wherever the tie-break landed.

Pick your VM subnet from a different RFC 1918 block than your LAN uses:

| Block | Range | Commonly used by |
|---|---|---|
| `10.0.0.0/8` | 10.0.0.0 – 10.255.255.255 | Corporate, VPNs |
| `172.16.0.0/12` | 172.16.0.0 – 172.31.255.255 | Docker defaults |
| `192.168.0.0/16` | 192.168.0.0 – 192.168.255.255 | Home routers |

Home LANs are nearly always in `192.168.x.x`, so `10.10.10.0/24` is a safe pick
for guests — and memorable.

</details>

---

## Variables

All of these live in `scripts/config.sh`.

| Variable | Description | Example |
|---|---|---|
| `IFACE` | Wi-Fi interface name (`ip -br a`) | `wlp3s0` |
| `SSID` | Wi-Fi network name | `YourSSID` |
| `COUNTRY` | ISO 3166-1 alpha-2 regulatory domain | `US` |
| `HOST_IP` | Host's LAN address, over Wi-Fi | `192.168.0.100` |
| `GATEWAY` | Router | `192.168.0.1` |
| `DNS1` / `DNS2` | Upstream resolvers | `1.1.1.1` / `8.8.8.8` |
| `VM_SUBNET` | Private subnet for guests — must **not** overlap the LAN | `10.10.10.0/24` |
| `VM_GW` | Host's address on the NAT bridge | `10.10.10.1` |
| `ETH_IFACE` | Wired NIC, kept configured but unused | `nic0` |

<details>
<summary><b>📚 Why is the interface called <code>wlp3s0</code> and not <code>wlan0</code>?</b></summary>

`wlan0` was assigned in probe order, which changes between boots depending on
which driver loads first. A machine with two NICs could swap them after a kernel
update and come up with its firewall rules on the wrong interface.

systemd/udev now uses **Predictable Network Interface Names**, derived from where
the hardware physically sits:

```
wlp3s0
│││ │
││└─┴── PCI bus 3, slot 0
│└───── p = PCI path
└────── wl = wireless LAN  (en = ethernet, ww = WWAN/cellular)
```

A USB adapter instead gets `wlxAABBCCDDEEFF` — `wlx` plus its MAC, since USB
ports don't give a stable path. Proxmox 9 may additionally show friendly
`altnames` like `nic0`, which is why `ip -br a` can show both.

The dmesg line `rtw88_8822ce 0000:03:00.0 wlp3s0: renamed from wlan0` is udev
performing exactly this rename at boot.

</details>

---

## 🔍 Phase 0: Preflight

```bash
./00-preflight.sh
```

Read-only. Checks gateway reachability, internet-by-IP, DNS, clock sync, wireless
hardware, and whether `apt update` is clean. Fix anything it flags before
continuing.

<details>
<summary><b>📚 Why check by IP and by name separately?</b></summary>

`ping 1.1.1.1` and `ping deb.debian.org` test two entirely different things, and
separating them is the fastest way to split a network problem in half:

| Test | What it proves |
|---|---|
| `ping <gateway>` | Layer 2/3 works — you have a link, an address, and a reachable router |
| `ping 1.1.1.1` | Routing and NAT out to the internet work |
| `getent hosts <name>` | Name resolution works |

If IP succeeds and names fail, everything below DNS is fine and you have a
resolver problem — no point checking cables. That's exactly the split that
started this whole guide: `ping 1.1.1.1` at 61 ms, and every `apt` line saying
`Temporary failure resolving`.

`getent hosts` is used rather than `nslookup` deliberately: it goes through
**NSS** (`/etc/nsswitch.conf`), the same path a real application takes —
`/etc/hosts` first, then DNS. `dig` and `nslookup` bypass NSS and talk straight to
a server, so they can succeed while applications still fail.

</details>

## 🌐 Phase 1: DNS and the clock

Skip only if preflight passed both.

```bash
./01-fix-dns-and-clock.sh
```

**Why these two are one phase.** They look unrelated but form a chain, and the
error at the end names neither of them:

```
router refuses :53
    └─> chrony can't resolve its NTP pool at boot, keeps zero sources
            └─> clock drifts hours
                    └─> apt rejects signatures: "Not live until 2026-09-12T19:48Z"
                            └─> "The repository is not signed"
```

That last message reads like a GPG or repository problem. It's a clock problem.

Diagnosing DNS by hand:

```bash
dig +short deb.debian.org @192.168.0.1    # your router
dig +short deb.debian.org @1.1.1.1        # public resolver
```

> ⚠️ Make the fix permanent in the UI at **System → DNS**. Editing
> `/etc/resolv.conf` directly gets overwritten.

<details>
<summary><b>📚 How name resolution actually works here</b></summary>

Debian has no local caching resolver by default. `getent`, `curl`, and `apt` all
call glibc's resolver, which reads `/etc/resolv.conf` on every lookup:

```
search server
nameserver 192.168.0.1
```

That's a **stub resolver** — it doesn't walk the DNS hierarchy itself. It fires a
UDP query at port 53 on the listed server and waits. Whatever you put there does
all the real work: querying root servers, then TLDs, then authoritative servers,
and caching the result.

`search server` appends that domain to single-label names — `ping nas` tries
`nas.server` first. Harmless, occasionally confusing.

Failure modes are distinguishable by how they fail:

| Response | Meaning |
|---|---|
| `connection refused` | Something answered "nothing is listening here" — no resolver running |
| timeout | Packets vanished — firewall dropping, or host down |
| `SERVFAIL` | Resolver exists but couldn't answer |
| `NXDOMAIN` | Resolver answered: that name doesn't exist |

The router in this case returned **connection refused** on port 53 while routing
traffic perfectly. Plenty of ISP-supplied routers do this — they forward packets
but run no DNS forwarder, expecting clients to take resolvers from DHCP. A host
with a static IP never gets that DHCP option, so it's left pointing at a resolver
that was never there.

**Why the UI and not just the file:** Proxmox owns `/etc/resolv.conf` and
rewrites it from `/etc/pve/` cluster config on boot and on network reload. Hand
edits survive until the next reboot, then silently vanish — a great way to have
this break again in a month.

</details>

<details>
<summary><b>📚 chrony, NTP, and why a restart fixed the clock</b></summary>

`chrony` is the NTP client Proxmox 9 ships. It keeps time by measuring round-trip
delay to several servers, estimating your crystal's drift rate, and then
*steering* the clock — speeding it up or slowing it down slightly so it converges
without ever jumping. Monotonic time matters: jumping backwards breaks
timestamps, cron, databases, and TLS.

Its config points at a **pool** — a hostname like `2.debian.pool.ntp.org` that
resolves to a rotating set of volunteer servers.

And there's the deadlock. chrony starts early in boot, resolves its pool
hostnames, and builds a source list. If DNS is dead at that moment, it resolves
nothing, keeps an **empty source list**, and then sits there forever — it does
not retry resolution on a schedule. `systemctl status chrony` says `active
(running)` and everything looks fine. Which is what you see:

```
Reference ID    : 00000000 ()
Stratum         : 0
Leap status     : Not synchronised
```

`Reference ID: 00000000` means "synced to nothing." The source list is empty.
Restarting chrony after DNS works re-runs resolution and the sources appear.

Reading `chronyc sources -v`:

```
MS Name/IP address         Stratum Poll Reach LastRx Last sample
^* time-usw5.crimpac.net         2   6    17    50  -3722us[-3766us] +/- 70ms
^+ 172-104-28-175.ip.linode>     2   6    17    51  +4290us[+4246us] +/- 90ms
^- time.cloudflare.com           3   6    17    50   +591us[ +591us] +/- 45ms
^? some.server                   2   6     3     1  -49323s[-49323s] +/- 92ms
```

- `^*` — the selected source. You need exactly one.
- `^+` — a good source being combined with it.
- `^-` — measured, but excluded from the average.
- `^?` — unusable: unreachable, or not yet measured enough times.
- **Stratum** — hops from a reference clock. Stratum 1 is attached to GPS or an
  atomic clock; stratum 2 syncs from a stratum 1.
- **Reach** — an octal register of the last 8 polls. `377` is all eight
  successful; `17` means the four most recent worked (still filling up).

**`makestep` vs. steering.** With a 14-hour error, steering would take
approximately forever. `chronyc makestep` orders an immediate jump. chrony does
this automatically for large offsets during the first few updates after startup,
but only then — hence calling it explicitly.

**Why `hwclock --systohc`.** Two clocks exist: the kernel's system clock (RAM,
lost at power-off) and the RTC (battery-backed, on the motherboard). Boot reads
the RTC. Correcting only the system clock means the next cold boot reloads the
old wrong time. `--systohc` writes system time back to the RTC.

`timedatectl` showing `System clock synchronized: no` right after a successful
step is normal — it reflects a flag chrony raises only after it has confidence in
its estimate, a poll or two later.

</details>

<details>
<summary><b>📚 Why a wrong clock breaks apt</b></summary>

apt doesn't trust mirrors. It downloads an `InRelease` file — a package index
with an inline OpenPGP signature — and verifies it against keys in
`/etc/apt/trusted.gpg.d/`. Everything else is checked by hash against that signed
index, so one valid signature covers every package you install.

Debian 13 verifies with **`sqv`** (Sequoia), replacing the old `gpgv`. Sequoia is
stricter about time. An OpenPGP signature carries a creation timestamp, and a
signature whose creation time is **in the future relative to your clock** is not
merely suspicious — it's invalid:

```
Sub-process /usr/bin/sqv returned an error code (1), error message is:
Verifying signature: Not live until 2026-09-12T19:48:18Z
```

"Not live until" = this signature claims to have been made at a time you haven't
reached yet. With the host 14 hours behind, every freshly-signed index looked
like it came from the future. apt then reports:

```
The repository '...' is not signed.
```

Which sends you hunting for missing GPG keys. The keys were fine. This is also
why the *older* `trixie` index verified while `trixie-security` did not — the
security index had been re-signed more recently, landing on the far side of the
gap.

The same class of failure hits TLS certificates (`not yet valid`), Kerberos, and
JWTs. A wrong clock breaks cryptography broadly, and rarely says so plainly.

</details>

## 📦 Phase 2: Repositories

A stock install points at `enterprise.proxmox.com`, which returns **401** without
a paid subscription.

```bash
./02-fix-repos.sh
apt update && apt full-upgrade
```

Or in the UI: **Updates → Repositories** → select `pve-enterprise` → **Disable**
(same for enterprise `ceph-*`) → **Add** → `No-Subscription`.

<details>
<summary><b>📚 Proxmox repository tiers, and <code>upgrade</code> vs <code>full-upgrade</code></b></summary>

Proxmox ships three package channels:

| Repository | Needs subscription | Intended for |
|---|---|---|
| `pve-enterprise` | yes | Production. Slowest, most tested. |
| `pve-no-subscription` | no | Homelabs. Same packages, less soak time. |
| `pve-test` | no | Pre-release. Expect breakage. |

A default install enables `pve-enterprise`, so a fresh unlicensed node 401s on
its very first update. Nothing is wrong; it's asking for credentials you don't
have.

**Debian 13 file format.** Repos moved to deb822 `.sources` files — one stanza of
`Key: value` lines, instead of the old one-line `deb http://... trixie main`
format in `.list` files. More verbose, much easier to edit programmatically,
which is why `02-fix-repos.sh` handles both.

**`full-upgrade`, not `upgrade`.** Plain `upgrade` will never remove a package
and never install a new one — a deliberately conservative default. But Proxmox
transitions routinely rename packages, split them, or bump a kernel metapackage
that pulls in a new versioned kernel. `upgrade` responds by silently *holding
back* those packages, leaving you partially updated in a way that's easy to miss.
`full-upgrade` (the old `dist-upgrade`) is allowed to add and remove packages to
resolve dependencies, and is what Proxmox's own docs specify.

</details>

## 📡 Phase 3: Connect the Wi-Fi card

Still wired. This only associates the radio — routing is untouched, so you cannot
lock yourself out here.

```bash
./03-wifi-connect.sh
```

Success looks like:

```
Connected to aa:bb:cc:dd:ee:ff (on wlp3s0)
        SSID: YourSSID
        signal: -40 dBm
        rx bitrate: 270.0 MBit/s
```

Prove the radio has a real path out, without disturbing the live default route:

```bash
ip route add 1.1.1.1/32 via 192.168.0.1 dev wlp3s0
ping -c3 -I wlp3s0 1.1.1.1
ip route del 1.1.1.1/32
```

> `ping -I wlp3s0 1.1.1.1` **without** that temporary route will fail, and that's
> expected — Wi-Fi has no default route yet. Binding to an interface doesn't
> create a path; the kernel still needs a route telling it where to send the
> packet.

<details>
<summary><b>📚 The Linux wireless stack, layer by layer</b></summary>

Wi-Fi involves more moving parts than Ethernet, and knowing which layer you're
looking at makes failures much easier to place:

```
  wpa_supplicant          userspace daemon: scanning, auth, key exchange
        │  nl80211 (netlink)
  ┌─────┴──────┐
  │  cfg80211  │          kernel config API + regulatory enforcement
  │  mac80211  │          802.11 MAC for "softMAC" cards
  │   driver   │          rtw88_8822ce, iwlwifi, ath9k, ...
  │  firmware  │          blob running on the card itself
  └────────────┘
        │
     the radio
```

Each layer fails distinctly:

| Layer | Symptom | Check |
|---|---|---|
| firmware | interface never appears | `dmesg \| grep -i firmware` |
| driver | no interface, or instant disconnects | `lspci -k`, `dmesg` |
| regulatory | interface exists, sees no networks | `iw reg get` |
| rfkill | interface stays `DOWN` | `rfkill list` |
| supplicant | scans fine, never associates | `journalctl -u wpa_supplicant@IFACE` |

**Why a userspace daemon at all?** Ethernet is "plug in, link up." Wi-Fi requires
scanning, selecting a BSS, authenticating, associating, running a 4-way
cryptographic handshake, installing keys, and re-doing all of it on roaming or
timeout. That's policy, not packet-pushing, so it lives in userspace.
`wpa_supplicant` is that daemon, talking to the kernel over **nl80211**.

This is why `ip link set wlp3s0 up` appears to do nothing on an unassociated
card: without an association there's no carrier, so the interface reports `DOWN`
no matter how many times you ask it to come up. The link comes up as a
*consequence* of association, not before it.

**Reading the association output:**

- `signal: -40 dBm` — logarithmic, always negative. −30 excellent, −67 good for
  streaming, −80 marginal, −90 unusable. Each −3 dBm is half the power.
- `MCS 15` — Modulation and Coding Scheme; index 15 is 802.11n's top two-stream
  rate.
- `40MHz` — channel width. Double the standard 20 MHz, double the throughput,
  more interference on crowded 2.4 GHz.
- `short GI` — short guard interval, ~11% more throughput.
- rx and tx rates differ because each direction adapts independently.

</details>

<details>
<summary><b>📚 wpa_supplicant: the PSK, the handshake, and the silent failure</b></summary>

**The config file.** `wpa_passphrase` doesn't store your password — it derives a
key:

```
PSK = PBKDF2-SHA1(password, SSID, 4096 iterations, 256 bits)
```

The SSID is the salt, which is why the same password on two differently-named
networks produces different keys, and why you must regenerate the file if the
SSID changes. Output:

```txt
network={
	ssid="YourSSID"
	psk=7f3c9e1a2b...64 hex chars...d8
}
```

That 64-hex-character value **is** the credential. Anyone with it can join the
network; possession of it is equivalent to knowing the password, so the file is
`chmod 600`.

`wpa_passphrase` also emits your plaintext password as a `#psk="..."` comment.
`03-wifi-connect.sh` strips that line — there's no reason for the plaintext to
exist on disk.

**The failure that started this.** A config with `key_mgmt=WPA-PSK` and the
`psk=` line commented out produces exactly this in the journal:

```
Successfully initialized wpa_supplicant
```

...and then nothing. Forever. No error, no retry, no complaint. The daemon is
running, the interface exists, and it will never associate, because it has no
credential to associate with. `systemctl status` shows `active (running)` the
whole time.

The lesson generalizes: **"the service is running" is not "the service is
working."** For wpa_supplicant, the real health check is
`wpa_cli -i IFACE status` returning `wpa_state=COMPLETED`.

**What association involves**, when it does work:

1. **Scan** — listen for beacons, or probe actively.
2. **Authentication** — a legacy 802.11 step, mostly vestigial under WPA2.
3. **Association** — the AP allocates state and an association ID.
4. **4-way handshake** — both sides prove they hold the PSK *without
   transmitting it*, and derive fresh per-session keys. A wrong password fails
   here, logging `4-Way Handshake failed` — a very different signature from the
   silent no-PSK case.
5. **Keys installed**, carrier comes up, and only now does the interface go `UP`.

**Why the `wpa_supplicant@IFACE` systemd unit** rather than a `wpa-conf` line in
`/etc/network/interfaces`? Proxmox uses `ifupdown2`, a Python reimplementation of
ifupdown built for bridges, bonds, and VLANs at scale. Its handling of `wpa-*`
options is incomplete and version-dependent. The systemd template unit is
independent of the network stack, starts early, restarts on failure, and is
managed with ordinary systemd commands. It reads
`/etc/wpa_supplicant/wpa_supplicant-%I.conf` where `%I` is the instance name —
which is why the filename must match the interface exactly.

</details>

<details>
<summary><b>📚 Regulatory domains and rfkill</b></summary>

**Regulatory domain.** Legal channels, power limits, and DFS rules differ by
country. The kernel refuses to transmit outside them, so it needs to know where
you are. `wireless-regdb` provides a signed database; `country=XX` in the
supplicant config selects the entry.

```
cfg80211: failed to load regulatory.db
```

Without it the kernel falls back to the most restrictive possible set — world
domain `00`. Symptoms are confusing: 2.4 GHz mostly works, while 5 GHz networks
are simply invisible, because most 5 GHz channels are country-specific. Check
with `iw reg get`.

**rfkill** is the kernel's radio kill-switch subsystem:

- **Soft block** — software. A `rfkill block` command, a desktop toggle, a
  driver default. Clear with `rfkill unblock wifi`.
- **Hard block** — a physical switch, a laptop Fn-key, or a BIOS setting. No
  command clears it; you have to flip the switch.

A blocked radio shows the interface present but permanently `DOWN`, which looks
identical to several other problems — so `rfkill list` is worth checking first.
It costs a second and rules out a whole class of causes.

</details>

## 🔀 Phase 4: Cutover to Wi-Fi, with NAT for guests

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

Three things carry all the weight:

- `bridge-ports none` — vmbr0 stops being tied to the NIC and becomes a pure
  virtual switch. Guests keep attaching to `vmbr0` exactly as before.
- **Exactly one `gateway` line** in the whole file, on the Wi-Fi interface.
- Proxmox's UI parser is strict: **no inline comments, no stray blank lines.**

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

Then verify and unplug:

```bash
./99-verify.sh      # want: default route on wlp3s0
# pull the Ethernet cable
./99-verify.sh
```

<details>
<summary><b>📚 What a Linux bridge is, and what <code>bridge-ports none</code> does</b></summary>

A Linux bridge is a **software Ethernet switch** inside the kernel. It learns
which MAC addresses live behind which ports and forwards frames accordingly. Its
member ports can be physical NICs, VM tap devices, container veth pairs, or VLAN
interfaces — the bridge doesn't care.

Standard Proxmox setup:

```
    LAN ── nic0 ──┬── vmbr0 ──┬── tap100i0 (VM 100)
                  │           ├── tap101i0 (VM 101)
                  │           └── host IP 192.168.0.100
```

`vmbr0` is a switch whose uplink is `nic0`. Guests land on your LAN; your router
gives them addresses; other machines can reach them. The host also gives itself
an IP on that bridge.

After cutover:

```
    LAN ── wlp3s0 (host IP 192.168.0.100, default route)
             │  NAT
    vmbr0 ──┴── 10.10.10.1  ──┬── tap100i0 (VM 100 → 10.10.10.50)
    (no physical port)        └── tap101i0 (VM 101 → 10.10.10.51)
```

`bridge-ports none` removes the uplink. vmbr0 is now an **isolated virtual
switch** — guests can talk to each other and to the host at `10.10.10.1`, and
nothing else. The host routes and translates between the two worlds.

Guest config doesn't change: they still attach to `vmbr0`, they just get
different addresses.

**`bridge-stp off`** disables Spanning Tree, the protocol that prevents loops in
switched networks by blocking redundant paths. With a single bridge and no
redundant links there's no loop to prevent, and STP only adds convergence delay.

**`bridge-fd 0`** sets forwarding delay to zero. With STP on, a bridge waits ~15
seconds in listening/learning before forwarding, to avoid loops during
convergence. With STP off, that wait is pure startup latency — and it's long
enough to make guests miss their DHCP window on boot.

**Why vmbr0 shows `DOWN` with no guests running:** a bridge has carrier only if
at least one member port does. Empty bridge, no carrier, `state DOWN`, and its
route marked `linkdown`. Start one VM and its tap interface joins, carrier
appears, and the bridge comes up. This is normal and not worth chasing.

</details>

<details>
<summary><b>📚 NAT, MASQUERADE, and connection tracking</b></summary>

Guests have `10.10.10.x` addresses. Those are RFC 1918 private addresses — your
router won't route them, and the internet certainly won't. Something must
**translate** them.

The rule:

```bash
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o wlp3s0 -j MASQUERADE
```

Read piece by piece:

| Part | Meaning |
|---|---|
| `-t nat` | the NAT table, consulted for the first packet of each new connection |
| `-A POSTROUTING` | append to the chain traversed *after* the routing decision, just before transmission |
| `-s 10.10.10.0/24` | only for traffic originating in the VM subnet |
| `-o wlp3s0` | only for traffic leaving via Wi-Fi |
| `-j MASQUERADE` | rewrite the source address to this interface's current IP |

`MASQUERADE` is `SNAT` that looks up the outgoing interface's address at runtime
instead of hardcoding it — the right choice when the address could change (DHCP,
reconnects), at a small per-connection cost.

**How return traffic finds its way back.** This is the part that feels like
magic. When a guest at `10.10.10.50:51234` connects to `1.1.1.1:443`, the host
rewrites the source to `192.168.0.100:<some port>` and records the mapping in the
**conntrack** table:

```
10.10.10.50:51234 ──> 192.168.0.100:61000 ──> 1.1.1.1:443
```

The reply comes back to `192.168.0.100:61000`. conntrack matches it to the stored
entry, rewrites the destination back to `10.10.10.50:51234`, and forwards it over
vmbr0. Inspect the live table with `conntrack -L` or `cat
/proc/net/nf_conntrack`.

This is also precisely why **inbound connections don't work**: with no prior
outbound packet, there's no conntrack entry, so an unsolicited packet arriving at
the host matches nothing and has no guest to be delivered to. Port forwarding
(`DNAT`) fixes that by creating the mapping explicitly, in advance.

**IP forwarding.** By default a Linux host drops packets not addressed to itself
— it's a host, not a router. `net.ipv4.ip_forward=1` changes that. Setting it in
`/etc/sysctl.d/99-nat.conf` rather than a `post-up` hook means it applies during
early boot, before interfaces come up, avoiding a window where guests exist and
forwarding doesn't.

**Why `post-up`/`post-down` hooks for the rule?** iptables rules live in memory
and vanish on reboot. Tying them to vmbr0's lifecycle means they're installed
exactly when the interface they describe exists, and removed when it goes away —
no duplicate rules accumulating across `ifreload` cycles. (`iptables-persistent`
is the alternative; the hook keeps everything in one file.)

</details>

<details>
<summary><b>📚 dnsmasq, DHCP, and the open-resolver trap</b></summary>

Guests need addresses. Your router can't provide them — it never sees the VM
network. So the host runs its own DHCP server.

**dnsmasq** is a combined DHCP server, DNS forwarder, and TFTP server, built to
be small enough for routers. Here it does two jobs: hand out leases, and forward
guest DNS queries upstream.

**How a guest gets an address** — DHCP's four-step DORA exchange, all of it
broadcast initially, since the client has no address yet:

| Step | Direction | Meaning |
|---|---|---|
| **D**ISCOVER | client → broadcast | "Is there a DHCP server?" |
| **O**FFER | server → client | "Take 10.10.10.50" |
| **R**EQUEST | client → broadcast | "I'll take 10.10.10.50" (broadcast so other servers withdraw) |
| **A**CK | server → client | "Confirmed, 12-hour lease" |

Watch it live with `journalctl -fu dnsmasq`.

The options matter as much as the address:

- `option:router` → the guest's default gateway, `10.10.10.1` (the host). Without
  it a guest can reach its own subnet and nothing else.
- `option:dns-server` → where to resolve names. Pointed upstream directly here;
  `10.10.10.1` would work too and give you caching plus guest hostname
  resolution.

**`bind-dynamic` vs `bind-interfaces` — the security bug this avoids.**

By default dnsmasq opens a wildcard socket on `0.0.0.0:53` — every interface,
present and future — and filters by interface after the fact.

- `bind-interfaces` binds to specific addresses instead, but enumerates them
  **once at startup**. vmbr0 with no guests has no carrier, so at startup there
  may be nothing to bind to. dnsmasq then binds what it *can* find — which
  included `192.168.0.100`, the LAN-facing Wi-Fi address:

  ```
  UNCONN  0  0  192.168.0.100:53  0.0.0.0:*  users:(("dnsmasq",pid=9512,fd=6))
  ```

  That is an **open DNS resolver on your home network**. Best case, neighbors use
  your DNS. Worst case, if the router forwards port 53 from outside, it's a DNS
  amplification reflector — attackers send small spoofed queries and your host
  blasts large responses at a victim.

- `bind-dynamic` watches for interface changes with netlink and binds as
  interfaces appear. Combined with `listen-address=10.10.10.1` and
  `no-dhcp-interface=wlp3s0`, it serves the bridge and only the bridge.

Always verify after changing this:

```bash
ss -lnup | grep :53      # want 10.10.10.1 and loopback, never your LAN address
```

The general lesson: a service that binds "whatever it finds" will eventually find
something you didn't intend. Bind explicitly.

</details>

<details>
<summary><b>📚 Routing, and how to tell which path traffic really takes</b></summary>

The routing table after cutover:

```
default via 192.168.0.1 dev wlp3s0 proto kernel onlink
10.10.10.0/24 dev vmbr0 proto kernel scope link src 10.10.10.1
192.168.0.0/24 dev wlp3s0 proto kernel scope link src 192.168.0.100
```

The kernel picks a route by **longest prefix match** — most specific wins,
regardless of order in the listing. `/24` beats `default` (which is `/0`,
matching everything with zero specificity), so `default` is only used when
nothing more specific matches.

`scope link` means "directly reachable, no gateway needed" — ARP for the
destination and send. Routes with `via` need a gateway to forward on your behalf.

**Ask the kernel instead of guessing:**

```bash
ip route get 1.1.1.1
1.1.1.1 via 192.168.0.1 dev wlp3s0 src 192.168.0.100
```

This performs a real lookup and reports the decision, including the source
address it would use. It's the single most useful command for "is this actually
going over Wi-Fi?" — far more reliable than inferring from the table by eye.

**Why only one `gateway` line.** Each `gateway` in `/etc/network/interfaces`
installs a default route. Two of them means two `default` entries with equal
specificity, and traffic follows whichever the kernel picks — usually by metric,
effectively arbitrary if metrics aren't set. Symptoms are maddening:
intermittent connectivity, asymmetric paths, breakage that moves when you restart
networking. One default route.

**Why `ping -I wlp3s0 1.1.1.1` failed before cutover.** `-I` binds the socket to
an interface, but the kernel still consults the routing table to decide where to
send the packet. Wi-Fi had no default route at that point, so the lookup returned
"no route to host." Adding a temporary `/32` route gave it a specific path — more
specific than any default — which is what made the test meaningful:

```bash
ip route add 1.1.1.1/32 via 192.168.0.1 dev wlp3s0
```

**Both interfaces on one subnet** (during the transitional phase) is legal but
worth understanding: Linux answers ARP for any of its addresses on any
interface by default (`arp_ignore=0`), so the same host may reply on both. It's
fine for a brief test, and one more reason not to linger in that state.

</details>

### Optional: static leases for guests

`/etc/dnsmasq.d/static-ips.conf`:

```txt
dhcp-host=52:54:00:12:34:56,10.10.10.50,my-ubuntu-vm
```

The guest still runs DHCP — dnsmasq just always answers with the same address for
that MAC. Better than static config inside the guest: it's centralized, and
there's no chance of a conflict with the dynamic range.

### Optional: expose a guest to the LAN

Guests behind NAT aren't reachable from your home network. Forward individual
ports — this maps host `:8080` to a guest's web server:

```bash
iptables -t nat -A PREROUTING -i wlp3s0 -p tcp --dport 8080 -j DNAT --to 10.10.10.50:80
```

Add it as another `post-up` line on vmbr0 to survive reboots.

<details>
<summary><b>📚 DNAT: the mirror image of MASQUERADE</b></summary>

`PREROUTING` is traversed *before* the routing decision, which is the point:
rewriting the destination there changes where the packet gets routed. By the time
the kernel decides what to do with it, it's addressed to `10.10.10.50:80` and
routes naturally over vmbr0.

MASQUERADE and DNAT are symmetric:

| | MASQUERADE (outbound) | DNAT (inbound) |
|---|---|---|
| Chain | POSTROUTING (after routing) | PREROUTING (before routing) |
| Rewrites | source address | destination address |
| Triggered by | a guest starting a connection | an outsider starting a connection |
| Conntrack | creates the mapping | uses the static rule, then tracks |

Return traffic needs no second rule in either direction — conntrack reverses the
translation automatically.

</details>

## ✅ Phase 5: Verify

```bash
./99-verify.sh
```

Checks association, boot-persistence of `wpa_supplicant@`, routing, whether the
cable is actually out, connectivity, NAT, DHCP scoping, clock, repos, and the UI
listener.

```
=== result ===
  passed: 16   failed: 0
  ALL CHECKS PASS
```

<details>
<summary><b>📚 What makes a verification script worth having</b></summary>

Manual checking fails in a specific way: you check the thing you just changed,
it works, you move on — and miss that something three steps back regressed.

The properties that make this one useful:

- **Read-only.** Safe to run at any time, including mid-incident, without
  changing the state you're trying to diagnose.
- **Tests behavior, not configuration.** `systemctl is-active dnsmasq` says a
  process is running. `ss -lnup | grep 10.10.10.1:53` says it's listening where
  intended. The second is what you actually care about — recall that
  wpa_supplicant was `active (running)` for the entire time it wasn't working.
- **Tests the negative too.** It checks that dnsmasq is *not* on your LAN
  address. Absence of a bad state is as much a property as presence of a good
  one, and it's the half people forget.
- **Prints raw output alongside pass/fail.** When something fails you want the
  actual `ip route` output right there, not just a red X.
- **Non-zero exit on failure**, so it can be dropped into cron or a CI check.

The `00-preflight.sh` / `99-verify.sh` split is deliberate: preflight answers
"can I safely start?", verify answers "did it work, and does it still?" Run
verify after every reboot and every kernel upgrade.

</details>

### Migrating existing guests

Guests with a **static** LAN address are stranded after cutover — that subnet now
lives on Wi-Fi, not on vmbr0. Switch them to DHCP, or to `10.10.10.x` with
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

### The first reboot

Wi-Fi is now the only way in.

```bash
systemctl is-enabled wpa_supplicant@wlp3s0    # must say 'enabled' BEFORE you reboot
```

Reboot with a monitor attached, then run `./99-verify.sh` again.

<details>
<summary><b>📚 Why the first reboot is the real test</b></summary>

Everything up to here was configured on a running system. A reboot proves
something different: that the configuration is **persistent and correctly
ordered**, with nothing depending on state you created by hand.

What has to work, in order:

1. udev names the interface `wlp3s0` (predictable naming, or the config points at
   a device that doesn't exist)
2. The driver loads and pulls firmware from disk
3. `wireless-regdb` loads so channels are permitted
4. `wpa_supplicant@wlp3s0` starts — **only if enabled**; `systemctl start` alone
   does not survive a reboot
5. Association completes, carrier comes up
6. `ifupdown2` configures addresses and installs the default route
7. vmbr0 comes up and its `post-up` hook installs the NAT rule
8. `net.ipv4.ip_forward` is applied from `/etc/sysctl.d/`
9. dnsmasq starts and binds to vmbr0
10. chrony resolves its pool — which now works, because DNS does

A single missed `systemctl enable` breaks the chain at step 4 and leaves you at
the console. That's why it's the last check before rebooting.

Kernel upgrades are the recurring risk: a new kernel means a new `rtw88` module,
and wireless drivers do regress. Keeping the previous kernel installed gives you
a GRUB entry to fall back to.

</details>

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
| `4-Way Handshake failed` | Wrong password | Regenerate with the correct one |
| Interface stays `DOWN` | rfkill block, or not associated | `rfkill list`; check association |
| SSID missing from scan | Missing regdb, or hidden SSID | `apt install wireless-regdb`; add `scan_ssid=1` |
| `failed to load regulatory.db` | `wireless-regdb` missing | `apt install wireless-regdb` |
| `Not connected` after reboot | Unit not enabled | `systemctl enable wpa_supplicant@IFACE` |
| Guests get an IP, no internet | Forwarding or NAT rule | `sysctl net.ipv4.ip_forward`; `iptables -t nat -S POSTROUTING` |
| Guests get no IP | dnsmasq not bound to vmbr0 | `bind-dynamic`; `journalctl -u dnsmasq` |
| `:53` on your LAN address | `bind-interfaces` with no carrier | `bind-dynamic` + `listen-address` |
| `/var/log/syslog` missing | Debian 13 dropped rsyslog | `journalctl -fu <unit>` |
| `vmbr0 DOWN` / route `linkdown` | Bridge has no carrier | Normal with no guests running |

### A method for unfamiliar failures

The chain that broke `apt` here spanned four layers, and the error message named
none of them. Working bottom-up is what makes that tractable — each layer only
works if the one below it does:

| Layer | Question | Command |
|---|---|---|
| 1. Physical | Is there a link? | `ip -br a`, `rfkill list`, `iw dev IFACE link` |
| 2. Addressing | Do we have an IP? | `ip -br a` |
| 3. Routing | Is there a path? | `ip route get 1.1.1.1` |
| 4. Reachability | Do packets return? | `ping 1.1.1.1` |
| 5. Naming | Do names resolve? | `getent hosts deb.debian.org` |
| 6. Time | Is the clock right? | `timedatectl`, `chronyc tracking` |
| 7. Application | Does the app work? | `apt update` |

Start at 1 and stop at the first failure — everything above it is noise until
that layer is fixed. Layer 6 belongs on the list precisely because it's invisible
otherwise: it breaks TLS, package signatures, and auth tokens while every network
test passes.

### Useful commands

```bash
iw dev wlp3s0 link                            # association state
iw dev wlp3s0 scan | grep -i 'SSID:' | sort -u
iw reg get                                    # active regulatory domain
wpa_cli -i wlp3s0 status                      # want wpa_state=COMPLETED
journalctl -u wpa_supplicant@wlp3s0 -n 40 --no-pager
iptables -t nat -L POSTROUTING -n -v          # with packet/byte counters
conntrack -L                                  # live NAT translations
ss -lnup | grep :53                           # what is listening on DNS
ip route get 1.1.1.1                          # which interface really carries traffic
journalctl -fu dnsmasq                        # watch DHCP leases
```

> `iptables -L -n -v` counters are underused: if a rule's counter is zero, no
> traffic is matching it, and the rule is wrong or unreached. That distinguishes
> "rule is broken" from "traffic never got here" in one glance.

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

## Glossary

| Term | Meaning |
|---|---|
| **802.11** | The IEEE standard family behind Wi-Fi |
| **BSSID** | An access point radio's MAC address. Geolocatable via public wardriving databases — don't publish yours |
| **bridge** | A software Ethernet switch in the kernel |
| **cfg80211 / nl80211** | Kernel wireless configuration layer, and the netlink API into it |
| **conntrack** | Connection tracking; remembers NAT mappings so replies find their way home |
| **DORA** | DHCP's Discover → Offer → Request → Ack exchange |
| **ifupdown2** | Proxmox's network config engine; reads `/etc/network/interfaces`, applied with `ifreload -a` |
| **InRelease** | A signed package index; apt's root of trust for a repository |
| **MASQUERADE** | SNAT that uses the outgoing interface's current address |
| **MCS** | Modulation and Coding Scheme; the rate index a Wi-Fi link negotiated |
| **NAT** | Network Address Translation; rewriting addresses so a private subnet can share one public-facing address |
| **PSK** | Pre-Shared Key; the 256-bit key derived from your Wi-Fi password and SSID |
| **RFC 1918** | The private address ranges: `10/8`, `172.16/12`, `192.168/16` |
| **rfkill** | Kernel radio kill-switch subsystem, soft (software) and hard (physical) |
| **RTC** | Real-Time Clock; the battery-backed clock the system reads at boot |
| **regulatory domain** | Per-country channel and transmit-power rules the kernel enforces |
| **stratum** | Distance from a reference clock in NTP; stratum 1 is directly attached to one |
| **tap device** | A virtual interface representing a VM's NIC on the host side |

## Final disclaimer

Homelab use. Not for production. A Wi-Fi uplink means lower throughput, higher
latency, and a dependency on your AP staying up — for a hypervisor running
several guests that's a real downgrade from a cable. If Ethernet is physically
possible where the box lives, use it.
