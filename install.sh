cat << 'EOF' | sudo tee /usr/local/bin/black-backup > /dev/null
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

BACKUP_DIR="/var/backups/black-backup"
LOG_FILE="/var/log/black-backup.log"
HTTP_PORT=8765
UFW_OPENED=0
IPTABLES_OPENED=0

# ─────────────────────────────────────────────────────────────
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║           BLACK-BACKUP  v2.0             ║"
    echo "  ║     Server Snapshot & Restore Tool       ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_ok()   { echo -e "  ${GREEN}[✔]${NC} $1"; echo "[OK]   $(date '+%H:%M:%S') $1" >> "$LOG_FILE"; }
log_warn() { echo -e "  ${YELLOW}[!]${NC} $1"; echo "[WARN] $(date '+%H:%M:%S') $1" >> "$LOG_FILE"; }
log_err()  { echo -e "  ${RED}[✗]${NC} $1"; echo "[ERR]  $(date '+%H:%M:%S') $1" >> "$LOG_FILE"; }
log_step() { echo -e "  ${BLUE}[→]${NC} $1"; echo "[STEP] $(date '+%H:%M:%S') $1" >> "$LOG_FILE"; }
log_info() { echo -e "  ${MAGENTA}[i]${NC} $1"; echo "[INFO] $(date '+%H:%M:%S') $1" >> "$LOG_FILE"; }
divider()  { echo -e "  ${CYAN}──────────────────────────────────────────${NC}"; }

log_section() {
    echo "" >> "$LOG_FILE"
    echo "═══════════════════════════════════════" >> "$LOG_FILE"
    echo "  $1  —  $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "═══════════════════════════════════════" >> "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Please run with sudo or as root."
        exit 1
    fi
}

ensure_python() {
    if ! command -v python3 &>/dev/null; then
        log_warn "Python3 not found. Installing..."
        apt-get update -qq && apt-get install -y python3 -qq
        log_ok "Python3 installed."
    fi
}

get_server_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

open_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow ${HTTP_PORT}/tcp -q 2>/dev/null
        log_ok "Firewall (ufw): port ${HTTP_PORT} opened."
        UFW_OPENED=1
    fi
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport ${HTTP_PORT} -j ACCEPT 2>/dev/null || true
        IPTABLES_OPENED=1
    fi
}

close_firewall() {
    if [[ "$UFW_OPENED" == "1" ]]; then
        ufw delete allow ${HTTP_PORT}/tcp -q 2>/dev/null || true
        log_ok "Firewall (ufw): port ${HTTP_PORT} closed."
        UFW_OPENED=0
    fi
    if [[ "$IPTABLES_OPENED" == "1" ]]; then
        iptables -D INPUT -p tcp --dport ${HTTP_PORT} -j ACCEPT 2>/dev/null || true
        IPTABLES_OPENED=0
    fi
}

ask_backup_name() {
    local DEFAULT="backup-$(date +%Y%m%d_%H%M%S)"
    echo ""
    read -rp "  Backup name [${DEFAULT}]: " INPUT
    BACKUP_NAME=$(echo "${INPUT:-$DEFAULT}" | tr ' ' '-' | tr -cd '[:alnum:]-_.')
    BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
    BACKUP_META="${BACKUP_DIR}/${BACKUP_NAME}.meta"
}

save_meta() {
    # save current network interface names into meta for later restore fix
    local IFACES
    IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ',')
    cat > "$BACKUP_META" <<META
name=$BACKUP_NAME
date=$(date '+%Y-%m-%d %H:%M:%S')
size=$(du -sh "$BACKUP_FILE" 2>/dev/null | cut -f1)
hostname=$(hostname)
file=$BACKUP_FILE
interfaces=$IFACES
kernel=$(uname -r)
arch=$(uname -m)
os=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')
META
}

start_http_server() {
    local FILE_PATH="$1"
    local FILE_DIR FILE_NAME SERVER_IP
    FILE_DIR=$(dirname "$FILE_PATH")
    FILE_NAME=$(basename "$FILE_PATH")
    SERVER_IP=$(get_server_ip)

    ensure_python
    fuser -k ${HTTP_PORT}/tcp &>/dev/null || true
    sleep 1

    UFW_OPENED=0
    IPTABLES_OPENED=0
    open_firewall

    trap 'echo ""; close_firewall; log_ok "HTTP server stopped."; trap - INT TERM; return' INT TERM

    echo ""
    echo -e "  ${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}${BOLD}║         DOWNLOAD LINK  (active)          ║${NC}"
    echo -e "  ${GREEN}${BOLD}╠══════════════════════════════════════════╣${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  ${CYAN}http://${SERVER_IP}:${HTTP_PORT}/${FILE_NAME}${NC}"
    echo -e "  ${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""
    log_info "File saved at  : $FILE_PATH"
    log_warn "Press Ctrl+C to stop the server and close the firewall port."
    echo ""

    cd "$FILE_DIR"
    python3 -m http.server ${HTTP_PORT} --bind 0.0.0.0

    close_firewall
    trap - INT TERM
    echo ""
    log_ok "HTTP server stopped."
}

