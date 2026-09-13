# 🖥️ Creating a VM on Proxmox

Getting an installer image, building a VM with settings that aren't the wizard's
defaults, installing Debian, and making the guest's services reachable from your
LAN when it lives behind NAT.

Commands first in each section; the collapsed blocks explain what the setting
does and why it matters. Expand them to understand the system, skip them to just
get it working.

Tested on Proxmox VE 9.2.2 with Debian 13 guests.

---

## Quick start

```bash
git clone https://github.com/marcosmamg/proxmox_homelab_resources.git
cd proxmox_homelab_resources/proxmox-vm/scripts
nano config.sh              # VMID, sizing, storage, ISO

./00-get-iso.sh --race      # which mirror is actually fast from here?
./00-get-iso.sh             # download from several at once, then verify
./01-create-vm.sh           # create with the right settings
qm start 100                # install via the UI console

./99-verify-vm.sh           # read-only: did everything land?
```

| Script | Safe? | What it does |
|---|---|---|
| `00-get-iso.sh` | yes | Multi-mirror download + **checksum verification** |
| `01-create-vm.sh` | creates | `qm create` with non-default settings, refuses without VT-x |
| `02-expose-port.sh` | changes NAT | Publishes one guest port on the host's LAN IP, persistently |
| `99-verify-vm.sh` | read-only | Config audit, guest IP, published ports, host headroom |

---

## ⚠️ Before you start: hardware virtualization

```bash
grep -c vmx /proc/cpuinfo      # Intel; want non-zero
grep -c svm /proc/cpuinfo      # AMD
```

Zero means it's disabled in the BIOS, and starting a VM fails with:

```
TASK ERROR: KVM virtualisation configured, but not available.
Either disable in VM configuration or enable in BIOS.
```

Reboot into BIOS setup and enable **Intel Virtualization Technology (VT-x)** or
**AMD-V**, usually under *Advanced → CPU Configuration*. Enable **VT-d / AMD-Vi
(IOMMU)** at the same time — you don't need it today, but PCIe passthrough does,
and it saves a second trip.

<details>
<summary><b>📚 What KVM actually does, and why software emulation isn't an option</b></summary>

QEMU can run a guest two ways:

- **TCG** — binary translation. Every guest instruction is translated and
  executed by the host in software. Works anywhere, 10–20× slower.
- **KVM** — the guest runs *natively* on the CPU. Intel VT-x and AMD-V add a
  hardware mode where guest code executes directly at full speed, trapping to
  the hypervisor only for privileged operations (I/O, page-table changes). The
  kernel module `kvm_intel` / `kvm_amd` drives it.

The difference isn't a tuning detail. A container stack that takes 3 minutes to
start under KVM takes the better part of an hour under TCG. `kvm: 0` exists for
testing on hardware that can't do better, not as a workable option.

Confirm KVM is live:

```bash
lsmod | grep kvm       # want kvm_intel or kvm_amd
```

The use count on `kvm_intel` shows how many vCPUs are currently attached, which
is a quick way to see that a guest is really using hardware acceleration.

Why it's off by default on so many boards: VT-x adds a small attack surface and
most desktop buyers never use it, so vendors ship it disabled. The host installs
and runs fine without it — you only find out when you start your first guest.

</details>

---

## Getting the ISO

```bash
./00-get-iso.sh --race    # measure mirrors
./00-get-iso.sh           # download + verify
./00-get-iso.sh --torrent # or via BitTorrent
```

Then always:

```bash
./00-get-iso.sh --verify
```

> ⚠️ **Never boot an installer you haven't checksummed.** A corrupt ISO doesn't
> announce itself — it drops you at a bare `grub>` prompt with no explanation.

<details>
<summary><b>📚 How <code>wget -c</code> silently corrupts a download</b></summary>

`wget -c` resumes by asking for a byte range starting where the local file ends.
It does **not** verify that the remote file is the same one the partial came
from.

So this sequence produces garbage:

```bash
wget https://mirror-a/.../debian-13.7.0-netinst.iso    # interrupted at 40%
wget -c https://mirror-b/.../debian-13.7.0-netinst.iso # "resumes" from mirror B
```

If mirror B doesn't honor the range request the same way — or the partial was
from a different version entirely — the new bytes are appended rather than
continued. The result looks finished:

```
-rw-r--r-- 1 root root 1.5G debian-13.7.0-amd64-netinst.iso
```

except the real image is **756 MB**. Twice the expected size is the tell, and
the symptom at boot is GRUB loading, failing to find its config, and dropping to
`grub>`.

