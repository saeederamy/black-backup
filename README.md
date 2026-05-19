# Black-Backup

Black-Backup is a full-featured server snapshot and restore tool for Ubuntu 24 (AMD64). It lets you take a complete system backup — including all installed software, services, configs, and project files — and restore it on any fresh server with a single command. No rescue mode required.

---

## ✨ Features

- 📦 **Full backup** — complete system snapshot, safest option
- 🪶 **Light backup** — skips logs, cache, docker layers, snap packages (much smaller size)
- 🔁 **Incremental backup** — only stores files changed since last backup (minimum storage)
- 🔗 **Chain restore** — pick any checkpoint: system merges layers in order automatically
- 🌐 Temporary HTTP download link with automatic firewall management
- 🔒 Port opens on download start and closes automatically on Ctrl+C
- 📋 View all backups with type, date, size, and file path
- 🗑️ Delete individual backups (warns if base has dependent incrementals)
- 🔧 Auto UUID fix in `/etc/fstab` after restore
- 🌐 Auto network interface name fix after restore
- ⚙️ Kernel module + initramfs rebuild after restore
- 🥾 GRUB reinstall after restore
- 🧹 Full uninstall option from within the menu

---

## ⚡ One-Line Installation

```bash
bash <(curl -s https://raw.githubusercontent.com/saeederamy/black-backup/main/install.sh)
```

Or upload to server and run:

```bash
sudo bash install.sh
```

After installation, the `black-backup` command is available system-wide:

```bash
black-backup
```

---

## 🖥️ Menu

```
  ╔══════════════════════════════════════════╗
  ║           BLACK-BACKUP  v3.0             ║
  ║     Server Snapshot & Restore Tool       ║
  ╚══════════════════════════════════════════╝

  Main Menu

  1)  Take a Backup
  2)  Restore from Backup
  3)  View Backups & Download
  4)  Delete a Backup
  5)  Uninstall black-backup
  0)  Exit
```

---

## 📦 Backup — Three Modes

When you select **Take a Backup**, you choose the type:

```
  1)  Full Backup
       Complete system snapshot — safest, largest size

  2)  Light Backup
       Skips logs, cache, docker layers, snaps — smaller size

  3)  Incremental Backup
       Only files changed since last backup — minimum storage
       Requires an existing full or light base backup
```

### 1) Full Backup
- Complete snapshot of the entire system
- Largest file size but most complete
- Best for: first-time backup, disaster recovery

### 2) Light Backup
- Same as full but excludes heavy directories
- **Excluded:** `/var/log`, `/var/cache`, `/var/lib/docker`, `/var/lib/containerd`, `/var/lib/snapd`, `/snap`, `/usr/share/doc`, `/usr/share/man`, `/usr/share/locale`, user `~/.cache` folders
- Typical size reduction: 40–70% compared to full backup

### 3) Incremental Backup
- Only archives files **modified since the last backup** (full, light, or previous incremental)
- Example: 2GB full backup → 2 weeks later only 0.5GB of changes → incremental is 0.5GB
- Each incremental is linked to its base backup and numbered in sequence
- **Requires** a full or light base backup to exist first

### Excluded from all backups:
`/proc` `/sys` `/dev` `/run` `/tmp` `/mnt` `/media` `/lost+found`

---

## 🔁 Restore

Restore supports three sources:

1. **Pick from saved backups** — lists all backups on this server
2. **Local file path** — provide the full path to a `.tar.gz` file
3. **Download URL** — paste the HTTP link from another server running Black-Backup

### Incremental Chain Restore

When restoring a backup that has incrementals (or selecting an incremental directly), Black-Backup asks **which checkpoint to restore to**:

```
  Backup chain for: my-server-20250518

  #    Type     Name                           Date                   Size
  1)   base     my-server-20250518             2025-05-18 14:00:00    1.8G
  2)   inc#1    my-server-inc1                 2025-06-01 10:00:00    120M
  3)   inc#2    my-server-inc2                 2025-06-15 09:00:00    95M
  4)   inc#3    my-server-inc3                 2025-07-01 11:00:00    210M

  Select the checkpoint you want to restore TO.
  All layers from #1 up to your choice will be merged.

  Checkpoint number [4]:
```

