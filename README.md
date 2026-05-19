# Black-Backup

Black-Backup is a full-featured server snapshot and restore tool for **Linux (Ubuntu 24)** and **Windows (Server / Desktop)**. Take a complete system backup — installed software, services, configs, project files — and restore it on any fresh server with a single command.

---

## 📋 Table of Contents

- [Linux](#-linux)
- [Windows](#-windows)
- [Backup Types (both platforms)](#-backup-types)
- [Incremental & Chain Restore](#-incremental--chain-restore)

---

# 🐧 Linux

## ⚡ One-Line Install (online)

Open a terminal on your server and run:

```bash
bash <(curl -s https://raw.githubusercontent.com/saeederamy/black-backup/main/install.sh)
```

## 📋 Offline Install (paste method)

No internet on the server? Copy the **entire content** of `install.sh`, paste it directly into your terminal, and press **Enter**. The heredoc runs as-is — no file needed.

Or upload the file and run:

```bash
sudo bash install.sh
```

After installation:

```bash
black-backup
```

---

## 🖥️ Linux Menu

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

## 🔧 Linux Requirements

- Ubuntu 24 LTS (AMD64)
- `bash` 5+, `tar`, `curl` (pre-installed)
- `python3` — auto-installed if missing
- `pv` — auto-installed if missing
- Root / sudo access

---

# 🪟 Windows

## ⚡ One-Line Install (online)

Open **PowerShell as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/saeederamy/black-backup/main/install.ps1 | iex
```

## 📋 Offline Install — Method 1: paste

No internet? Copy the **entire content** of `install.ps1`, paste it into an **Administrator PowerShell** window, and press **Enter**. Works exactly like the Linux paste method.

## 📋 Offline Install — Method 2: download & run

```powershell
# Download
$f = "$env:TEMP\bb-install.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/saeederamy/black-backup/main/install.ps1" -OutFile $f

# Run as Administrator
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$f`"" -Verb RunAs
```

Or if you already have the file:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

After installation, `black-backup` is available from **any Administrator prompt**:

```powershell
black-backup
```

---

## 🖥️ Windows Menu

```
  +==========================================+
  |      BLACK-BACKUP  v1.0  (Windows)       |
  |    Server Snapshot & Restore Tool        |
  +==========================================+

  Main Menu

  1)  Take a Backup
  2)  Restore from Backup
  3)  View Backups & Download
  4)  Delete a Backup
  5)  Uninstall black-backup
  0)  Exit
```

---

## 🔧 Windows Requirements

- Windows 10 / 11 or Windows Server 2019 / 2022
- PowerShell 5.1+ (pre-installed on all modern Windows)
- Administrator privileges
- **VSS service** running (`vssadmin list providers` to verify)
- **DISM** (pre-installed on all modern Windows)
- Internet access only needed for the one-liner install

---

## 🗂️ Windows Storage Paths

| Path | Description |
|------|-------------|
| `C:\BlackBackup\*.wim` | Full / Light backup image (DISM WIM format) |
| `C:\BlackBackup\*.zip` | Incremental backup (changed files, ZIP) |
| `C:\BlackBackup\*.meta` | Metadata: name, date, size, type, base, sequence |
| `C:\BlackBackup\black-backup.log` | Operation log |
| `C:\Program Files\BlackBackup\` | Installed tool |

---

# 📦 Backup Types

Both platforms offer the same three modes:

```
  1)  Full Backup
       Complete system snapshot — safest, largest size

  2)  Light Backup
       Skips logs, cache, docker/snap (Linux) or temp/logs/WD scans (Windows)
       Typical size reduction: 40–70%

  3)  Incremental Backup
       Only files changed since the last backup — minimum storage
       Example: 2 GB full → 2 weeks later → 0.5 GB incremental (not 2 GB again)
       Requires an existing full or light base backup
```

### What each backup excludes

**Linux — Full:** `/proc` `/sys` `/dev` `/run` `/tmp` `/mnt` `/media` `/lost+found`

**Linux — Light (additional):** `/var/log` `/var/cache` `/var/lib/docker` `/var/lib/containerd` `/snap` `/usr/share/doc` `/usr/share/man` `~/.cache`

**Windows — Light (additional):** `pagefile.sys` `hiberfil.sys` `Windows\Temp` `Windows\Logs` `SoftwareDistribution\Download` `Windows Defender\Scans` user `AppData\Local\Temp` browser caches

---

# 🔁 Incremental & Chain Restore

### How it works

Each incremental backup is linked to a **base** (full or light) backup and gets a sequence number:

```
  base  →  inc#1  →  inc#2  →  inc#3  →  inc#4  →  inc#5
  2 GB     120 MB    95 MB     210 MB    80 MB     310 MB
```

Total storage: `2 GB + 0.8 GB` instead of `2 GB × 6`

### Restore to any checkpoint

When restoring or downloading, Black-Backup asks which checkpoint you want:

```
  Backup chain for: my-server-20250518

  #    Type     Name                      Date                   Size
  1)   base     my-server-20250518        2025-05-18 14:00:00    1.8G
  2)   inc#1    my-server-inc1            2025-06-01 10:00:00    120M
  3)   inc#2    my-server-inc2            2025-06-15 09:00:00    95M
  4)   inc#3    my-server-inc3            2025-07-01 11:00:00    210M

  All layers from #1 up to your choice will be merged.

  Checkpoint number [4]:
```

Enter `3` → system merges layers **1 + 2 + 3** and applies/downloads that. Layer 4 is ignored.

### On Linux — direct restore

Layers are extracted in order directly to `/`. Post-restore fixes run automatically (UUID, network, initramfs, GRUB).

### On Windows — one-restart restore

1. Black-Backup injects a restore script into **WinRE** (`startnet.cmd`)
2. Arms `reagentc /boottore` so WinRE runs on next boot
3. You reboot once
4. WinRE applies the base WIM with DISM, then overlays each incremental layer
5. Fixes bootloader with `bcdboot`, reboots into the restored Windows

> No WinPE USB or recovery media needed.

---

## 🌐 Temporary Download Link

After taking a backup, Black-Backup can serve it over HTTP so you can download it on another server.

**Linux** — uses Python's built-in HTTP server  
**Windows** — uses .NET `HttpListener` (streamed, handles multi-GB files)

```
  +==========================================+
  |         DOWNLOAD LINK  (active)          |
  |  http://YOUR_SERVER_IP:8765/backup.wim   |
  +==========================================+
```

- Firewall port `8765` is opened automatically (ufw/iptables on Linux, Windows Firewall on Windows)
- Press **Ctrl+C** to stop — port closes automatically

---

## 🗑️ Delete a Backup

If you delete a **base backup** that has incrementals depending on it, Black-Backup warns you and offers to delete the base **and all its incrementals** together. Incrementals cannot be restored without their base.

---

## 📄 License

MIT