Rules that avoid this entirely:

1. **Resume only against the same URL.** Different mirror, start over.
2. **Always checksum.** `sha256sum -c SHA256SUMS` takes seconds.
3. **Prefer BitTorrent for installer images.** Every chunk is hash-verified on
   arrival, so a corrupt result is structurally impossible — and it's usually
   faster, since it pulls from many peers rather than one slow mirror.

</details>

<details>
<summary><b>📚 When the mirror is slow, and how to tell it apart from your link</b></summary>

Before optimizing a download, find out whether the bottleneck is *yours*.

**1. Measure your actual WAN capacity** against something known-fast, not a
Debian mirror:

```bash
# macOS has this built in
networkQuality

# or any machine
curl -s -o /dev/null -r 0-20000000 -w '%{speed_download} B/s\n' \
  http://cachefly.cachefly.net/100mb.test
```

**2. Race the mirrors** — `./00-get-iso.sh --race`. Real numbers from one
Central American connection with 41 Mbps of capacity:

| Source | Speed |
|---|---|
| cachefly (CDN baseline) | 2,002 KB/s |
| mirrors.ocf.berkeley.edu | 513 KB/s |
| mirror.us.leaseweb.net | 318 KB/s |
| mirror.steadfast.net | 10 KB/s |
| three other mirrors | < 1 KB/s |

A 2,000× spread between mirrors, on a link that was never the problem. Debian's
mirror network is volunteer-run and unevenly connected; `cdimage.debian.org`
geo-routes by your *resolver's* location, so using a public DNS resolver can
send you to another continent.

**3. Pull from several at once.** `aria2c` splits one file across mirrors:

```bash
aria2c -x 4 -s 8 -k 1M -o out.iso URL1 URL2 URL3
```

`-x` is connections per host, `-s` total splits. This also helps when a single
mirror throttles per connection.

**Don't bother downloading on another machine on the same network** — it shares
the same WAN link and adds a transfer hop. Measure both before assuming one is
faster.

</details>

---

## Sizing the VM

| Workload | Cores | RAM | Disk |
|---|---|---|---|
| Small service, reverse proxy | 2 | 2 GB | 20 GB |
| General dev box | 4 | 8 GB | 60 GB |
| Docker stack with a database | 8 | 12 GB | 150 GB |
| Stack with OpenSearch/Elasticsearch | 8–10 | 16 GB | 200 GB |

Leave the host **4–8 GB of RAM** and a couple of threads. Proxmox itself is
light (~2 GB), but a host under memory pressure starts swapping and everything
suffers.

<details>
<summary><b>📚 Overcommitting cores is fine; overcommitting RAM is not</b></summary>

**vCPUs** are scheduled like processes. Ten vCPUs on a 16-thread host is
unremarkable, and the sum across all guests can exceed the host's thread count —
they're only competing when actually running. Assigning *more vCPUs than the
host has threads to a single VM* is the mistake: the guest's scheduler assumes
its CPUs run in parallel, and it can't.

**RAM** is different. Without ballooning, every MB assigned is reserved. Two
16 GB VMs on a 24 GB host will not both start. With ballooning the host can
reclaim idle guest memory, but that has real costs for some workloads
(see below), so it's not a free way to overcommit.

**Disk** is thin-provisioned on LVM-thin, so a 200 GB guest disk consumes only
what's written — but the pool can be over-provisioned across guests and fill up.
Watch `lvs -o +data_percent`.

The practical order to think about it: RAM is the hard constraint, disk is a
monitoring problem, cores are usually a non-issue.

</details>

---

## Creating the VM

**Script:**

```bash
./01-create-vm.sh
```

**Or the UI** — `Create VM`, with these deviations from the defaults:

| Tab | Setting | Default | Use | Why |
|---|---|---|---|---|
| General | Start at boot | off | **on** | Guest returns after a host reboot |
| System | Machine | i440fx | **q35** | Modern PCIe chipset |
| System | BIOS | SeaBIOS | **OVMF (UEFI)** | Modern firmware; needed for passthrough |
| System | SCSI Controller | VirtIO SCSI single | keep | Required for discard + iothread |
| System | Qemu Agent | off | **on** | Host can see the IP and shut down cleanly |
| Disks | Discard | off | **on** | Returns freed blocks to the thin pool |
| Disks | SSD emulation | off | **on** | Guest picks the right I/O scheduler |
| Disks | IO thread | on | keep | Disk I/O gets its own thread |
| CPU | Type | x86-64-v2-AES | **host** | Exposes AVX2, AES-NI to the guest |
| Memory | Ballooning | on | **off** | JVMs and databases react badly |
| Network | Model | VirtIO | keep | Paravirtualized, far faster than emulated |
| Network | Firewall | on | **off** | One less layer while NAT is in play |