# ─────────────────────────────────────────────────────────────
do_backup() {
    banner
    echo -e "  ${BOLD}═══ BACKUP MODE ═══${NC}"
    divider
    mkdir -p "$BACKUP_DIR"
    log_section "BACKUP START"
    ask_backup_name

    if [[ -f "$BACKUP_FILE" ]]; then
        log_warn "Backup with this name already exists."
        read -rp "  Overwrite? (y/n): " OW
        [[ ! "$OW" =~ ^[Yy]$ ]] && { log_warn "Cancelled."; return; }
    fi

    echo ""
    log_step "Starting full system backup. Please wait..."
    echo ""

    if ! command -v pv &>/dev/null; then
        apt-get install -y pv -qq 2>/dev/null || true
    fi

    EXCL=(
        --exclude=/proc --exclude=/sys --exclude=/dev
        --exclude=/run --exclude=/tmp --exclude=/mnt
        --exclude=/media --exclude=/lost+found
        --exclude="$BACKUP_DIR" --exclude=/var/cache/apt
    )

    if command -v pv &>/dev/null; then
        USED=$(df / --output=used -k | tail -1)
        tar -czp "${EXCL[@]}" / 2>/dev/null | pv -s "${USED}k" > "$BACKUP_FILE"
    else
        tar -czpf "$BACKUP_FILE" "${EXCL[@]}" /
    fi

    save_meta
    SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    echo ""
    divider
    log_ok "Backup completed!"
    log_info "Name   : $BACKUP_NAME"
    log_info "File   : $BACKUP_FILE"
    log_info "Size   : $SIZE"
    log_info "Log    : $LOG_FILE"
    divider
    echo ""

    read -rp "  Generate a temporary download link? (y/n): " WANT_LINK
    [[ "$WANT_LINK" =~ ^[Yy]$ ]] && start_http_server "$BACKUP_FILE"
}

