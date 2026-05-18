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
HTTP_PORT=8765
UFW_OPENED=0
IPTABLES_OPENED=0

banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║           BLACK-BACKUP  v1.0             ║"
    echo "  ║     Server Snapshot & Restore Tool       ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_ok()   { echo -e "  ${GREEN}[✔]${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}[!]${NC} $1"; }
log_err()  { echo -e "  ${RED}[✗]${NC} $1"; }
log_step() { echo -e "  ${BLUE}[→]${NC} $1"; }
log_info() { echo -e "  ${MAGENTA}[i]${NC} $1"; }
divider()  { echo -e "  ${CYAN}──────────────────────────────────────────${NC}"; }

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
    cat > "$BACKUP_META" <<META
name=$BACKUP_NAME
date=$(date '+%Y-%m-%d %H:%M:%S')
size=$(du -sh "$BACKUP_FILE" 2>/dev/null | cut -f1)
hostname=$(hostname)
file=$BACKUP_FILE
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

do_backup() {
    banner
    echo -e "  ${BOLD}═══ BACKUP MODE ═══${NC}"
    divider
    mkdir -p "$BACKUP_DIR"
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
    log_info "Name : $BACKUP_NAME"
    log_info "File : $BACKUP_FILE"
    log_info "Size : $SIZE"
    divider
    echo ""

    read -rp "  Generate a temporary download link? (y/n): " WANT_LINK
    [[ "$WANT_LINK" =~ ^[Yy]$ ]] && start_http_server "$BACKUP_FILE"
}

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
            printf "  ${CYAN}%-4s${NC} %-28s ${YELLOW}%-22s${NC} ${GREEN}%s${NC}\n" \
                "$I)" "$NAME" "$DATE" "$SIZE"
            printf "       ${MAGENTA}Path: %s${NC}\n" "$FILE"
            echo ""
            I=$((I+1))
        done

        divider
        echo ""
        echo "  Enter a number to generate a download link for that backup,"
        echo -e "  or press ${CYAN}Enter${NC} / type ${CYAN}0${NC} to go back."
        echo ""
        read -rp "  Choice: " NUM

        [[ -z "$NUM" || "$NUM" == "0" ]] && return

        if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
            log_err "Invalid selection."
            sleep 1
            continue
        fi

        local SELECTED_FILE
        SELECTED_FILE=$(grep '^file=' "${METAS[$((NUM-1))]}" | cut -d= -f2-)

        if [[ ! -f "$SELECTED_FILE" ]]; then
            log_err "Backup file not found on disk: $SELECTED_FILE"
            sleep 2
            continue
        fi

        start_http_server "$SELECTED_FILE"
    done
}

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
        log_warn "No backups found."
        return
    fi

    local I=1
    for META in "${METAS[@]}"; do
        NAME=$(grep '^name=' "$META" | cut -d= -f2-)
        DATE=$(grep '^date=' "$META" | cut -d= -f2-)
        SIZE=$(grep '^size=' "$META" | cut -d= -f2-)
        printf "  ${CYAN}%-4s${NC} %-28s %-20s %s\n" "$I)" "$NAME" "$DATE" "$SIZE"
        I=$((I+1))
    done

    echo ""
    read -rp "  Backup number to delete (0 to cancel): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && { log_warn "Cancelled."; return; }

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
        log_err "Invalid selection."
        return
    fi

    SELECTED="${METAS[$((NUM-1))]}"
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

