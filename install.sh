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

# Global return values for functions that can't return arrays
_CHAIN_RESULT=()
_MERGE_FILE=""

# ─────────────────────────────────────────────────────────────
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║           BLACK-BACKUP  v3.0             ║"
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

# save_meta <type> [base_name] [sequence]
save_meta() {
    local TYPE="${1:-full}"
    local BASE="${2:-}"
    local SEQ="${3:-}"
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
type=$TYPE
base=$BASE
sequence=$SEQ
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
# Return via stdout: sorted list of incremental .meta files for a base backup
get_incrementals_for_base() {
    local BASE_NAME="$1"
    for M in "$BACKUP_DIR"/*.meta; do
        [[ -f "$M" ]] || continue
        local T B SEQ
        T=$(grep '^type=' "$M" | cut -d= -f2-)
        B=$(grep '^base=' "$M" | cut -d= -f2-)
        SEQ=$(grep '^sequence=' "$M" | cut -d= -f2-)
        [[ "$T" == "incremental" && "$B" == "$BASE_NAME" ]] && echo "$SEQ $M"
    done | sort -n | awk '{print $2}'
}

# Find the base .meta file for a given meta file (returns via echo).
# For non-incremental, echoes the file itself.
find_base_meta() {
    local META_FILE="$1"
    local TYPE BASE
    TYPE=$(grep '^type=' "$META_FILE" | cut -d= -f2-)
    if [[ "$TYPE" != "incremental" ]]; then
        echo "$META_FILE"; return 0
    fi
    BASE=$(grep '^base=' "$META_FILE" | cut -d= -f2-)
    local BASE_META="${BACKUP_DIR}/${BASE}.meta"
    if [[ ! -f "$BASE_META" ]]; then
        log_err "Base backup not found: $BASE"; return 1
    fi
    echo "$BASE_META"
}

# Ask user which checkpoint in a chain to use.
# Sets global _CHAIN_RESULT to the ordered list of meta files up to chosen point.
ask_chain_checkpoint() {
    local BASE_META="$1"
    local BASE_NAME
    BASE_NAME=$(grep '^name=' "$BASE_META" | cut -d= -f2-)

    local ALL_METAS=("$BASE_META")
    while IFS= read -r INC; do
        ALL_METAS+=("$INC")
    done < <(get_incrementals_for_base "$BASE_NAME")

    if [[ ${#ALL_METAS[@]} -eq 1 ]]; then
        # Only the base — no choice needed
        _CHAIN_RESULT=("$BASE_META")
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Backup chain for: ${CYAN}${BASE_NAME}${NC}"
    divider
    printf "  ${CYAN}%-4s${NC} %-8s %-30s %-22s %s\n" "#" "Type" "Name" "Date" "Size"
    echo ""

    local I=1
    for M in "${ALL_METAS[@]}"; do
        local N D S T SEQ
        N=$(grep '^name=' "$M" | cut -d= -f2-)
        D=$(grep '^date=' "$M" | cut -d= -f2-)
        S=$(grep '^size=' "$M" | cut -d= -f2-)
        T=$(grep '^type=' "$M" | cut -d= -f2-)
        SEQ=$(grep '^sequence=' "$M" | cut -d= -f2-)
        [[ "$T" == "full" || "$T" == "light" || -z "$T" ]] && T="base"
        [[ "$T" == "incremental" ]] && T="inc#$SEQ"
        printf "  ${CYAN}%-4s${NC} %-8s %-30s %-22s %s\n" "$I)" "$T" "$N" "$D" "$S"
        I=$((I+1))
    done

    echo ""
    log_info "Select the checkpoint you want to restore/download TO."
    log_info "All layers from #1 up to your choice will be merged."
    echo ""
    read -rp "  Checkpoint number [${#ALL_METAS[@]}]: " SEL
    SEL="${SEL:-${#ALL_METAS[@]}}"

    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [[ $SEL -lt 1 || $SEL -gt ${#ALL_METAS[@]} ]]; then
        log_err "Invalid selection."; return 1
    fi

    _CHAIN_RESULT=("${ALL_METAS[@]:0:$SEL}")
    return 0
}

# Merge an array of meta files into a single combined archive.
# Sets global _MERGE_FILE to the path of the merged archive.
merge_chain_for_download() {
    local CHAIN=("$@")
    local MERGE_DIR="/tmp/black-backup-merge-$$"
    _MERGE_FILE="/tmp/black-backup-merged-$$.tar.gz"

    mkdir -p "$MERGE_DIR"
    log_step "Merging ${#CHAIN[@]} backup layer(s) into a single archive..."

    for META in "${CHAIN[@]}"; do
        local FILE TYPE SEQ
        FILE=$(grep '^file=' "$META" | cut -d= -f2-)
        TYPE=$(grep '^type=' "$META" | cut -d= -f2-)
        SEQ=$(grep '^sequence=' "$META" | cut -d= -f2-)
        [[ -z "$TYPE" ]] && TYPE="full"
        [[ "$TYPE" == "incremental" ]] && TYPE="inc#$SEQ"
        if [[ ! -f "$FILE" ]]; then
            log_err "Archive not found: $FILE"; rm -rf "$MERGE_DIR"; return 1
        fi
        log_step "Applying [$TYPE]: $(basename "$FILE")..."
        tar -xzpf "$FILE" -C "$MERGE_DIR" 2>/dev/null || true
    done

    log_step "Repacking merged archive (this may take a while)..."
    if command -v pv &>/dev/null; then
        local USED
        USED=$(du -sk "$MERGE_DIR" | cut -f1)
        tar -czp -C "$MERGE_DIR" . 2>/dev/null | pv -s "${USED}k" > "$_MERGE_FILE"
    else
        tar -czpf "$_MERGE_FILE" -C "$MERGE_DIR" . 2>/dev/null
    fi

    rm -rf "$MERGE_DIR"

    if [[ ! -f "$_MERGE_FILE" ]]; then
        log_err "Merge failed."; return 1
    fi

    local SZ
    SZ=$(du -sh "$_MERGE_FILE" | cut -f1)
    log_ok "Merged archive ready ($SZ): $_MERGE_FILE"
    return 0
}

# ─────────────────────────────────────────────────────────────
do_full_backup() {
    mkdir -p "$BACKUP_DIR"
    log_section "FULL BACKUP START"
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

    save_meta "full"
    SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    echo ""
    divider
    log_ok "Full backup completed!"
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
do_light_backup() {
    mkdir -p "$BACKUP_DIR"
    log_section "LIGHT BACKUP START"
    ask_backup_name

    if [[ -f "$BACKUP_FILE" ]]; then
        log_warn "Backup with this name already exists."
        read -rp "  Overwrite? (y/n): " OW
        [[ ! "$OW" =~ ^[Yy]$ ]] && { log_warn "Cancelled."; return; }
    fi

    echo ""
    log_step "Starting light backup (excludes logs, cache, docker, snap)..."
    echo ""

    if ! command -v pv &>/dev/null; then
        apt-get install -y pv -qq 2>/dev/null || true
    fi

    EXCL=(
        --exclude=/proc --exclude=/sys --exclude=/dev
        --exclude=/run --exclude=/tmp --exclude=/mnt
        --exclude=/media --exclude=/lost+found
        --exclude="$BACKUP_DIR"
        # heavy dirs excluded to keep size small
        --exclude=/var/cache
        --exclude=/var/log
        --exclude=/var/lib/docker
        --exclude=/var/lib/containerd
        --exclude=/var/lib/snapd
        --exclude=/snap
        --exclude=/usr/share/doc
        --exclude=/usr/share/man
        --exclude=/usr/share/locale
        --exclude=/usr/share/help
        --exclude=/home/*/.cache
        --exclude=/root/.cache
        --exclude=/home/*/.local/share/Trash
    )

    if command -v pv &>/dev/null; then
        USED=$(df / --output=used -k | tail -1)
        tar -czp "${EXCL[@]}" / 2>/dev/null | pv -s "${USED}k" > "$BACKUP_FILE"
    else
        tar -czpf "$BACKUP_FILE" "${EXCL[@]}" /
    fi

    save_meta "light"
    SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    echo ""
    divider
    log_ok "Light backup completed!"
    log_info "Name   : $BACKUP_NAME"
    log_info "File   : $BACKUP_FILE"
    log_info "Size   : $SIZE"
    log_info "Log    : $LOG_FILE"
    divider
    echo ""
    echo -e "  ${YELLOW}Note:${NC} Excluded: logs, apt/apt-get cache, docker layers,"
    echo -e "        snap packages, doc/man pages, user caches."
    echo ""

    read -rp "  Generate a temporary download link? (y/n): " WANT_LINK
    [[ "$WANT_LINK" =~ ^[Yy]$ ]] && start_http_server "$BACKUP_FILE"
}

# ─────────────────────────────────────────────────────────────
do_incremental_backup() {
    mkdir -p "$BACKUP_DIR"
    log_section "INCREMENTAL BACKUP START"

    # Find the most recent base (full or light) backup to attach this incremental to
    local BASE_META="" BASE_NAME="" NEWEST_TIME=0
    for M in "$BACKUP_DIR"/*.meta; do
        [[ -f "$M" ]] || continue
        local T
        T=$(grep '^type=' "$M" | cut -d= -f2-)
        if [[ "$T" == "full" || "$T" == "light" ]]; then
            local MT
            MT=$(stat -c %Y "$M" 2>/dev/null || echo 0)
            if [[ $MT -gt $NEWEST_TIME ]]; then
                NEWEST_TIME=$MT; BASE_META="$M"
            fi
        fi
    done

    if [[ -z "$BASE_META" ]]; then
        echo ""
        log_warn "No base backup (full or light) found!"
        log_warn "An incremental backup requires a full or light base first."
        echo ""
        read -rp "  Take a full backup now instead? (y/n): " DOFULL
        [[ "$DOFULL" =~ ^[Yy]$ ]] && do_full_backup
        return
    fi

    BASE_NAME=$(grep '^name=' "$BASE_META" | cut -d= -f2-)

    # Find the most recent entry in this chain (base or latest incremental)
    local LAST_META="$BASE_META"
    local LAST_SEQ=0
    NEWEST_TIME=$(stat -c %Y "$BASE_META" 2>/dev/null || echo 0)

    while IFS= read -r INC; do
        local MT
        MT=$(stat -c %Y "$INC" 2>/dev/null || echo 0)
        if [[ $MT -gt $NEWEST_TIME ]]; then
            NEWEST_TIME=$MT; LAST_META="$INC"
        fi
        local S
        S=$(grep '^sequence=' "$INC" | cut -d= -f2-)
        [[ -n "$S" && "$S" -gt "$LAST_SEQ" ]] && LAST_SEQ=$S
    done < <(get_incrementals_for_base "$BASE_NAME")

    local LAST_DATE NEW_SEQ
    LAST_DATE=$(grep '^date=' "$LAST_META" | cut -d= -f2-)
    NEW_SEQ=$((LAST_SEQ + 1))

    echo ""
    log_info "Base backup    : $BASE_NAME"
    log_info "Last checkpoint: $LAST_DATE"
    log_info "New sequence   : #$NEW_SEQ"
    echo ""
    log_step "Only files modified after  \"$LAST_DATE\"  will be included."
    echo ""

    ask_backup_name

    if [[ -f "$BACKUP_FILE" ]]; then
        log_warn "Backup with this name already exists."
        read -rp "  Overwrite? (y/n): " OW
        [[ ! "$OW" =~ ^[Yy]$ ]] && { log_warn "Cancelled."; return; }
    fi

    if ! command -v pv &>/dev/null; then
        apt-get install -y pv -qq 2>/dev/null || true
    fi

    EXCL=(
        --exclude=/proc --exclude=/sys --exclude=/dev
        --exclude=/run --exclude=/tmp --exclude=/mnt
        --exclude=/media --exclude=/lost+found
        --exclude="$BACKUP_DIR" --exclude=/var/cache/apt
    )

    log_step "Scanning and archiving changed files..."
    if command -v pv &>/dev/null; then
        tar -czp "${EXCL[@]}" --newer-mtime="$LAST_DATE" / 2>/dev/null | pv > "$BACKUP_FILE"
    else
        tar -czpf "$BACKUP_FILE" "${EXCL[@]}" --newer-mtime="$LAST_DATE" /
    fi

    save_meta "incremental" "$BASE_NAME" "$NEW_SEQ"
    SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    echo ""
    divider
    log_ok "Incremental backup completed!"
    log_info "Name     : $BACKUP_NAME"
    log_info "File     : $BACKUP_FILE"
    log_info "Size     : $SIZE"
    log_info "Base     : $BASE_NAME"
    log_info "Sequence : #$NEW_SEQ"
    log_info "Changes since: $LAST_DATE"
    divider
    echo ""

    read -rp "  Generate a temporary download link? (y/n): " WANT_LINK
    [[ "$WANT_LINK" =~ ^[Yy]$ ]] && start_http_server "$BACKUP_FILE"
}

# ─────────────────────────────────────────────────────────────
do_backup() {
    banner
    echo -e "  ${BOLD}═══ BACKUP MODE ═══${NC}"
    divider
    echo ""
    echo -e "  ${CYAN}1)${NC}  ${BOLD}Full Backup${NC}"
    echo -e "       Complete system snapshot — safest, largest size"
    echo ""
    echo -e "  ${CYAN}2)${NC}  ${BOLD}Light Backup${NC}"
    echo -e "       Skips logs, cache, docker layers, snaps — smaller size"
    echo ""
    echo -e "  ${CYAN}3)${NC}  ${BOLD}Incremental Backup${NC}"
    echo -e "       Only files changed since last backup — minimum storage"
    echo -e "       Requires an existing full or light base backup"
    echo ""
    divider
    read -rp "  Backup type (1/2/3): " BT
    echo ""
    case "$BT" in
        1) do_full_backup ;;
        2) do_light_backup ;;
        3) do_incremental_backup ;;
        *) log_err "Invalid choice."; sleep 1 ;;
    esac
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
            local NAME DATE SIZE FILE TYPE SEQ BASE
            NAME=$(grep '^name=' "$META" | cut -d= -f2-)
            DATE=$(grep '^date=' "$META" | cut -d= -f2-)
            SIZE=$(grep '^size=' "$META" | cut -d= -f2-)
            FILE=$(grep '^file=' "$META" | cut -d= -f2-)
            TYPE=$(grep '^type=' "$META" | cut -d= -f2-)
            SEQ=$(grep '^sequence=' "$META" | cut -d= -f2-)
            BASE=$(grep '^base=' "$META" | cut -d= -f2-)
            [[ -z "$TYPE" ]] && TYPE="full"

            local TLABEL
            case "$TYPE" in
                full)        TLABEL="${GREEN}[FULL ]${NC}" ;;
                light)       TLABEL="${BLUE}[LITE ]${NC}" ;;
                incremental) TLABEL="${YELLOW}[INC#${SEQ}]${NC}" ;;
                *)           TLABEL="${CYAN}[?????]${NC}" ;;
            esac

            printf "  ${CYAN}%-4s${NC} " "$I)"
            echo -e "${TLABEL} ${BOLD}${NAME}${NC}"
            printf "       ${YELLOW}%-22s${NC}  ${GREEN}%s${NC}\n" "$DATE" "$SIZE"
            printf "       ${MAGENTA}Path: %s${NC}\n" "$FILE"
            [[ "$TYPE" == "incremental" ]] && printf "       ${CYAN}Base: %s${NC}\n" "$BASE"
            echo ""
            I=$((I+1))
        done

        divider
        echo ""
        echo "  Enter a backup number to download it."
        echo -e "  For incremental backups you will be asked which checkpoint to merge."
        echo -e "  ${CYAN}Enter${NC} / ${CYAN}0${NC} to go back."
        echo ""
        read -rp "  Choice: " NUM

        [[ -z "$NUM" || "$NUM" == "0" ]] && return

        if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
            log_err "Invalid selection."; sleep 1; continue
        fi

        local SELECTED_META="${METAS[$((NUM-1))]}"
        local SELECTED_TYPE SELECTED_FILE SELECTED_NAME
        SELECTED_TYPE=$(grep '^type=' "$SELECTED_META" | cut -d= -f2-)
        SELECTED_FILE=$(grep '^file=' "$SELECTED_META" | cut -d= -f2-)
        SELECTED_NAME=$(grep '^name=' "$SELECTED_META" | cut -d= -f2-)
        [[ -z "$SELECTED_TYPE" ]] && SELECTED_TYPE="full"

        local BASE_META
        if [[ "$SELECTED_TYPE" == "incremental" ]]; then
            BASE_META=$(find_base_meta "$SELECTED_META") || { sleep 2; continue; }
        else
            BASE_META="$SELECTED_META"
        fi

        local BASE_NAME INC_COUNT=0
        BASE_NAME=$(grep '^name=' "$BASE_META" | cut -d= -f2-)
        while IFS= read -r _; do INC_COUNT=$((INC_COUNT+1)); done \
            < <(get_incrementals_for_base "$BASE_NAME")

        if [[ $INC_COUNT -gt 0 || "$SELECTED_TYPE" == "incremental" ]]; then
            # Chain exists — ask which checkpoint
            _CHAIN_RESULT=()
            ask_chain_checkpoint "$BASE_META" || { sleep 1; continue; }

            if [[ ${#_CHAIN_RESULT[@]} -eq 1 && "${_CHAIN_RESULT[0]}" == "$SELECTED_META" && "$SELECTED_TYPE" != "incremental" ]]; then
                # Only base selected, no merging needed
                if [[ ! -f "$SELECTED_FILE" ]]; then
                    log_err "Backup file not found: $SELECTED_FILE"; sleep 2; continue
                fi
                start_http_server "$SELECTED_FILE"
            else
                merge_chain_for_download "${_CHAIN_RESULT[@]}" || { sleep 2; continue; }
                log_info "Merged file location: $_MERGE_FILE"
                start_http_server "$_MERGE_FILE"
                rm -f "$_MERGE_FILE"
            fi
        else
            # Simple single backup
            if [[ ! -f "$SELECTED_FILE" ]]; then
                log_err "Backup file not found: $SELECTED_FILE"; sleep 2; continue
            fi
            start_http_server "$SELECTED_FILE"
        fi
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
        local NAME DATE SIZE TYPE SEQ
        NAME=$(grep '^name=' "$META" | cut -d= -f2-)
        DATE=$(grep '^date=' "$META" | cut -d= -f2-)
        SIZE=$(grep '^size=' "$META" | cut -d= -f2-)
        TYPE=$(grep '^type=' "$META" | cut -d= -f2-)
        SEQ=$(grep '^sequence=' "$META" | cut -d= -f2-)
        [[ -z "$TYPE" ]] && TYPE="full"
        local TLABEL="[$TYPE]"
        [[ "$TYPE" == "incremental" ]] && TLABEL="[inc#$SEQ]"
        printf "  ${CYAN}%-4s${NC} %-10s %-30s %-22s %s\n" "$I)" "$TLABEL" "$NAME" "$DATE" "$SIZE"
        I=$((I+1))
    done

    echo ""
    read -rp "  Backup number to delete (0 to cancel): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && { log_warn "Cancelled."; return; }

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
        log_err "Invalid selection."; return
    fi

    local SELECTED="${METAS[$((NUM-1))]}"
    local DEL_FILE DEL_NAME DEL_TYPE
    DEL_FILE=$(grep '^file=' "$SELECTED" | cut -d= -f2-)
    DEL_NAME=$(grep '^name=' "$SELECTED" | cut -d= -f2-)
    DEL_TYPE=$(grep '^type=' "$SELECTED" | cut -d= -f2-)
    [[ -z "$DEL_TYPE" ]] && DEL_TYPE="full"

    # Warn if deleting a base that has dependent incrementals
    if [[ "$DEL_TYPE" == "full" || "$DEL_TYPE" == "light" ]]; then
        local INC_COUNT=0
        while IFS= read -r _; do INC_COUNT=$((INC_COUNT+1)); done \
            < <(get_incrementals_for_base "$DEL_NAME")
        if [[ $INC_COUNT -gt 0 ]]; then
            echo ""
            log_warn "WARNING: This base has $INC_COUNT incremental backup(s) depending on it!"
            log_warn "Deleting it will make those incrementals unrestorable."
            echo ""
            read -rp "  Delete base AND all its incrementals? (yes/no): " CONF2
            if [[ "$CONF2" == "yes" ]]; then
                while IFS= read -r INC; do
                    local INC_FILE INC_NAME
                    INC_FILE=$(grep '^file=' "$INC" | cut -d= -f2-)
                    INC_NAME=$(grep '^name=' "$INC" | cut -d= -f2-)
                    [[ -f "$INC_FILE" ]] && rm -f "$INC_FILE"
                    rm -f "$INC"
                    log_ok "Deleted incremental: $INC_NAME"
                done < <(get_incrementals_for_base "$DEL_NAME")
            else
                log_warn "Cancelled."; return
            fi
        fi
    fi

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
check_disk_space() {
    local BACKUP_FILE="$1"
    log_step "Checking available disk space..."

    local BACKUP_SIZE_KB
    BACKUP_SIZE_KB=$(du -k "$BACKUP_FILE" | cut -f1)

    local ESTIMATED_KB=$(( BACKUP_SIZE_KB * 3 ))
    local AVAILABLE_KB
    AVAILABLE_KB=$(df / --output=avail -k | tail -1)

    local ESTIMATED_HR AVAILABLE_HR
    ESTIMATED_HR=$(( ESTIMATED_KB / 1024 / 1024 ))
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

                if [[ "$MOUNTPOINT" == "/" ]]; then
                    local ROOT_DEV
                    ROOT_DEV=$(findmnt -n -o SOURCE /)
                    NEW_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null)
                fi

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
fix_network() {
    local META_FILE="$1"
    log_step "Checking network interface compatibility..."

    local NEW_IFACES
    NEW_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)

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

    for FILE in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [[ -f "$FILE" ]] || continue
        if grep -q "$OLD_IFACES" "$FILE" 2>/dev/null; then
            cp "$FILE" "${FILE}.bak"
            sed -i "s|${OLD_IFACES}|${NEW_IFACES}|g" "$FILE"
            log_ok "Fixed netplan: $FILE"
            FIXED=$((FIXED+1))
        fi
    done

    if [[ -f /etc/network/interfaces ]]; then
        if grep -q "$OLD_IFACES" /etc/network/interfaces 2>/dev/null; then
            cp /etc/network/interfaces /etc/network/interfaces.bak
            sed -i "s|${OLD_IFACES}|${NEW_IFACES}|g" /etc/network/interfaces
            log_ok "Fixed /etc/network/interfaces"
            FIXED=$((FIXED+1))
        fi
    fi

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
        if command -v netplan &>/dev/null; then
            netplan generate 2>/dev/null && log_ok "Netplan config regenerated." || true
        fi
    fi
}

# ─────────────────────────────────────────────────────────────
fix_kernel_modules() {
    log_step "Checking kernel module compatibility..."

    local MODULES=(virtio_net virtio_blk virtio_scsi virtio_balloon)
    for MOD in "${MODULES[@]}"; do
        if ! lsmod | grep -q "^${MOD}" 2>/dev/null; then
            modprobe "$MOD" 2>/dev/null && log_ok "Loaded module: $MOD" || true
        fi
    done

    if command -v update-initramfs &>/dev/null; then
        log_step "Rebuilding initramfs (this may take a moment)..."
        update-initramfs -u -k all >> "$LOG_FILE" 2>&1 && \
            log_ok "initramfs rebuilt successfully." || \
            log_warn "initramfs rebuild had warnings — check $LOG_FILE"
    fi
}

# ─────────────────────────────────────────────────────────────
fix_bootloader() {
    log_step "Updating GRUB bootloader..."

    if command -v update-grub &>/dev/null; then
        update-grub >> "$LOG_FILE" 2>&1 && \
            log_ok "GRUB updated." || \
            log_warn "GRUB update had warnings."
    fi

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

# Apply an ordered array of meta files as restore layers
apply_restore_chain() {
    local METAS=("$@")
    for META in "${METAS[@]}"; do
        local FILE TYPE SEQ
        FILE=$(grep '^file=' "$META" | cut -d= -f2-)
        TYPE=$(grep '^type=' "$META" | cut -d= -f2-)
        SEQ=$(grep '^sequence=' "$META" | cut -d= -f2-)
        [[ -z "$TYPE" ]] && TYPE="full"
        [[ "$TYPE" == "incremental" ]] && TYPE="inc#$SEQ"

        if [[ ! -f "$FILE" ]]; then
            log_err "Archive not found: $FILE"; return 1
        fi
        check_disk_space "$FILE" || return 1

        log_step "Applying [$TYPE] layer: $(basename "$FILE")..."
        tar -xzpf "$FILE" -C / \
            --exclude=./proc --exclude=./sys \
            --exclude=./dev  --exclude=./run \
            2>/dev/null
        log_ok "Layer applied: $(basename "$FILE")"
        echo ""
    done
    return 0
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
    local USE_CHAIN=0

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
                local N D S T SEQ
                N=$(grep '^name=' "$META" | cut -d= -f2-)
                D=$(grep '^date=' "$META" | cut -d= -f2-)
                S=$(grep '^size=' "$META" | cut -d= -f2-)
                T=$(grep '^type=' "$META" | cut -d= -f2-)
                SEQ=$(grep '^sequence=' "$META" | cut -d= -f2-)
                [[ -z "$T" ]] && T="full"
                [[ "$T" == "incremental" ]] && T="inc#$SEQ"
                printf "  ${CYAN}%-4s${NC} [%-8s] %-30s %-22s %s\n" "$I)" "$T" "$N" "$D" "$S"
                I=$((I+1))
            done
            echo ""
            read -rp "  Select number: " NUM
            if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ $NUM -lt 1 || $NUM -gt ${#METAS[@]} ]]; then
                log_err "Invalid."; return
            fi
            RESTORE_META="${METAS[$((NUM-1))]}"
            RESTORE_FILE=$(grep '^file=' "$RESTORE_META" | cut -d= -f2-)
            local RESTORE_TYPE
            RESTORE_TYPE=$(grep '^type=' "$RESTORE_META" | cut -d= -f2-)
            [[ -z "$RESTORE_TYPE" ]] && RESTORE_TYPE="full"

            local BASE_META
            if [[ "$RESTORE_TYPE" == "incremental" ]]; then
                BASE_META=$(find_base_meta "$RESTORE_META") || return
            else
                BASE_META="$RESTORE_META"
            fi

            local BASE_NAME INC_COUNT=0
            BASE_NAME=$(grep '^name=' "$BASE_META" | cut -d= -f2-)
            while IFS= read -r _; do INC_COUNT=$((INC_COUNT+1)); done \
                < <(get_incrementals_for_base "$BASE_NAME")

            if [[ $INC_COUNT -gt 0 || "$RESTORE_TYPE" == "incremental" ]]; then
                _CHAIN_RESULT=()
                ask_chain_checkpoint "$BASE_META" || return
                USE_CHAIN=1
            else
                _CHAIN_RESULT=("$RESTORE_META")
                USE_CHAIN=1
            fi
            ;;
        2)
            read -rp "  File path: " RESTORE_FILE
            [[ ! -f "$RESTORE_FILE" ]] && { log_err "File not found."; return; }
            RESTORE_META="${RESTORE_FILE%.tar.gz}.meta"
            [[ ! -f "$RESTORE_META" ]] && RESTORE_META=""
            USE_CHAIN=0
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
            USE_CHAIN=0
            ;;
        *)
            log_err "Invalid choice."; return ;;
    esac

    echo ""
    log_section "RESTORE START"

    if [[ "$USE_CHAIN" -eq 1 ]]; then
        echo ""
        log_info "Restore plan — ${#_CHAIN_RESULT[@]} layer(s) will be applied in order:"
        for M in "${_CHAIN_RESULT[@]}"; do
            local N T SEQ
            N=$(grep '^name=' "$M" | cut -d= -f2-)
            T=$(grep '^type=' "$M" | cut -d= -f2-)
            SEQ=$(grep '^sequence=' "$M" | cut -d= -f2-)
            [[ -z "$T" ]] && T="full"
            [[ "$T" == "incremental" ]] && T="inc#$SEQ"
            log_info "  → [$T] $N"
        done
        echo ""
        log_warn "This will overwrite your current system!"
        read -rp "  Type YES to confirm: " CONF
        [[ "$CONF" != "YES" ]] && { log_warn "Cancelled."; return; }
        echo ""

        apply_restore_chain "${_CHAIN_RESULT[@]}" || return

        fix_uuid
        echo ""
        fix_network "${_CHAIN_RESULT[0]}"
        echo ""
        fix_kernel_modules
        echo ""
        fix_bootloader
        echo ""
        log_step "Reloading systemd..."
        systemctl daemon-reexec 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        log_ok "systemd reloaded."
    else
        # Single file restore (manual path or URL download)
        log_step "Running pre-restore checks..."
        echo ""
        check_disk_space "$RESTORE_FILE" || return

        echo ""
        log_info "Backup file: $RESTORE_FILE"
        log_warn "This will overwrite your current system!"
        read -rp "  Type YES to confirm: " CONF
        [[ "$CONF" != "YES" ]] && { log_warn "Cancelled."; return; }
        echo ""

        log_step "Extracting backup to system..."
        tar -xzpf "$RESTORE_FILE" -C / \
            --exclude=./proc --exclude=./sys \
            --exclude=./dev  --exclude=./run \
            2>/dev/null
        log_ok "Extraction complete."
        echo ""

        fix_uuid
        echo ""
        fix_network "$RESTORE_META"
        echo ""
        fix_kernel_modules
        echo ""
        fix_bootloader
        echo ""
        log_step "Reloading systemd..."
        systemctl daemon-reexec 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        log_ok "systemd reloaded."
    fi

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
echo -e "\033[0;32m[✔]\033[0m black-backup v3.0 installed! Run: \033[0;36mblack-backup\033[0m"
echo ""
