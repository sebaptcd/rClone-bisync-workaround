#!/bin/bash
# =============================================================================
# MobileSync.sh — rclone bisync wrapper for Termux/Android
# =============================================================================

# ── Self-update ───────────────────────────────────────────────────────────────
# Every launch fetches the latest MobileSync.sh from GitHub and runs it with the
# same working directory. If GitHub is unreachable, the local copy is used.

MOBILESYNC_RAW_URL="https://raw.githubusercontent.com/sebaptcd/rClone-bysinc-workaround/refs/heads/main/MobileSync.sh"

if [[ -z "${MOBILESYNC_UPDATED:-}" ]]; then
    LATEST_SCRIPT=""

    if command -v curl >/dev/null 2>&1; then
        LATEST_SCRIPT=$(curl -fsSL --retry 3 "$MOBILESYNC_RAW_URL" 2>/dev/null)
    fi

    if [[ -n "$LATEST_SCRIPT" ]] && bash -n <(printf '%s\n' "$LATEST_SCRIPT") 2>/dev/null; then
        export MOBILESYNC_UPDATED=1
        exec bash -c "$LATEST_SCRIPT" "$0" "$@"
    fi

    echo "[WARN] Could not fetch the latest MobileSync.sh from GitHub." >&2
    echo "       Continuing with the local copy." >&2
fi

# ── Machine ID ────────────────────────────────────────────────────────────────
# machineID.txt lives in the working directory and contains only the device
# name: letters, numbers, hyphen (-) and underscore (_). No spaces.
# If it is missing, the script prompts for a valid name and creates the file.

MACHINE_ID_FILE="machineID.txt"

if [[ ! -f "$MACHINE_ID_FILE" ]]; then
    echo "" >&2
    echo "[WARN] machineID.txt was not found in the current directory." >&2
    echo "       Let's create it now." >&2
    echo "" >&2
    echo "       Use only your device name, with no spaces." >&2
    echo "       Allowed characters: letters (A-Z, a-z), numbers (0-9)," >&2
    echo "       hyphen (-) and underscore (_)." >&2
    echo "       Example: WATER-LION" >&2
    echo "" >&2

    if [[ ! -t 0 ]]; then
        echo "[ERR!] Cannot prompt for a device name because stdin is not a terminal." >&2
        echo "       Create machineID.txt manually in the current directory." >&2
        exit 1
    fi

    while true; do
        if ! read -rp " Device name: " MACHINE_ID; then
            echo "" >&2
            echo "[ERR!] No device name provided. Aborting." >&2
            exit 1
        fi

        if [[ "$MACHINE_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
            if printf '%s\n' "$MACHINE_ID" > "$MACHINE_ID_FILE"; then
                chmod 600 "$MACHINE_ID_FILE" 2>/dev/null || true
                echo "[ OK ] Created ${MACHINE_ID_FILE} with device name: ${MACHINE_ID}" >&2
                break
            else
                echo "[ERR!] Could not write ${MACHINE_ID_FILE}." >&2
                exit 1
            fi
        else
            echo "[ERR!] Invalid device name. Use letters, numbers, - and _ only (no spaces)." >&2
        fi
    done
else
    MACHINE_ID=$(<"$MACHINE_ID_FILE")
fi

if [[ ! "$MACHINE_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    cat >&2 <<EOF
[ERR!] Invalid machine ID in "${MACHINE_ID_FILE}": '${MACHINE_ID}'

       The file must contain only your device name, with no spaces.
       Allowed characters: letters (A-Z, a-z), numbers (0-9),
       hyphen (-) and underscore (_).

       Example contents: WATER-LION
EOF
    exit 1
fi

# ── Configuration ─────────────────────────────────────────────────────────────

SYNC_LOCK_DIR="Dev:syncControl/"
SYNC_LOCK_REMOTE="Dev:syncControl/syncTime.lock"
LOG_REMOTE_PATH="Dev:syncControl/Logs/${MACHINE_ID}"

BISYNC_FLAGS="--recover --transfers 64 --checkers 48 --create-empty-src-dirs --force --max-lock 600"
LOCK_TIMEOUT=120   # seconds before a remote lock is considered stale
SYNC_INTERVAL=300  # seconds to wait between sync cycles

# Define remotes as parallel arrays: REMOTE_NAME[i] <-> LOCAL_PATH[i]
REMOTE_NAMES=(
    "Dropbox:Drive"
    "WORKSTATION:@WORKSTATION/Cross-platform"
    "Dev:Drive/Cross-platform"
)
LOCAL_PATHS=(
    "/storage/emulated/0/Cloud/Dropbox"
    "/storage/emulated/0/Cloud/WORKSTATION"
    "/storage/emulated/0/Cloud/Dev"
)
# Label used in log messages for each remote
REMOTE_LABELS=(
    "Personal (Dropbox)"
    "WORKSTATION"
    "Dev"
)

# ── Appearance & Logging ──────────────────────────────────────────────────────

# ANSI Color Codes
CLR_RESET='\033[0m'
CLR_BOLD='\033[1m'
CLR_DIM='\033[2m'
CLR_INFO='\033[1;34m'     # Bold Blue
CLR_SUCCESS='\033[1;32m'  # Bold Green
CLR_WARN='\033[1;33m'     # Bold Yellow
CLR_ERROR='\033[1;31m'    # Bold Red
CLR_CYAN='\033[0;36m'     # Cyan (for labels)
CLR_ITALIC='\033[3m'

log_msg() {
    local level="${1:-INFO}"
    shift
    local timestamp
    timestamp=$(date '+%H:%M:%S')
    local color=$CLR_INFO
    local prefix="[INFO]"

    case "${level^^}" in
        SUCCESS) color=$CLR_SUCCESS; prefix="[ OK ]" ;;
        WARN)    color=$CLR_WARN;    prefix="[WARN]" ;;
        ERROR)   color=$CLR_ERROR;   prefix="[ERR!]" ;;
        *)       color=$CLR_INFO;    prefix="[INFO]" ;;
    esac

    echo -e "${CLR_DIM}${timestamp}${CLR_RESET} ${color}${prefix}${CLR_RESET} $*"
}