fix_uuid_auto() {
    log_step "Checking and fixing UUIDs in /etc/fstab..."
    local FSTAB="/etc/fstab"
    cp "$FSTAB" "/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"
    local CHANGED=0
    local TMP
    TMP=$(mktemp)
    cp "$FSTAB" "$TMP"

    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        local ENTRY
        ENTRY=$(echo "$line" | awk '{print $1}')
        if [[ "$ENTRY" == UUID=* ]]; then
            local OLD="${ENTRY#UUID=}"
            if ! blkid -t UUID="$OLD" > /dev/null 2>&1; then
                local FSTYPE NEW_UUID=""
                FSTYPE=$(echo "$line" | awk '{print $3}')
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
                if [[ -n "$NEW_UUID" ]]; then
                    sed -i "s|UUID=$OLD|UUID=$NEW_UUID|g" "$TMP"
                    log_ok "UUID fixed: $OLD → $NEW_UUID"
                    CHANGED=$((CHANGED+1))
                else
                    log_warn "No replacement found for UUID=$OLD (fstype=$FSTYPE)"
                fi
            fi
        fi
    done < "$FSTAB"

    cp "$TMP" "$FSTAB"
    rm -f "$TMP"
    [[ $CHANGED -gt 0 ]] && log_ok "$CHANGED UUID(s) updated." || log_ok "All UUIDs OK."
}

do_restore() {
    banner
    echo -e "  ${BOLD}═══ RESTORE MODE ═══${NC}"
    divider
    echo ""
    log_warn "Target server should be a fresh Ubuntu 24 install."
    echo ""
    echo "  Restore source:"
    echo "  1) Pick from saved backups on this server"
    echo "  2) Enter local file path"
    echo "  3) Download from URL"
    echo ""
    read -rp "  Choice (1/2/3): " SRC

    local RESTORE_FILE=""

    case "$SRC" in
        1)
            local METAS=()
            for META in "$BACKUP_DIR"/*.meta; do
                [[ -f "$META" ]] && METAS+=("$META")
            done
            if [[ ${#METAS[@]} -eq 0 ]]; then
                log_err "No backups found."
                return
            fi
            local I=1
            for META in "${METAS[@]}"; do
                NAME=$(grep '^name=' "$META" | cut -d= -f2-)
                DATE=$(grep '^date=' "$META" | cut -d= -f2-)
                SIZE=$(grep '^size=' "$META" | cut -d= -f2-)
                printf "  ${CYAN}%-4s${NC} %-28s %-20s %s\n" "$I)" "$NAME" "$DATE" "$SIZE"
                I=$((I+1))
            done
            echo ""
            read -rp "  Select number: " NUM
            if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
                log_err "Invalid."; return
            fi
            RESTORE_FILE=$(grep '^file=' "${METAS[$((NUM-1))]}" | cut -d= -f2-)
            ;;
        2)
            read -rp "  File path: " RESTORE_FILE
            [[ ! -f "$RESTORE_FILE" ]] && { log_err "File not found."; return; }
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
            ;;
        *)
            log_err "Invalid choice."; return ;;
    esac

    echo ""
    log_info "Backup file: $RESTORE_FILE"
    log_warn "This will overwrite your current system!"
    read -rp "  Type YES to confirm: " CONF
    [[ "$CONF" != "YES" ]] && { log_warn "Cancelled."; return; }

    echo ""
    log_step "Extracting backup..."
    tar -xzpf "$RESTORE_FILE" -C / \
        --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run 2>/dev/null
    log_ok "Extraction complete."

    echo ""
    fix_uuid_auto

    echo ""
    systemctl daemon-reexec 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    divider
    log_ok "Restore completed! Please reboot: ${CYAN}reboot${NC}"
    divider
    echo ""
}

uninstall_tool() {
    banner
    echo -e "  ${BOLD}═══ UNINSTALL BLACK-BACKUP ═══${NC}"
    divider
    echo ""
    log_warn "This will remove:"
    echo "    - /usr/local/bin/black-backup"
    echo "    - All backups in $BACKUP_DIR"
    echo ""
    read -rp "  Type YES to confirm: " CONF
    [[ "$CONF" != "YES" ]] && { log_warn "Cancelled."; return; }
    rm -f /usr/local/bin/black-backup
    rm -rf "$BACKUP_DIR"
    log_ok "black-backup completely removed."
    echo ""
    exit 0
}

main_menu() {
    check_root
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
echo -e "\033[0;32m[✔]\033[0m black-backup installed! Run it with: \033[0;36mblack-backup\033[0m"
echo ""
