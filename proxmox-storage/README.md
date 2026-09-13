# 💾 Proxmox Storage

Adding disks to a Proxmox VE node, choosing the right storage type, and getting
that space to your VMs and containers.

Like the Wi-Fi guide, this is written to be **learned from, not just executed**.
Commands come first in each section; the collapsed blocks underneath explain what
the tools do and why the choice is shaped that way.

Tested on Proxmox VE 9.2.2 (Debian 13 "trixie"), with a 512 GB NVMe boot disk and
a 4 TB SATA drive added afterward.

---

## ⚠️ Warnings

- **Formatting a disk destroys everything on it.** There is no undo, no recycle
  bin, and `wipefs` takes under a second. Check the serial number, not the
  `/dev/sdX` letter.
- **`/dev/sdX` letters are not stable.** They're assigned in detection order and
  can change between boots. Always address disks by `/dev/disk/by-id/`.
- **A full root filesystem breaks Proxmox.** Not gracefully. Keep `/` under 80%.
- **A full thin pool can corrupt guest filesystems.** Monitor it. ([Why](#-thin-provisioning-what-it-is-and-what-it-costs))

---

## Quick start

```bash
git clone https://github.com/marcosmamg/proxmox_homelab_resources.git
cd proxmox_homelab_resources/proxmox-storage/scripts

./disk-inspect.sh        # read-only: what disks exist, where did the space go?

# DESTRUCTIVE - wipes the named disk, formats ext4, registers as Directory storage
./add-directory-storage.sh /dev/disk/by-id/ata-YOUR_DISK_SERIAL media

./storage-health.sh      # read-only: root usage, thin pool usage, SMART
```

| Script | Safe? | What it does |
|---|---|---|
| `disk-inspect.sh` | read-only | Every disk, partition, LVM volume, filesystem, and Proxmox storage |
| `add-directory-storage.sh` | **destructive** | Wipe → GPT → ext4 → mount → `pvesm add` |
| `storage-health.sh` | read-only | Root and thin-pool fill, overcommitment, SMART |

`add-directory-storage.sh` refuses to run against a mounted disk or an LVM
physical volume, requires a `/dev/disk/by-id/` path, and makes you type the
storage name to confirm.

---

## The Proxmox storage model

Two questions decide everything: **what kind of storage is it**, and **what is it
allowed to hold**.

### Storage types

| Type | Layout | Snapshots | Holds files? | Good for |
|---|---|---|---|---|
| **Directory** | A filesystem path (ext4/xfs) | qcow2 only | yes | Backups, ISOs, templates, media |
| **LVM-Thin** | Block volumes from a pool | yes, instant | no | Guest disks — the default |
| **LVM** | Block volumes, thick | no | no | Rarely, when you want no overcommit |
| **ZFS** | Pool with checksums + compression | yes | yes | Redundancy, bit-rot protection |
| **NFS / CIFS** | Network share | qcow2 only | yes | Shared storage across nodes |

### Content types

Every storage declares what it may hold. This is the lever that keeps fast and
bulk disks doing the right jobs:

| Content | Means | Lives at |
|---|---|---|
| **Disk image** | VM virtual disks | `images/` |
| **Container** | LXC root filesystems | `images/` |
| **ISO image** | Installer ISOs | `template/iso/` |
| **Container template** | LXC templates | `template/cache/` |
| **VZDump backup** | Backups | `dump/` |
| **Snippets** | cloud-init, hook scripts | `snippets/` |

A sensible split on a node with one fast disk and one big one:

| Storage | Disk | Content |
|---|---|---|
| `local` | NVMe root | ISO image, Container template, Snippets |
| `local-lvm` | NVMe thin pool | Disk image, Container |
| `media` | SATA bulk | VZDump backup, ISO image, Container template |

<details>
<summary><b>📚 Why restrict content types at all?</b></summary>

Nothing stops you from enabling every content type everywhere. The reason not to
is that Proxmox's storage picker is a dropdown, and dropdowns get clicked without
thinking.

If your 4 TB spinner accepts "Disk image", then six months from now, creating a
VM at 11pm, you will pick it by accident and wonder for weeks why that guest
feels sluggish. Turning the content type off makes the mistake impossible rather
than merely unlikely.

The same reasoning applies in the other direction, and it's the more valuable
half: **taking "VZDump backup" off your root storage.** A backup job that grows
past expectations will otherwise fill `/`, and a Proxmox host with a full root
filesystem stops being able to log, write cluster state, or serve its own web UI.
Pointing backups at a storage that physically cannot threaten root removes a
whole class of 2am problem.

Content types are cheap, reversible policy. Use them.

</details>

---

## Reading your current layout

```bash
./disk-inspect.sh
```

A stock Proxmox install on a single NVMe looks like this:

```
nvme0n1  512.11 GB
├─ p1      1 MB   BIOS boot
├─ p2      1 GB   EFI  → /boot/efi
└─ p3    510 GB   LVM physical volume (volume group "pve")
   ├─ pve-swap    8 GB   swap
   ├─ pve-root   96 GB   ext4 → /          ← "local" storage lives here
   └─ pve-data  348 GB   thin pool         ← "local-lvm"
```

Three separate volumes. They do **not** share free space: filling root doesn't
touch the pool, and filling the pool doesn't touch root.

<details>
<summary><b>📚 LVM: physical volumes, volume groups, logical volumes</b></summary>

LVM inserts a layer between partitions and filesystems so that "how much space
does this filesystem get" stops being decided by partition boundaries.

```
  physical volume (PV)   /dev/nvme0n1p3 - a partition handed to LVM
          │
  volume group (VG)      "pve" - a pool of space from one or more PVs
          │
  logical volumes (LV)   pve-root, pve-swap, pve-data - carved from the VG
```

What this buys you:

- **Resize without repartitioning.** `lvextend` grows a volume; `resize2fs` grows
  the filesystem on it, online, while mounted.
- **Span disks.** Add a second PV to the VG and volumes can use both.
- **Snapshots.** Point-in-time copies, cheap on thin pools.

Inspect each layer:

```bash
pvs    # physical volumes: which partitions belong to LVM
vgs    # volume groups: total and free space
lvs    # logical volumes: the actual volumes, and pool usage
```

`lvs` is the one to remember — it shows `Data%` and `Meta%` for thin pools, the
two numbers that matter most on a Proxmox host.

</details>

<details>
<summary><b>📚 Thin provisioning: what it is, and what it costs</b></summary>

**Thick provisioning:** a 100 GB guest disk consumes 100 GB the moment you create
it. The guest installs 8 GB of OS; the other 92 GB is reserved and unusable by
anything else.

**Thin provisioning:** the same 100 GB disk consumes **zero**. The guest sees 100
GB. Blocks are allocated only as they're actually written. After that install,
the pool has used 8 GB.

So a 348 GB pool can host five guests with 100 GB disks each — 500 GB
"provisioned" against 348 GB real. That's **overcommitment**, and it's the point:
provision generously, consume actually.

**The failure mode.** If those guests really do fill their disks, the pool runs
out while the guests still believe they have room. Writes fail in a way guest
filesystems handle badly: ext4 remounts read-only, databases corrupt, VMs crash.
Recovery is materially worse than a full ordinary filesystem.

So monitor the **pool**, never the sum of provisioned sizes:

```bash
lvs -o lv_name,lv_size,data_percent,metadata_percent pve
```

Two percentages, because there are two ways to run out:

- **Data%** — the blocks themselves.
- **Meta%** — the map of which blocks belong to which volume. This lives in a
  separate small volume (`pve-data_tmeta`, ~3.5 GB). Metadata exhaustion stops
  the pool even with data space free, and it's the one people forget.

Past 80% on either, act: delete, move a guest, or extend the pool.

**Snapshots are why this design exists.** Because the pool tracks blocks by
reference, a snapshot costs nothing at creation — it just marks the current
blocks as shared. Only later *writes* allocate new blocks (copy-on-write). That's
why Proxmox snapshots on `local-lvm` are instant, and also why a long-lived
snapshot quietly grows as the guest diverges from it.

**Reclaiming space needs the guest's cooperation.** Deleting a 10 GB file inside
a VM does not shrink pool usage — the host has no idea those blocks are free. The
guest must issue TRIM/discard. Enable **Discard** on the disk (Hardware → Disk →
Discard ✅), use `virtio-scsi` as the controller, and run `fstrim -av` in the
guest (most distros ship a weekly `fstrim.timer`).

</details>

<details>
<summary><b>📚 Why the sizes never seem to add up</b></summary>

Three different things get called "512 GB":

| Reported | Value | Why |
|---|---|---|
| Manufacturer / `Disks` view | 512.11 **GB** | Decimal: 512,110,190,592 bytes |
| `lsblk`, `df` | 476.9 **GiB** | Binary: ÷ 1024³ |
| Usable after layout | ~452 GB | Minus EFI, swap, metadata, slack |

`GB` is 10⁹ bytes; `GiB` is 2³⁰ = 1,073,741,824 bytes. The gap is ~7% and grows
with size — a "4 TB" disk is 3.64 TiB.

Nothing is missing and nothing is lying. Proxmox's `Disks` view reports decimal
(matching the label on the drive), while `df` and `lsblk` report binary. Then
subtract the EFI partition, swap, thin-pool metadata, and LVM's own alignment
slack, and 512.11 GB of hardware presents as roughly 452 GB of usable volumes.

</details>

---

## Adding a disk

### Step 1: Identify it safely

```bash
ls -l /dev/disk/by-id/ | grep -v part
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL
```

Use the `by-id` path — it embeds the model and serial:

```
/dev/disk/by-id/ata-WDC_WD43PURZ-74BWPY0_WD-XXXXXXXXXXXX
```

<details>
<summary><b>📚 Why <code>/dev/sdX</code> will eventually betray you</b></summary>

`sda`, `sdb`, `sdc` are assigned in the order the kernel finds devices at boot.
That order depends on controller initialization timing, which is not guaranteed.
Add a disk, move a cable to a different SATA port, or have one drive spin up
slightly slower after a firmware update, and the letters shift.

If that happens between writing a script and running it, `wipefs -a /dev/sdb`
destroys a different disk than the one you checked.

`/dev/disk/by-id/` is a udev-maintained symlink tree keyed on properties of the
hardware itself:

| Form | Built from | Notes |
|---|---|---|
| `ata-MODEL_SERIAL` | model + serial | Clearest to read |
| `wwn-0x5000...` | World Wide Name | Globally unique |
| `nvme-MODEL_SERIAL` | NVMe identify data | |

Follow one to see what it currently points at:

```bash
readlink -f /dev/disk/by-id/ata-WDC_WD43PURZ-74BWPY0_WD-XXXXXXXXXXXX
/dev/sda
```

The same reasoning is why `/etc/fstab` should use `UUID=`: a filesystem UUID is
generated at `mkfs` time and travels with the filesystem, so it survives
recabling, controller changes, and disk reordering.

</details>

### Step 2: Check what's on it first

A disk that already has a filesystem **will not appear** in the UI's storage
creation dialogs. That's Proxmox protecting existing data, not a bug.

```bash
lsblk -f /dev/sda
mount -o ro /dev/sda1 /mnt/inspect    # read-only look, if it has a filesystem
```

For NTFS, `apt install ntfs-3g` first. Unmount with `umount /mnt/inspect`.

Also check the drive's health before committing to it:

```bash
apt install -y smartmontools
smartctl -a /dev/sda | grep -iE 'model|power_on_hours|reallocated|pending|health'
```

<details>
<summary><b>📚 Reading SMART before you trust a disk</b></summary>

`PASSED` on the overall health line is weak evidence — drives typically report
`PASSED` right up until they don't. The individual attributes say more:

| Attribute | Meaning |
|---|---|
| `Power_On_Hours` | Age in service. 40,000+ is a well-used drive (4.5 years continuous) |
| `Reallocated_Sector_Ct` | Sectors that failed and were remapped. **Should be 0.** Anything growing is a replace signal |
| `Current_Pending_Sector` | Sectors that failed to read and await remap. **Should be 0** |
| `Offline_Uncorrectable` | Unrecoverable sectors. **Should be 0** |
| `UDMA_CRC_Error_Count` | Cable/connection errors, not the drive itself. Non-zero → reseat the SATA cable |
| `Percentage_Used` (SSD/NVMe) | Write endurance consumed. 100% means rated life reached, not dead |

A real test, rather than reading counters:

```bash
smartctl -t short /dev/sda     # ~2 minutes
smartctl -t long /dev/sda      # hours - reads every sector
smartctl -l selftest /dev/sda  # results
```

Run a long test on any used drive before putting data on it. It's free and it
reads the whole surface.

</details>

### Step 3: Wipe, format, mount, register

**UI path** (handles the mount unit for you):

1. **Datacenter → node → Disks** → select the disk → **Wipe Disk**
2. **Disks → Directory** → **Create: Directory** → filesystem `ext4`, a name,
   Add Storage ✅
3. **Datacenter → Storage** → select it → **Edit** → set content types

**Script path:**

```bash
./add-directory-storage.sh /dev/disk/by-id/ata-YOUR_DISK_SERIAL media
```

**By hand:**

```bash
DISK=/dev/disk/by-id/ata-YOUR_DISK_SERIAL

wipefs -a "$DISK"
sgdisk -Z "$DISK"
sgdisk -n1:0:0 -t1:8300 -c1:media "$DISK"
partprobe "$DISK"

mkfs.ext4 -L media -m 0 -T largefile "${DISK}-part1"

mkdir -p /mnt/pve/media
UUID=$(blkid -s UUID -o value "${DISK}-part1")
echo "UUID=$UUID /mnt/pve/media ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a

pvesm add dir media --path /mnt/pve/media --content backup,iso,vztmpl
```

<details>
<summary><b>📚 The mkfs flags that matter, and the 200 GB you're leaving behind</b></summary>

**`-m 0` — reclaim the root reserve.** ext4 reserves 5% of the filesystem for
`root` by default. The reason is sound on a system disk: if a runaway process
fills the disk, root can still log in, write logs, and clean up. On a 4 TB data
disk it means **~200 GB** you paid for and cannot use.

The Proxmox UI does **not** pass `-m 0`. If you created the storage through the
UI, that space is still reserved. Reclaim it any time, online, no data risk:

```bash
tune2fs -m 0 /dev/sda1
df -h /mnt/pve/media      # Avail jumps to match Size
```

**`-T largefile` — fewer inodes.** Every file needs an inode, and the table is
allocated up front at `mkfs` time. The default (`-T small`/`default`) assumes
roughly one file per 16 KB. On a 4 TB disk that's ~244 million inodes consuming
several GB — pointless if you're storing ISOs, backups, and video, where files
average hundreds of MB.

| Profile | Bytes per inode | Suits |
|---|---|---|
| `news` | 4 KB | Enormous numbers of tiny files |
| `small` | 8 KB | Many small files |
| default | 16 KB | Mixed |
| `largefile` | 1 MB | Media, backups, ISOs |
| `largefile4` | 4 MB | Very large files only |

Getting this wrong is survivable but annoying: run out of inodes and the disk
reports "No space left on device" with free space showing in `df`. Check with
`df -i`. It cannot be changed after `mkfs` — one of the few genuinely permanent
choices here.

**`nofail` in fstab** — without it, a disk that fails or is unplugged drops the
host into an emergency shell at boot instead of continuing. On a host whose
management interface you need in order to fix things, that matters.

**Why GPT** (`sgdisk`) rather than MBR: MBR maxes out at 2 TiB per partition. A 4
TB disk requires GPT, which also stores a backup partition table at the end of
the disk.

</details>

<details>
<summary><b>📚 fstab vs. systemd mount units</b></summary>

The UI creates a systemd mount unit; the CLI recipe above uses `/etc/fstab`. Both
work, and systemd actually converts fstab entries into transient units at boot —
`/etc/fstab` is a generator input, not a separate mechanism.

| | fstab | systemd unit |
|---|---|---|
| Location | `/etc/fstab` | `/etc/systemd/system/mnt-pve-media.mount` |
| Naming | free | **must** match the mount path, escaped |
| Dependencies | limited | full `After=`, `Requires=`, `.automount` |
| Created by | you | Proxmox UI |

The unit filename is not cosmetic: `/mnt/pve/media` must be a unit named
`mnt-pve-media.mount`. systemd derives one from the other.

Inspect whichever you have:

```bash
systemctl cat mnt-pve-media.mount    # UI-created
grep media /etc/fstab                 # CLI-created
findmnt /mnt/pve/media                # what is actually mounted, either way
```

Don't configure the same mount in both places — you'll get conflicting units and
confusing boot failures. `findmnt` tells you the truth.

</details>

---

## Where files actually go

Proxmox owns specific subdirectories inside a Directory storage:

| Content | Path |
|---|---|
| ISOs | `/mnt/pve/media/template/iso/` |
| Container templates | `/mnt/pve/media/template/cache/` |
| Backups | `/mnt/pve/media/dump/` |
| Disk images | `/mnt/pve/media/images/<vmid>/` |
| Snippets | `/mnt/pve/media/snippets/` |
| **Your own files** | anywhere else — e.g. `library/` |

Drop an `.iso` into `template/iso/` and it appears in the UI immediately; there's
no import step or database to update. Proxmox scans these directories on demand.

Keep your own data in a directory Proxmox doesn't manage (`library/`, `data/`) so
it never collides with a future feature.

> **Where does `wget` put things?** In your current directory — `/root` by
> default, which lives on the 96 GB root filesystem. Use
> `wget -P /mnt/pve/media/library <url>` for anything large, and watch `df -h /`.

---

## Getting storage to guests

A guest cannot see `/mnt/pve/media` just because the host can. How you bridge
that depends on whether it's a container or a VM.

| Method | Works with | Speed | Complexity |
|---|---|---|---|
| **LXC bind mount** | Containers | Native | Trivial |
| **NFS from host** | VMs + containers | Good | Moderate |
| **virtiofs** | VMs (PVE 8.3+) | Very good | Moderate, newer |
| **Disk passthrough** | One VM | Native | Simple, exclusive |
| **Virtual disk on the storage** | Any | Slow on HDD | Trivial, but opaque |

### LXC bind mount (recommended for media servers)

```bash
mkdir -p /mnt/pve/media/library
pct set 100 -mp0 /mnt/pve/media/library,mp=/media
```

The container sees `/media`. No network, no copy, no virtual disk — the same
files, at disk speed.

<details>
<summary><b>📚 Bind mounts and the unprivileged-container UID shift</b></summary>

A container shares the host's kernel, so "mounting" a host directory into one is
just making the same directory visible in the container's mount namespace. There
is no filesystem layer in between, hence no overhead.

**The permissions trap.** Proxmox creates **unprivileged** containers by default,
which is the right security default: the container's UID range is shifted by
100000 on the host, so container-root (UID 0) is really UID 100000 on the host
and has no host privileges.

The consequence for bind mounts is that a directory owned by `root` on the host
appears as owned by `nobody` inside the container, and applications can't write
to it. Options:

**Give the directory to the container's root:**

```bash
chown -R 100000:100000 /mnt/pve/media/library
```

Simple, but now host-root can write while other host users can't, and a second
container with a different offset won't have access either.

**Or share by group,** which is nicer when both the host and several containers
need access. Pick a group ID, create it on both sides, and add `lxc.idmap` lines
to the container config so the GID maps through rather than shifting.

**Or use a privileged container** (`unprivileged: 0`), where UIDs map 1:1 and
none of this applies. It's the easy answer and the weaker security boundary —
reasonable on a trusted home network, not something to do reflexively.

Check the mapping any time:

```bash
pct config 100 | grep -E 'unprivileged|mp[0-9]'
ls -ln /mnt/pve/media/library      # numeric owners, as the host sees them
```

</details>

### NFS to a VM

When it has to be a VM, export from the host and mount over the guest network.
Heavier than a bind mount — a real network stack, a service to maintain, and
exports to keep scoped to your guest subnet.

### Disk passthrough

Give an entire physical disk to one VM (a NAS appliance, TrueNAS):

```bash
qm set 100 -scsi1 /dev/disk/by-id/ata-YOUR_DISK_SERIAL
```

That VM owns the disk. The host can no longer use it, and neither can any other
guest. Use `by-id` here especially — the device letter is baked into the VM
config, and a shift after reboot means the VM gets a *different disk*.

---

## Monitoring

```bash
./storage-health.sh
```

The two numbers that actually predict trouble:

```bash
df -h /                                        # keep under 80%
lvs -o lv_name,data_percent,metadata_percent   # keep both under 80%
```

<details>
<summary><b>📚 What actually goes wrong, and how it announces itself</b></summary>

**Root fills up.** Usually backups pointed at `local`, a runaway log, or
downloads left in `/root`. Symptoms are systemic and confusing rather than a
tidy "disk full": the web UI stops responding, `pvedaemon` fails, cluster
filesystem writes to `/etc/pve` fail, guests won't start. Find it with:

```bash
du -xh --max-depth=2 / | sort -rh | head -20
```

`-x` keeps `du` on one filesystem so it doesn't wander into `/mnt/pve/media` and
report 3 TB of media as the problem.

**Thin pool fills up.** Guests see write errors while `df` on the *host* looks
fine — the host filesystem isn't full, the pool underneath the guests' virtual
disks is. Guest ext4 goes read-only; anything mid-write can corrupt. `lvs` is the
only place this is visible, which is exactly why it's worth a scheduled check.

**Inodes run out.** `df -h` shows free space, writes fail with "No space left on
device", and `df -i` shows 100% inode use. Only fixable by deleting files or
recreating the filesystem.

**A disk starts failing.** Rising `Reallocated_Sector_Ct` or
`Current_Pending_Sector`, I/O errors in `dmesg`, and latency spikes. `dmesg -T |
grep -iE 'i/o error|ata[0-9]|medium error'` is the fast check.

Proxmox can email on these — **Datacenter → Notifications**. Worth configuring
before you need it, since the failure mode for most of these is "you find out
when something breaks."

</details>

---

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Disk missing from UI storage dialogs | It has partitions or a filesystem | Wipe it, or mount it as a Directory instead |
| Disk missing from `lsblk` entirely | Cable, power, BIOS port disabled, RAID mode | Check `dmesg \| grep -i ata`, BIOS → AHCI |
| `Device or resource busy` on wipe | Mounted, or claimed by LVM/mdadm | `umount`, `vgchange -an`, `wipefs` again |
| `Avail` much less than `Size` | ext4 5% root reserve | `tune2fs -m 0 /dev/sdX1` |
| "No space left" but `df` shows free | Out of inodes | `df -i`; recreate with `-T largefile` |
| Storage shows `inactive` | Mount missing | `findmnt <path>`, `mount -a`, check fstab/unit |
| Host drops to emergency shell at boot | fstab entry for a missing disk | Add `nofail` |
| Guest can't read bind-mounted files | Unprivileged UID shift | `chown -R 100000:100000 <dir>` |
| Thin pool at 100% | Overcommitted and filled | Delete snapshots, move guests, extend pool |
| Deleting files in a VM frees nothing | No TRIM reaching the host | Enable Discard, `fstrim -av` in guest |
| Wrong disk after reboot | Used `/dev/sdX` | Use `/dev/disk/by-id/` everywhere |

### Useful commands

```bash
lsblk -f                                  # devices, filesystems, mountpoints
ls -l /dev/disk/by-id/                    # stable names
blkid                                     # UUIDs
findmnt /mnt/pve/media                    # what is mounted and how
pvs; vgs; lvs                             # LVM, layer by layer
lvs -o +data_percent,metadata_percent     # thin pool fill
df -h; df -i                              # space, and inodes
du -xh --max-depth=2 / | sort -rh | head  # what is eating root
pvesm status                              # Proxmox's view
cat /etc/pve/storage.cfg                  # storage definitions
smartctl -a /dev/sda                      # drive health
dmesg -T | grep -iE 'i/o error|ata[0-9]'  # hardware errors
```

---

## Glossary

| Term | Meaning |
|---|---|
| **by-id** | udev symlinks naming disks by model and serial; stable across reboots |
| **content type** | What a storage is permitted to hold (disk images, ISOs, backups...) |
| **discard / TRIM** | A guest telling the host which blocks it freed, so thin pools can reclaim them |
| **GPT** | GUID Partition Table; required above 2 TiB, replaces MBR |
| **inode** | Per-file metadata structure; the table is fixed at `mkfs` time |
| **LV / VG / PV** | LVM's logical volume, volume group, physical volume |
| **overcommitment** | Provisioning more guest storage than physically exists |
| **thin pool** | Block space allocated to guests on demand rather than up front |
| **tmeta** | A thin pool's metadata volume; fills independently of data |
| **wearout** | SSD/NVMe rated write endurance consumed, as a percentage |

## Final note

Homelab guidance. The destructive steps are genuinely destructive — a wrong
device path costs you data, not an error message. Check the serial, run the
read-only inspection first, and keep backups of anything you can't recreate.