notify() {
    local title="$1"
    local body="$2"
    # notify-send may not be available in all Termux setups; guard gracefully
    command -v notify-send &>/dev/null && notify-send "$title" "$body"
    log_msg "INFO" "${CLR_BOLD}${title}:${CLR_RESET} $body"
}

get_epoch() {
    date +%s
}

# ── First-run resync menu ──────────────────────────────────────────────────────
# Populates RESYNC_FLAGS array: RESYNC_FLAGS[i]="--resync" or ""
select_resync_remotes() {
    local count=${#REMOTE_NAMES[@]}
    declare -ga RESYNC_FLAGS
    for i in "${!REMOTE_NAMES[@]}"; do
        RESYNC_FLAGS[$i]=""
    done

    echo -e "\n${CLR_CYAN}══════════════════════════════════════════════════${CLR_RESET}"
    echo -e "  ${CLR_BOLD}MobileSync — First-Run Resync Setup${CLR_RESET}"
    echo -e "${CLR_CYAN}══════════════════════════════════════════════════${CLR_RESET}\n"
    echo " Do you want to run --resync (one-way mirror) on any"
    echo " remote before starting the normal bisync cycle?"
    echo ""
    echo -e "  ${CLR_SUCCESS}[A]${CLR_RESET} Apply --resync to ALL remotes"
    echo -e "  ${CLR_INFO}[N]${CLR_RESET} Skip --resync for ALL remotes (normal bisync)"
    echo -e "  ${CLR_WARN}[S]${CLR_RESET} Select remotes individually"
    echo ""
    read -rp " Choice [A/N/S]: " choice
    echo ""

    case "${choice^^}" in
        A)
            for i in "${!REMOTE_NAMES[@]}"; do
                RESYNC_FLAGS[$i]="--resync"
                log_msg "INFO" "Action: Enabling --resync for ${CLR_CYAN}${REMOTE_LABELS[$i]}${CLR_RESET}"
            done
            ;;
        S)
            for i in "${!REMOTE_NAMES[@]}"; do
                read -rp "   Use --resync for '${REMOTE_LABELS[$i]}'? [y/N]: " yn
                if [[ "${yn^^}" == "Y" ]]; then
                    RESYNC_FLAGS[$i]="--resync"
                    log_msg "INFO" "--resync enabled for: ${CLR_CYAN}${REMOTE_LABELS[$i]}${CLR_RESET}"
                fi
            done
            ;;
        *)
            log_msg "INFO" "Skipping --resync for all remotes."
            ;;
    esac
    echo ""
}

