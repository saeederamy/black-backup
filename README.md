# Black-Backup

Black-Backup is a full-featured server snapshot and restore tool for Ubuntu 24 (AMD64). It lets you take a complete system backup — including all installed software, services, configs, and project files — and restore it on any fresh server with a single command. No rescue mode required.

---

## ✨ Features

- 📦 Full system backup with a custom name and timestamp
- 🔁 Restore from local file, path, or direct download URL
- 🌐 Temporary HTTP download link with automatic firewall management
- 🔒 Port opens on download start and closes automatically on Ctrl+C
- 📋 View all backups with name, date, size, and file path
- 🗑️ Delete individual backups from the menu
- 🔧 Auto UUID fix in `/etc/fstab` after restore
- 🧹 Full uninstall option from within the menu

---

## ⚡ One-Line Installation

Connect to your server and paste the full contents of `install.sh` into your terminal, then run:

```bash
sudo bash install.sh
```

Or copy-paste the entire `install.sh` content directly into your terminal — it works as a single heredoc block, exactly like Black-Proxy.

After installation, the `black-backup` command is available system-wide:

```bash
black-backup
```

---

## 🖥️ Menu

```
  ╔══════════════════════════════════════════╗
  ║           BLACK-BACKUP  v1.0             ║
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

## 📦 Backup

- You will be prompted to enter a name (or press Enter for a default timestamped name)
- Progress bar shown via `pv` (auto-installed if missing)
- Backup stored at `/var/backups/black-backup/<name>.tar.gz`
- Option to generate a temporary HTTP download link after backup completes

### Excluded from backup:
`/proc` `/sys` `/dev` `/run` `/tmp` `/mnt` `/media` `/lost+found` `/var/cache/apt`

---

## 🔁 Restore

Restore supports three sources:

1. **Pick from saved backups** — lists all backups on this server
2. **Local file path** — provide the full path to a `.tar.gz` file
3. **Download URL** — paste the HTTP link from another server running Black-Backup

After extraction:
- `/etc/fstab` UUIDs are automatically detected and corrected
- `systemd` is reloaded
- A reboot prompt is shown

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

---

## 🗂️ View Backups

Option `3` from the main menu lists all backups:

```
  1)  my-server-snapshot        2025-05-18 14:32:00    3.2G
       Path: /var/backups/black-backup/my-server-snapshot.tar.gz

  2)  backup-20250518_143200    2025-05-18 14:32:00    3.1G
       Path: /var/backups/black-backup/backup-20250518_143200.tar.gz
```

Enter a number to immediately generate a download link for that backup.

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
| `/var/backups/black-backup/*.tar.gz` | Compressed system snapshot |
| `/var/backups/black-backup/*.meta` | Metadata: name, date, size, hostname |

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