# ─────────────────────────────────────────────────────────────
list_backups() {
    while true; do
        banner
        echo -e "  ${BOLD}═══ BACKUP LIST ═══${NC}"
        divider
        echo ""

        local METAS=()
        for META in "$BACKUP_DIR"/*.meta; do
            [[ -f "$META" ]] && METAS+=("$META")
        done

        if [[ ${#METAS[@]} -eq 0 ]]; then
            log_warn "No backups found in $BACKUP_DIR"
            echo ""
            divider
            read -rp "  Press Enter to go back..." _
            return
        fi

        local I=1
        for META in "${METAS[@]}"; do
            local NAME DATE SIZE FILE
            NAME=$(grep '^name=' "$META" | cut -d= -f2-)
            DATE=$(grep '^date=' "$META" | cut -d= -f2-)
            SIZE=$(grep '^size=' "$META" | cut -d= -f2-)
            FILE=$(grep '^file=' "$META" | cut -d= -f2-)
            printf "  ${CYAN}%-4s${NC} %-30s ${YELLOW}%-22s${NC} ${GREEN}%s${NC}\n" \
                "$I)" "$NAME" "$DATE" "$SIZE"
            printf "       ${MAGENTA}Path: %s${NC}\n" "$FILE"
            echo ""
            I=$((I+1))
        done

        divider
        echo ""
        echo "  Enter a number to generate a download link,"
        echo -e "  or ${CYAN}Enter${NC} / ${CYAN}0${NC} to go back."
        echo ""
        read -rp "  Choice: " NUM

        [[ -z "$NUM" || "$NUM" == "0" ]] && return

        if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
            log_err "Invalid selection."; sleep 1; continue
        fi

        local SELECTED_FILE
        SELECTED_FILE=$(grep '^file=' "${METAS[$((NUM-1))]}" | cut -d= -f2-)

        if [[ ! -f "$SELECTED_FILE" ]]; then
            log_err "Backup file not found: $SELECTED_FILE"; sleep 2; continue
        fi

        start_http_server "$SELECTED_FILE"
    done
}

# ─────────────────────────────────────────────────────────────
delete_backup() {
    banner
    echo -e "  ${BOLD}═══ DELETE BACKUP ═══${NC}"
    divider
    echo ""

    local METAS=()
    for META in "$BACKUP_DIR"/*.meta; do
        [[ -f "$META" ]] && METAS+=("$META")
    done

    if [[ ${#METAS[@]} -eq 0 ]]; then
        log_warn "No backups found."; return
    fi

    local I=1
    for META in "${METAS[@]}"; do
        NAME=$(grep '^name=' "$META" | cut -d= -f2-)
        DATE=$(grep '^date=' "$META" | cut -d= -f2-)
        SIZE=$(grep '^size=' "$META" | cut -d= -f2-)
        printf "  ${CYAN}%-4s${NC} %-30s %-22s %s\n" "$I)" "$NAME" "$DATE" "$SIZE"
        I=$((I+1))
    done

    echo ""
    read -rp "  Backup number to delete (0 to cancel): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && { log_warn "Cancelled."; return; }

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
        log_err "Invalid selection."; return
    fi

    local SELECTED="${METAS[$((NUM-1))]}"
    local DEL_FILE DEL_NAME
    DEL_FILE=$(grep '^file=' "$SELECTED" | cut -d= -f2-)
    DEL_NAME=$(grep '^name=' "$SELECTED" | cut -d= -f2-)

    echo ""
    log_warn "About to delete: $DEL_NAME"
    read -rp "  Confirm? (yes/no): " CONF
    if [[ "$CONF" == "yes" ]]; then
        [[ -f "$DEL_FILE" ]] && rm -f "$DEL_FILE"
        rm -f "$SELECTED"
        log_ok "Deleted: $DEL_NAME"
    else
        log_warn "Cancelled."
    fi
}

# ─────────────────────────────────────────────────────────────
# CHECK: enough disk space before restore
check_disk_space() {
    local BACKUP_FILE="$1"
    log_step "Checking available disk space..."

    local BACKUP_SIZE_KB
    BACKUP_SIZE_KB=$(du -k "$BACKUP_FILE" | cut -f1)

    # estimate uncompressed size (~3x compressed)
    local ESTIMATED_KB=$(( BACKUP_SIZE_KB * 3 ))
    local AVAILABLE_KB
    AVAILABLE_KB=$(df / --output=avail -k | tail -1)

    local ESTIMATED_HR
    ESTIMATED_HR=$(( ESTIMATED_KB / 1024 / 1024 ))
    local AVAILABLE_HR
    AVAILABLE_HR=$(( AVAILABLE_KB / 1024 / 1024 ))

    log_info "Backup compressed size : ~$(( BACKUP_SIZE_KB / 1024 ))MB"
    log_info "Estimated unpacked size: ~${ESTIMATED_HR}GB"
    log_info "Available disk space   : ~${AVAILABLE_HR}GB"

    if [[ $AVAILABLE_KB -lt $ESTIMATED_KB ]]; then
        log_err "Not enough disk space!"
        log_err "Need ~${ESTIMATED_HR}GB but only ${AVAILABLE_HR}GB available."
        log_err "Restore aborted. Use a server with a larger disk."
        return 1
    fi

    log_ok "Disk space check passed."
    return 0
}

# ─────────────────────────────────────────────────────────────
# FIX: UUID — matches by fstype AND mount point
fix_uuid() {
    log_step "Fixing UUIDs in /etc/fstab..."
    local FSTAB="/etc/fstab"
    local BAK="/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$FSTAB" "$BAK"
    log_info "fstab backup saved: $BAK"

    local CHANGED=0
    local TMP
    TMP=$(mktemp)
    cp "$FSTAB" "$TMP"

    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        local ENTRY MOUNTPOINT FSTYPE
        ENTRY=$(echo "$line" | awk '{print $1}')
        MOUNTPOINT=$(echo "$line" | awk '{print $2}')
        FSTYPE=$(echo "$line" | awk '{print $3}')

        if [[ "$ENTRY" == UUID=* ]]; then
            local OLD="${ENTRY#UUID=}"
            if ! blkid -t UUID="$OLD" > /dev/null 2>&1; then
                log_warn "UUID not found: $OLD (mount: $MOUNTPOINT, type: $FSTYPE)"
                local NEW_UUID=""

                # Strategy 1: match by mount point (most accurate)
                if [[ "$MOUNTPOINT" == "/" ]]; then
                    # find the currently mounted root device's UUID
                    local ROOT_DEV
                    ROOT_DEV=$(findmnt -n -o SOURCE /)
                    NEW_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null)
                fi

                # Strategy 2: match by fstype if strategy 1 failed
                if [[ -z "$NEW_UUID" ]]; then
                    while IFS= read -r bl; do
                        local B_UUID B_TYPE
                        B_UUID=$(echo "$bl" | grep -oP 'UUID="\K[^"]+')
                        B_TYPE=$(echo "$bl" | grep -oP 'TYPE="\K[^"]+')
                        if [[ "$B_TYPE" == "$FSTYPE" && -n "$B_UUID" ]]; then
                            if ! grep -q "UUID=$B_UUID" "$TMP"; then
                                NEW_UUID="$B_UUID"; break
                            fi
                        fi
                    done < <(blkid)
                fi

                if [[ -n "$NEW_UUID" ]]; then
                    sed -i "s|UUID=$OLD|UUID=$NEW_UUID|g" "$TMP"
                    log_ok "UUID fixed: $OLD → $NEW_UUID (mount: $MOUNTPOINT)"
                    CHANGED=$((CHANGED+1))
                else
                    log_warn "Could not find replacement UUID for: $MOUNTPOINT ($FSTYPE)"
                fi
            else
                log_ok "UUID OK: $OLD ($MOUNTPOINT)"
            fi
        fi
    done < "$FSTAB"

    cp "$TMP" "$FSTAB"
    rm -f "$TMP"
    [[ $CHANGED -gt 0 ]] && log_ok "$CHANGED UUID(s) updated in /etc/fstab" \
                         || log_ok "All UUIDs are correct."
}

# ─────────────────────────────────────────────────────────────
# FIX: network interface name mismatch
fix_network() {
    local META_FILE="$1"
    log_step "Checking network interface compatibility..."

    # get interface names from new server
    local NEW_IFACES
    NEW_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)

    # get interface names from backup meta
    local OLD_IFACES=""
    if [[ -n "$META_FILE" && -f "$META_FILE" ]]; then
        OLD_IFACES=$(grep '^interfaces=' "$META_FILE" | cut -d= -f2- | tr ',' '\n' | grep -v '^$' | head -1)
    fi

    log_info "Old interface (backup server): ${OLD_IFACES:-unknown}"
    log_info "New interface (this server)  : $NEW_IFACES"

    if [[ -z "$OLD_IFACES" || "$OLD_IFACES" == "$NEW_IFACES" ]]; then
        log_ok "Network interfaces match. No fix needed."
        return
    fi

    log_warn "Interface name changed: $OLD_IFACES → $NEW_IFACES"
    log_step "Updating network config files..."

    local FIXED=0

    # fix netplan configs
    for FILE in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [[ -f "$FILE" ]] || continue
        if grep -q "$OLD_IFACES" "$FILE" 2>/dev/null; then
            cp "$FILE" "${FILE}.bak"
            sed -i "s|${OLD_IFACES}|${NEW_IFACES}|g" "$FILE"
            log_ok "Fixed netplan: $FILE"
            FIXED=$((FIXED+1))
        fi
    done

    # fix /etc/network/interfaces (older style)
    if [[ -f /etc/network/interfaces ]]; then
        if grep -q "$OLD_IFACES" /etc/network/interfaces 2>/dev/null; then
            cp /etc/network/interfaces /etc/network/interfaces.bak
            sed -i "s|${OLD_IFACES}|${NEW_IFACES}|g" /etc/network/interfaces
            log_ok "Fixed /etc/network/interfaces"
            FIXED=$((FIXED+1))
        fi
    fi

    # fix systemd network files
    for FILE in /etc/systemd/network/*.network; do
        [[ -f "$FILE" ]] || continue
        if grep -q "$OLD_IFACES" "$FILE" 2>/dev/null; then
            cp "$FILE" "${FILE}.bak"
            sed -i "s|${OLD_IFACES}|${NEW_IFACES}|g" "$FILE"
            log_ok "Fixed systemd-network: $FILE"
            FIXED=$((FIXED+1))
        fi
    done

    if [[ $FIXED -eq 0 ]]; then
        log_warn "No network config files contained '$OLD_IFACES' — check manually if network fails after reboot."
    else
        log_ok "$FIXED network config file(s) updated."
        # regenerate netplan if available
        if command -v netplan &>/dev/null; then
            netplan generate 2>/dev/null && log_ok "Netplan config regenerated." || true
        fi
    fi
}

# ─────────────────────────────────────────────────────────────
# FIX: kernel modules / VirtIO drivers
fix_kernel_modules() {
    log_step "Checking kernel module compatibility..."

    # ensure virtio modules are loaded (needed on KVM/QEMU/cloud VMs)
    local MODULES=(virtio_net virtio_blk virtio_scsi virtio_balloon)
    local MISSING=0

    for MOD in "${MODULES[@]}"; do
        if ! lsmod | grep -q "^${MOD}" 2>/dev/null; then
            modprobe "$MOD" 2>/dev/null && log_ok "Loaded module: $MOD" || true
        fi
    done

    # rebuild initramfs so new kernel picks up correct drivers
    if command -v update-initramfs &>/dev/null; then
        log_step "Rebuilding initramfs (this may take a moment)..."
        update-initramfs -u -k all >> "$LOG_FILE" 2>&1 && \
            log_ok "initramfs rebuilt successfully." || \
            log_warn "initramfs rebuild had warnings — check $LOG_FILE"
    fi
}

# ─────────────────────────────────────────────────────────────
# FIX: grub / bootloader
fix_bootloader() {
    log_step "Updating GRUB bootloader..."

    if command -v update-grub &>/dev/null; then
        update-grub >> "$LOG_FILE" 2>&1 && \
            log_ok "GRUB updated." || \
            log_warn "GRUB update had warnings."
    fi

    # detect root disk and reinstall grub
    local ROOT_DISK
    ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1)
    if [[ -n "$ROOT_DISK" ]]; then
        log_step "Reinstalling GRUB on /dev/${ROOT_DISK}..."
        grub-install "/dev/${ROOT_DISK}" >> "$LOG_FILE" 2>&1 && \
            log_ok "GRUB reinstalled on /dev/${ROOT_DISK}." || \
            log_warn "GRUB install had warnings — check $LOG_FILE"
    else
        log_warn "Could not detect root disk for GRUB install. Skipping."
    fi
}

# ─────────────────────────────────────────────────────────────
# SUMMARY REPORT after restore
print_restore_report() {
    echo ""
    echo -e "  ${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}${BOLD}║          RESTORE REPORT                  ║${NC}"
    echo -e "  ${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""
    log_info "Hostname        : $(hostname)"
    log_info "Kernel          : $(uname -r)"
    log_info "Network iface   : $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ')"
    log_info "Disk free       : $(df -h / | tail -1 | awk '{print $4}')"
    log_info "Full log        : $LOG_FILE"
    echo ""
    divider
    log_ok "Restore complete! Reboot now:"
    echo -e "  ${CYAN}reboot${NC}"
    divider
    echo ""
}

# ─────────────────────────────────────────────────────────────
do_restore() {
    banner
    echo -e "  ${BOLD}═══ RESTORE MODE ═══${NC}"
    divider
    echo ""
    log_warn "Target should be a fresh Ubuntu 24 installation."
    echo ""
    echo "  Restore source:"
    echo "  1) Pick from saved backups on this server"
    echo "  2) Enter local file path"
    echo "  3) Download from URL"
    echo ""
    read -rp "  Choice (1/2/3): " SRC

    local RESTORE_FILE=""
    local RESTORE_META=""

    case "$SRC" in
        1)
            local METAS=()
            for META in "$BACKUP_DIR"/*.meta; do
                [[ -f "$META" ]] && METAS+=("$META")
            done
            if [[ ${#METAS[@]} -eq 0 ]]; then
                log_err "No backups found."; return
            fi
            local I=1
            for META in "${METAS[@]}"; do
                NAME=$(grep '^name=' "$META" | cut -d= -f2-)
                DATE=$(grep '^date=' "$META" | cut -d= -f2-)
                SIZE=$(grep '^size=' "$META" | cut -d= -f2-)
                printf "  ${CYAN}%-4s${NC} %-30s %-22s %s\n" "$I)" "$NAME" "$DATE" "$SIZE"
                I=$((I+1))
            done
            echo ""
            read -rp "  Select number: " NUM
            if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
                log_err "Invalid."; return
            fi
            RESTORE_FILE=$(grep '^file=' "${METAS[$((NUM-1))]}" | cut -d= -f2-)
            RESTORE_META="${METAS[$((NUM-1))]}"
            ;;
        2)
            read -rp "  File path: " RESTORE_FILE
            [[ ! -f "$RESTORE_FILE" ]] && { log_err "File not found."; return; }
            # look for matching .meta file
            RESTORE_META="${RESTORE_FILE%.tar.gz}.meta"
            [[ ! -f "$RESTORE_META" ]] && RESTORE_META=""
            ;;
        3)
            read -rp "  Download URL: " URL
            mkdir -p /tmp/black-backup-dl
            RESTORE_FILE="/tmp/black-backup-dl/restore.tar.gz"
            log_step "Downloading..."
            if command -v wget &>/dev/null; then
                wget -O "$RESTORE_FILE" --progress=bar "$URL"
            else
                curl -L -o "$RESTORE_FILE" --progress-bar "$URL"
            fi
            [[ ! -f "$RESTORE_FILE" ]] && { log_err "Download failed."; return; }
            log_ok "Download complete."
            RESTORE_META=""
            ;;
        *)
            log_err "Invalid choice."; return ;;
    esac

    echo ""
    log_section "RESTORE START"

    # ── PRE-RESTORE CHECKS ──
    log_step "Running pre-restore checks..."
    echo ""

    # 1. disk space
    check_disk_space "$RESTORE_FILE" || return

    echo ""
    log_info "Backup file: $RESTORE_FILE"
    log_warn "This will overwrite your current system!"
    read -rp "  Type YES to confirm: " CONF
    [[ "$CONF" != "YES" ]] && { log_warn "Cancelled."; return; }

    echo ""

    # ── EXTRACT ──
    log_step "Extracting backup to system..."
    tar -xzpf "$RESTORE_FILE" -C / \
        --exclude=./proc --exclude=./sys \
        --exclude=./dev  --exclude=./run \
        2>/dev/null
    log_ok "Extraction complete."
    echo ""

    # ── POST-RESTORE FIXES ──
    log_step "Running post-restore fixes..."
    echo ""

    # 2. UUID fix (accurate: mount point aware)
    fix_uuid
    echo ""

    # 3. network interface name fix
    fix_network "$RESTORE_META"
    echo ""

    # 4. kernel modules + initramfs rebuild
    fix_kernel_modules
    echo ""

    # 5. bootloader
    fix_bootloader
    echo ""

    # 6. reload systemd
    log_step "Reloading systemd..."
    systemctl daemon-reexec 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log_ok "systemd reloaded."

    # ── REPORT ──
    print_restore_report
}

# ─────────────────────────────────────────────────────────────
uninstall_tool() {
    banner
    echo -e "  ${BOLD}═══ UNINSTALL BLACK-BACKUP ═══${NC}"
    divider
    echo ""
    log_warn "This will remove:"
    echo "    - /usr/local/bin/black-backup"
    echo "    - All backups in $BACKUP_DIR"
    echo "    - Log file $LOG_FILE"
    echo ""
    read -rp "  Type YES to confirm: " CONF
    [[ "$CONF" != "YES" ]] && { log_warn "Cancelled."; return; }
    rm -f /usr/local/bin/black-backup
    rm -rf "$BACKUP_DIR"
    rm -f "$LOG_FILE"
    log_ok "black-backup completely removed."
    echo ""
    exit 0
}

# ─────────────────────────────────────────────────────────────
main_menu() {
    check_root
    mkdir -p "$BACKUP_DIR"
    touch "$LOG_FILE"

    while true; do
        banner
        echo -e "  ${BOLD}Main Menu${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC}  Take a Backup"
        echo -e "  ${CYAN}2)${NC}  Restore from Backup"
        echo -e "  ${CYAN}3)${NC}  View Backups & Download"
        echo -e "  ${CYAN}4)${NC}  Delete a Backup"
        echo -e "  ${CYAN}5)${NC}  Uninstall black-backup"
        echo -e "  ${CYAN}0)${NC}  Exit"
        echo ""
        divider
        read -rp "  Choice: " CH
        case "$CH" in
            1) do_backup ;;
            2) do_restore ;;
            3) list_backups ;;
            4) delete_backup; read -rp "  Press Enter to continue..." _ ;;
            5) uninstall_tool ;;
            0) echo ""; log_ok "Goodbye."; echo ""; exit 0 ;;
            *) log_warn "Invalid. Enter 0-5."; sleep 1 ;;
        esac
    done
}

main_menu
EOF
sudo chmod +x /usr/local/bin/black-backup
echo ""
echo -e "\033[0;32m[✔]\033[0m black-backup v2.0 installed! Run: \033[0;36mblack-backup\033[0m"
echo ""