# ── Sync-lock helpers ──────────────────────────────────────────────────────────

# Write our timestamp+machineID to the remote lock file every 5 s (background).
# Sets global $LOCK_PID.
start_lock_heartbeat() {
    (
        while true; do
            echo "$(get_epoch) ${MACHINE_ID}" | rclone rcat "$SYNC_LOCK_REMOTE" 2>/dev/null
            sleep 5
        done
    ) &
    LOCK_PID=$!
    log_msg "INFO" "  └─ Heartbeat active (PID $LOCK_PID)."
}

stop_lock_heartbeat() {
    if [[ -n "${LOCK_PID:-}" ]]; then
        kill "$LOCK_PID" 2>/dev/null
        rclone delete "$SYNC_LOCK_REMOTE" 2>/dev/null
        log_msg "INFO" "  └─ Heartbeat stopped."
        LOCK_PID=""
    fi
}

wait_for_lock() {
    log_msg "INFO" "Checking remote sync lock..."
    while true; do
        local remote_file
        remote_file=$(rclone lsf "$SYNC_LOCK_REMOTE" 2>/dev/null)

        if [[ "$remote_file" != "syncTime.lock" ]]; then
            log_msg "SUCCESS" "Lock clear. Proceeding."
            return
        fi

        local lock_contents
        lock_contents=$(rclone cat "$SYNC_LOCK_REMOTE" 2>/dev/null)

        # Treat an itemNotFound error response as "no lock"
        if echo "$lock_contents" | grep -q '"error":.*"code":"itemNotFound"\|Item not found'; then
            log_msg "WARN" "Remote lock not found (API quirk). Retrying..."
            sleep 1
            continue
        fi

        local lock_epoch lock_machine
        lock_epoch=$(echo "$lock_contents" | awk '{print $1}')
        lock_machine=$(echo "$lock_contents" | awk '{print $2}')

        # If the lock belongs to THIS machine it is a leftover from the previous
        # cycle that stop_lock_heartbeat hadn't fully cleaned yet — remove it and
        # proceed immediately instead of waiting 60 s.
        if [[ "$lock_machine" == "$MACHINE_ID" ]]; then
            log_msg "INFO" "Our previous lock detected. Removing."
            rclone delete "$SYNC_LOCK_REMOTE" 2>/dev/null
            return
        fi

        local age=$(( $(get_epoch) - lock_epoch ))
        log_msg "INFO" "Sync locked by ${CLR_WARN}$lock_machine${CLR_RESET} (Age: ${age}s / Max: ${LOCK_TIMEOUT}s)"

        if (( age < LOCK_TIMEOUT )); then
            notify "MobileSync" "Machine $lock_machine is syncing. Waiting 60s…"
            sleep 60
        else
            log_msg "WARN" "Stale lock from $lock_machine detected. Overriding."
            notify "MobileSync" "Overriding stale lock."
            rclone delete "$SYNC_LOCK_REMOTE"
        fi
    done
}

# ── Sync cycle ─────────────────────────────────────────────────────────────────