If you enter `3`, the system applies layers 1 → 2 → 3 in order, giving you the exact state at that point in time. Layer 4 is ignored.

After extraction:
- `/etc/fstab` UUIDs are automatically detected and corrected
- Network interface names are fixed for the new server
- Kernel modules and initramfs are rebuilt
- GRUB bootloader is reinstalled
- `systemd` is reloaded

> No rescue mode needed. Works on a live fresh Ubuntu 24 installation.

---

## 🌐 Temporary Download Link

When you generate a download link, Black-Backup:

1. Installs Python3 if not present
2. Opens the firewall port (`8765`) automatically — both `ufw` and `iptables`
3. Starts an HTTP server in the foreground
4. Displays the full download URL

```
  ╔══════════════════════════════════════════╗
  ║         DOWNLOAD LINK  (active)          ║
  ╠══════════════════════════════════════════╣
  ║  http://YOUR_SERVER_IP:8765/backup.tar.gz
  ╚══════════════════════════════════════════╝
```

5. When you press **Ctrl+C**, the server stops and the firewall port is closed automatically

### Downloading an Incremental Chain

When you select an incremental backup (or a base with incrementals) from the **View Backups** menu, you are asked which checkpoint to download. Black-Backup then:

1. Merges all layers up to the selected checkpoint into a single combined `.tar.gz`
2. Starts the HTTP server serving the merged archive
3. Cleans up the temp file after the server stops

This lets you download a fully self-contained restore archive to any new server.

---

## 🗂️ View Backups

Option `3` from the main menu lists all backups with their type:

```
  1)  [FULL ] my-server-snapshot
       2025-05-18 14:32:00    1.8G
       Path: /var/backups/black-backup/my-server-snapshot.tar.gz

  2)  [LITE ] my-server-light
       2025-05-18 15:00:00    680M
       Path: /var/backups/black-backup/my-server-light.tar.gz

  3)  [INC#1] my-server-inc-june
       2025-06-01 10:00:00    95M
       Path: /var/backups/black-backup/my-server-inc-june.tar.gz
       Base: my-server-snapshot
```

Enter a number to download that backup (incremental backups will ask which checkpoint to merge).

---

## 🗑️ Delete a Backup

Select option `4` from the main menu.

> **Warning:** If you delete a base backup (full or light) that has incremental backups depending on it, Black-Backup will warn you and offer to delete the base **and all its incrementals** together. Incrementals cannot be restored without their base.

---

## 🗑️ Uninstall

Select option `5` from the main menu and type `YES` to confirm. This removes:

- `/usr/local/bin/black-backup`
- All backups in `/var/backups/black-backup/`

Or manually:

```bash
sudo rm /usr/local/bin/black-backup
sudo rm -rf /var/backups/black-backup
```

---

## 📁 Backup Storage

| Path | Description |
|------|-------------|
| `/var/backups/black-backup/*.tar.gz` | Compressed system snapshot (full, light, or incremental layer) |
| `/var/backups/black-backup/*.meta` | Metadata: name, date, size, hostname, type, base, sequence |

### Meta file format (v3)

```
name=my-server-inc1
date=2025-06-01 10:00:00
size=95M
hostname=myserver
file=/var/backups/black-backup/my-server-inc1.tar.gz
interfaces=eth0,
kernel=6.8.0-57-generic
arch=x86_64
os=Ubuntu 24.04.2 LTS
type=incremental
base=my-server-snapshot
sequence=1
```

`type` is one of: `full`, `light`, `incremental`

---

## 🔧 Requirements

- Ubuntu 24 LTS (AMD64)
- `bash` 5+
- `tar`, `curl` (pre-installed on Ubuntu)
- `python3` — auto-installed if missing
- `pv` — auto-installed if missing (progress bar)
- Root / sudo access

---

## 📄 License

MIT