> ⚠️ The wizard **does not carry your changes forward if you navigate with the
> tab headers instead of Next**. Always check the Confirm screen against what
> you intended before clicking Finish.

The Confirm screen should read roughly:

```
agent      1
balloon    0
bios       ovmf
cores      10
cpu        host
efidisk0   local-lvm:1,efitype=4m,pre-enrolled-keys=1
ide2       local:iso/debian-13.7.0-amd64-netinst.iso,media=cdrom
machine    q35
memory     16384
net0       virtio,bridge=vmbr0
onboot     1
scsi0      local-lvm:200,iothread=on,discard=on,ssd=on
scsihw     virtio-scsi-single
```

<details>
<summary><b>📚 VirtIO: why paravirtualized devices are faster</b></summary>

An emulated device (say, an Intel e1000 NIC) works by having QEMU pretend to be
that chip. The guest driver writes to what it thinks are hardware registers,
each write traps to the hypervisor, QEMU decodes it and does the real work. It's
faithful — an unmodified driver works — and it's slow, because every register
access is a context switch.

**VirtIO** drops the pretense. Guest and host agree on a shared-memory ring
buffer: the guest places requests in a queue, rings a doorbell once, and the
host processes a batch. One trap per batch instead of per register write.

Practically: emulated NICs cap out around 1 Gbit with high CPU; VirtIO reaches
10 Gbit+. Disk is similar. The only reason to use emulated devices is an OS
without VirtIO drivers (older Windows, mostly — which is why `virtio-win` ISOs
exist).

`virtio-scsi-single` gives each disk its own controller, which is what allows
`iothread=1` to give that disk a dedicated I/O thread instead of sharing QEMU's
main loop.

</details>

<details>
<summary><b>📚 <code>cpu: host</code>, and what the default hides</b></summary>

The default `x86-64-v2-AES` is a *synthetic* CPU model — a defined baseline of
instructions that any reasonably modern x86 chip supports. It exists so a VM can
live-migrate between hosts with different CPUs: the guest sees the same
capabilities everywhere.

The cost is that anything newer is hidden. AVX2, AVX-512, and newer crypto
extensions simply don't appear in the guest's CPUID. Software that checks at
startup — JVMs, numeric libraries, video encoders, TLS stacks — silently selects
slower code paths.

`host` passes the real CPU through. On a single node there's no migration to
protect, so there's no reason not to.

Check what the guest actually sees:

```bash
# inside the VM
lscpu | grep -E 'Model name|Flags' | head -2
grep -o 'avx2\|aes' /proc/cpuinfo | sort -u
```

The one case for a named model is a cluster with mixed CPU generations, where
you'd pick the oldest common denominator.

</details>

<details>
<summary><b>📚 Why ballooning off, and what it costs you</b></summary>

The balloon driver lets the host reclaim guest memory: a driver inside the guest
allocates pages and hands them back to the host, "inflating" to shrink the
guest's usable RAM. It's how you overcommit memory across guests.

It works badly for some very common workloads:

- **JVMs** (OpenSearch, Elasticsearch, Kafka) allocate a heap at startup and
  assume it stays. Reclaiming underneath them causes GC thrashing or OOM kills.
- **Databases** size their buffer pools from what they see at boot.
- **Page cache** is memory the guest *is* using productively; the host can't
  tell the difference between that and idle memory.

For a workstation-style VM that idles most of the time, ballooning is fine and
lets you pack more guests on. For a server VM running a database or a JVM, turn
it off and accept the reservation.

Setting `balloon: 0` in the config disables it entirely. In the UI it's the
**Ballooning Device** checkbox under Memory → Advanced.

</details>

<details>
<summary><b>📚 Discard: the setting that decides whether your disk ever shrinks</b></summary>

Thin provisioning allocates blocks on first write. Nothing ever *un*-allocates
them by itself, because when a guest deletes a file it just updates its own
filesystem metadata — the host sees no writes at all and has no idea those
blocks are now free.

So without discard, a 200 GB guest disk grows monotonically toward 200 GB no
matter how much you delete inside it. On a host running Docker — which churns
image layers constantly — that happens fast.

`discard=on` lets the guest issue TRIM/UNMAP commands that pass through to the
thin pool. Requirements, all three:

1. `discard=on` on the disk
2. `virtio-scsi-single` (or another SCSI controller — IDE won't do it)
3. The guest actually issuing TRIM

Most distros ship a weekly `fstrim.timer`. Force it and watch the effect:

```bash
# inside the guest
sudo fstrim -av

# on the host
lvs -o lv_name,data_percent
```

`ssd=1` is related but separate: it tells the guest the disk is non-rotational,
so Linux picks an appropriate I/O scheduler and doesn't optimize for seek
latency that doesn't exist.

</details>

---

## Installing Debian

Start the VM and open **Console**.

**Partitioning** — the one screen that matters:

```
Guided - use entire disk
  → All files in one partition
```

> ⚠️ Do **not** choose the separate `/home`, `/var`, `/tmp` layout. Docker
> stores images in `/var/lib/docker`; an installer-sized `/var` will fill and
> wedge Docker while the rest of the disk sits empty. Skip LVM inside the guest
> too — you're already on an LVM thin pool at the host level.

**Software selection** — uncheck the desktop, keep SSH:

```
[ ] Debian desktop environment
[ ] GNOME
[*] SSH server
[*] standard system utilities
```

**After first boot**, inside the guest:

```bash
sudo apt update && sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

Then on the host, detach the installer so it doesn't boot again:

```bash
qm set 100 --boot order='scsi0;ide2'
qm set 100 --ide2 none,media=cdrom
```

<details>
<summary><b>📚 What the guest agent gives you</b></summary>

`qemu-guest-agent` is a daemon inside the guest talking to the host over a
virtio serial channel — not the network, so it works regardless of the guest's
IP or firewall.

With it:

- **Proxmox shows the guest's IP** in the Summary panel
- **Shutdown works properly.** Without the agent, "Shutdown" sends an ACPI power
  button event and hopes the guest honors it. With it, the host asks the OS
  directly.
- **Backups can be filesystem-consistent.** The host asks the guest to freeze
  its filesystems (`fsfreeze`) for the instant the snapshot is taken, so the
  backup isn't a crash-consistent image mid-write.
- **`qm agent <vmid> exec`** runs commands in the guest from the host.

Two halves, both required: `--agent enabled=1` on the VM (creates the channel)
and the package installed inside the guest (answers on it). Enabling only the
first is a common half-configuration — the UI keeps showing no IP.

```bash
qm agent 100 ping
qm agent 100 network-get-interfaces
```

</details>

---

## Reaching the guest from your LAN

If the host bridges to your LAN, guests get addresses from your router and
there's nothing to do. **If guests are behind NAT** — which they are when the
host uplinks over Wi-Fi — they can reach out but nothing can reach in.

```bash
./02-expose-port.sh 8080 10.10.10.50 80
```

That publishes the host's `:8080` to the guest's `:80`, and persists it.

Give the guest a fixed address first, so the rule doesn't point at a lease that
moved — on the host:

```bash
cat >> /etc/dnsmasq.d/vmbr0.conf <<'EOF'
dhcp-host=BC:24:11:XX:XX:XX,10.10.10.50,debian-vm
EOF
systemctl restart dnsmasq
```

The MAC is in `qm config 100 | grep net0`.

<details>
<summary><b>📚 DNAT, and why inbound needs a rule when outbound doesn't</b></summary>

Outbound works through MASQUERADE plus connection tracking: the guest starts a
connection, the host rewrites the source address and remembers the mapping, and
replies are matched against that table and rewritten back.

Inbound has no such prior state. A packet arriving at the host addressed to the
host has no conntrack entry and no way to know which guest it belongs to. So you
state it explicitly:

```bash
iptables -t nat -A PREROUTING -i wlp3s0 -p tcp --dport 8080 -j DNAT --to 10.10.10.50:80
```

`PREROUTING` runs **before** the routing decision, which is the point — by the
time the kernel routes the packet it's already addressed to the guest, so it
goes out the bridge naturally. Replies are un-translated automatically by
conntrack; no second rule needed.

**Hairpin NAT** is the subtlety. If a guest (or the host itself) reaches the
service via the host's *LAN* address, the reply would otherwise go directly from
guest to client, bypassing the translation — and the client drops it, since it
expected a reply from the host's address. Adding a MASQUERADE on the way in
forces the reply back through the host. That's the second rule the script adds.

**Persistence.** iptables rules live in memory. `iptables-save` plus a oneshot
unit at boot is the simplest durable approach; `iptables-persistent` is the
packaged equivalent.

**Ports to avoid on the host:** `8006` (Proxmox UI), `22` (host SSH — forward
the guest's SSH on 2222 instead), `3128`, `5900-5999` (console).

</details>

<details>
<summary><b>📚 When your app serves by hostname</b></summary>

If the guest runs nginx with `server_name dev.example.com`, forwarding a port
isn't enough — the client must send that hostname in the `Host` header, which
means the *name* has to resolve to the host's LAN address.

On each machine that needs access:

```
# /etc/hosts  (C:\Windows\System32\drivers\etc\hosts on Windows)
192.168.0.100  dev.example.com  partners.dev.example.com
```

Then forward 80 and 443:

```bash
./02-expose-port.sh 80  10.10.10.50 80
./02-expose-port.sh 443 10.10.10.50 443
```

The request goes to the host on :80, DNAT sends it to the guest, and nginx sees
the `Host:` header it expects. Guests behind NAT can serve virtual hosts to your
whole LAN this way.

For more than a couple of machines, a local DNS entry (on the router, or a
Pi-hole/AdGuard) beats editing `/etc/hosts` everywhere.

</details>

---

## Verify

```bash
./99-verify-vm.sh
```

Audits the config against the settings above, reports the guest's IP via the
agent, lists DHCP leases and published ports, and shows host memory headroom.

---

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `KVM virtualisation configured, but not available` | VT-x/AMD-V off in BIOS | Enable it; `grep -c vmx /proc/cpuinfo` |
| Boots to a bare `grub>` prompt | **Corrupt ISO** | `sha256sum -c SHA256SUMS`; re-download |
| ISO is ~2× the expected size | `wget -c` resumed across mirrors | Delete, download from one source |
| Boots the installer again after install | Boot order still prefers the CD | `qm set <id> --boot order='scsi0;ide2'` |
| UEFI shell instead of the installer | No bootable media found | Check `ide2`, set boot order to `ide2;scsi0` |
| No IP shown in the Summary panel | Guest agent not installed inside | `apt install qemu-guest-agent` |
| Installer finds no DHCP server | dnsmasq not serving the bridge | `journalctl -u dnsmasq`; check `bind-dynamic` |
| Guest disk never shrinks | discard missing or no TRIM | `discard=on` + `fstrim -av` in guest |
| Guest unreachable from the LAN | It's behind NAT | `./02-expose-port.sh` |
| Port forward works, app 404s | App serves by hostname | Add `/etc/hosts` entries on clients |
| Wizard settings didn't apply | Navigated by tab instead of Next | Re-check the Confirm screen |
| VM won't start, "not enough memory" | RAM overcommitted | `free -h`; lower `memory` |

### Useful commands

```bash
qm list                                   # all VMs and their state
qm config 100                             # full config
qm status 100                             # running/stopped
qm start 100 / qm stop 100 / qm shutdown 100
qm set 100 --memory 8192                  # change a setting
qm agent 100 network-get-interfaces       # guest IPs (needs the agent)
qm monitor 100                            # QEMU monitor
qm terminal 100                           # serial console, if configured
lvs -o lv_name,data_percent               # thin pool fill
iptables -t nat -S PREROUTING             # what is published
cat /var/lib/misc/dnsmasq.leases          # who got which address
```

> `qm shutdown` asks the OS to shut down cleanly (needs the agent, or ACPI
> handling). `qm stop` is the equivalent of pulling the power cord — it will
> corrupt filesystems if used casually.

---

## Glossary

| Term | Meaning |
|---|---|
| **ballooning** | Host reclaiming guest RAM via a driver inside the guest |
| **conntrack** | Connection tracking; remembers NAT mappings so replies find their way home |
| **DNAT** | Destination NAT; rewriting where an inbound packet is going |
| **guest agent** | Daemon in the guest that lets the host query and control the OS |
| **hairpin NAT** | Translating traffic that leaves and re-enters by the same interface |
| **KVM** | Kernel-based Virtual Machine; hardware-accelerated virtualization |
| **OVMF** | UEFI firmware implementation for VMs |
| **q35** | Modern emulated chipset with PCIe; the alternative to legacy i440fx |
| **TCG** | QEMU's software CPU emulation — the slow fallback when KVM is unavailable |
| **TRIM / discard** | A guest telling the host which blocks it freed |
| **VirtIO** | Paravirtualized device interface; shared memory instead of emulated hardware |
| **VT-x / AMD-V** | CPU extensions that make hardware virtualization possible |

## Final note

Homelab guidance. The genuinely destructive step here is `qm stop` on a running
guest and deleting a VM — both do exactly what they say. Everything else is
recoverable.