# Run bisync for every remote. On the first call, --resync flags are applied
# then cleared so subsequent cycles run normally.
run_sync_cycle() {
    local is_first_run="${1:-false}"
    local local_log="./mobilesync_cycle.log"
    local live_log_remote="$LOG_REMOTE_PATH/LIVE_LOG.txt"
    : > "$local_log"

    # Start background "log heartbeat" to provide live visibility
    (
        while [[ -f "$local_log" ]]; do
            rclone copyto "$local_log" "$live_log_remote" 2>/dev/null
            sleep 15
        done
    ) &
    local LOG_HEARTBEAT_PID=$!

    for i in "${!REMOTE_NAMES[@]}"; do
        local remote="${REMOTE_NAMES[$i]}"
        local local_path="${LOCAL_PATHS[$i]}"
        local label="${REMOTE_LABELS[$i]}"
        local extra_flags=""

        if [[ "$is_first_run" == "true" && -n "${RESYNC_FLAGS[$i]:-}" ]]; then
            extra_flags="${RESYNC_FLAGS[$i]}"
            RESYNC_FLAGS[$i]=""   # clear after first use
        fi

        log_msg "INFO" "  ┌ Syncing: ${CLR_CYAN}${label}${CLR_RESET} $extra_flags"
        # shellcheck disable=SC2086
        rclone bisync "$remote" "$local_path" $BISYNC_FLAGS $extra_flags \
            --log-file "$local_log" --log-level INFO
        log_msg "SUCCESS" "  └─ Done: $label"
        sleep 1
    done

    # Stop log heartbeat and finalize logs
    if [[ -n "${LOG_HEARTBEAT_PID:-}" ]]; then
        kill "$LOG_HEARTBEAT_PID" 2>/dev/null
        wait "$LOG_HEARTBEAT_PID" 2>/dev/null
    fi
    
    if [[ -f "$local_log" ]]; then
        local remote_log_name="MobileSync_$(date +%Y%m%d_%H%M%S)_${MACHINE_ID}.txt"
        log_msg "INFO" "Uploading logs to cloud..."
        rclone copyto "$local_log" "$LOG_REMOTE_PATH/$remote_log_name"
        rclone delete "$live_log_remote" 2>/dev/null
        
        log_msg "INFO" "Cleaning up logs older than 1 day..."
        rclone delete "$LOG_REMOTE_PATH" --min-age 24h
        rm -f "$local_log"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Clean up on Ctrl+C / SIGTERM so the remote lock is always removed
trap 'echo -e "\n"; log_msg "WARN" "Interrupted. Cleaning up…"; stop_lock_heartbeat; command -v termux-wake-unlock >/dev/null && termux-wake-unlock; exit 0' INT TERM

# Hold a wake-lock to ensure the CPU doesn't sleep in the background
# BATTERY SAVER: Comment out the line below to let CPU sleep (saves battery, but timing becomes less accurate)
command -v termux-wake-lock >/dev/null && termux-wake-lock

# Ask the user about --resync before entering the loop
select_resync_remotes

FIRST_RUN=true
CYCLE=0

while true; do
    (( CYCLE++ ))

    # ── Wait for exclusive sync lock ─────────────────────────────────────────
    timestamp=$(date '+%H:%M:%S')
    echo -e "\n${CLR_BOLD}━━━━ Cycle #${CYCLE} (${timestamp})${CLR_RESET}"
    wait_for_lock
    start_lock_heartbeat

    # ── Run syncs ────────────────────────────────────────────────────────────
    log_msg "INFO" "Starting sync pass..."
    run_sync_cycle "$FIRST_RUN"
    FIRST_RUN=false
    log_msg "SUCCESS" "Cycle #${CYCLE} completed."

    # ── Release lock ─────────────────────────────────────────────────────────
    stop_lock_heartbeat

    echo -e ""
    UI_PAUSED=false
    for (( i=SYNC_INTERVAL; i>0; i-- )); do
        if [[ "$UI_PAUSED" == "false" ]]; then
            printf "\r${CLR_DIM}Next cycle in: %3d seconds... ${CLR_RESET}" "$i"
            echo -ne "\n${CLR_ITALIC}(Press 'S' to sync, 'P' to pause UI and scroll)${CLR_RESET}\n"
        fi
        
        # Wait 1 second for a character. -t 1 is the timeout, -n 1 is one character.
        read -t 1 -n 1 key
        
        if [[ "$UI_PAUSED" == "false" ]]; then
            # Move back up to Line 1
            echo -ne "\033[2F"
        fi
        
        case "${key^^}" in
            S)
                if [[ "$UI_PAUSED" == "false" ]]; then
                    # Clear both lines before breaking
                    echo -ne "\r\033[K\n\033[K\033[F"
                fi
                echo -e "\n\n${CLR_INFO}S pressed! Skipping wait...${CLR_RESET}"
                break
                ;;
            P)
                if [[ "$UI_PAUSED" == "false" ]]; then
                    UI_PAUSED=true
                    # Clear the two lines and stay at top
                    echo -ne "\r\033[K\n\033[K\033[F"
                    log_msg "INFO" "UI paused for scrolling. (Sync still running. Press 'P' to resume UI)"
                else
                    UI_PAUSED=false
                    echo -e "\n\n${CLR_SUCCESS}UI Resumed.${CLR_RESET}"
                    # UI will redraw on next iteration
                fi
                ;;
        esac
    done
    
    # Final cleanup of the countdown lines if we finished normally
    if [[ "$UI_PAUSED" == "false" && $i -le 0 ]]; then
         echo -ne "\r\033[K\n\033[K\033[F"
    fi
    echo -e "\n\r${CLR_SUCCESS}🚀 Starting next cycle!          ${CLR_RESET}"
done
