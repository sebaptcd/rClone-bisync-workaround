#!/bin/bash
# =============================================================================
# MobileSync.sh — rclone bisync wrapper for Termux/Android
# =============================================================================

# ── Machine ID ────────────────────────────────────────────────────────────────
# machineID.txt lives in the working directory and contains only the device
# name: letters, numbers, hyphen (-) and underscore (_). No spaces.
# If it is missing, the script prompts for a valid name and creates it here.

MACHINE_ID_FILE="machineID.txt"

valid_machine_id() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

machine_id_instructions() {
    echo "       Use only your device name, with no spaces." >&2
    echo "       Allowed characters: letters (A-Z, a-z), numbers (0-9)," >&2
    echo "       hyphen (-) and underscore (_)." >&2
    echo "       Example: MY-DEVICE" >&2
}

if [[ -f "$MACHINE_ID_FILE" ]]; then
    MACHINE_ID=$(<"$MACHINE_ID_FILE")
    if ! valid_machine_id "$MACHINE_ID"; then
        echo "" >&2
        echo "[ERR!] Invalid machine ID in \"${MACHINE_ID_FILE}\": '${MACHINE_ID}'" >&2
        machine_id_instructions
        exit 1
    fi
else
    echo "" >&2
    echo "[WARN] ${MACHINE_ID_FILE} was not found in the current directory:" >&2
    echo "       $(pwd)" >&2
    echo "       Let's create it now." >&2
    machine_id_instructions
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

        if valid_machine_id "$MACHINE_ID"; then
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
fi

# ── Configuration ─────────────────────────────────────────────────────────────

SYNC_LOCK_DIR="Dev:syncControl/"
SYNC_LOCK_REMOTE="Dev:syncControl/syncTime.lock"
LOG_REMOTE_PATH="Dev:syncControl/Logs/${MACHINE_ID}"

BISYNC_FLAGS="--recover --resilient --transfers 64 --checkers 48 --create-empty-src-dirs --force --max-lock 600 --color NEVER"
LOCK_TIMEOUT=120   # seconds before a remote lock is considered stale
SYNC_INTERVAL=300  # seconds to wait between sync cycles
LOCK_CHECK_RETRIES=3      # attempts to read the remote lock before skipping a cycle
LOCK_CHECK_RETRY_DELAY=10 # seconds between lock-check attempts

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

# Returns success when an rclone error only means "the path/file does not exist".
# Deliberately does not match generic "not found" text (for example the
# "Config file ... not found" notice), so real login errors are not mistaken
# for a missing lock file.
is_not_found_error() {
    printf '%s\n' "${1:-}" | grep -Eiq 'itemNotFound|Item not found|directory not found|object not found|path not found|File not found|no such file|does not exist|doesn.t exist|Error 404'
}

# Returns success when the output contains an authentication/login failure.
contains_auth_error() {
    printf '%s\n' "${1:-}" | grep -Eiq 'expired_access_token|InvalidAuthenticationToken|AuthenticationException|invalid_grant|token (has )?expired|401 Unauthorized|Unauthorized|permission denied|access_denied|oauth2|cannot fetch token|reauthenticate|re-authenticate'
}

# Returns success when bisync says the pair needs a manual --resync.
contains_resync_required() {
    printf '%s\n' "${1:-}" | grep -Eq 'Bisync critical error|Must run --resync|Bisync aborted'
}

notify() {
    local title="$1"
    local body="$2"

    # Notifications are best-effort and must never block the sync loop.
    # termux-notification can wait for the Termux:API service (or hang when it
    # is unavailable), which previously stopped the countdown and the next
    # cycle. Run it in the background, with a timeout when available.
    # Termux has termux-notification; desktop Linux has notify-send.
    if command -v termux-notification &>/dev/null; then
        if command -v timeout &>/dev/null; then
            timeout 5 termux-notification --title "$title" --content "$body" \
                >/dev/null 2>&1 &
        else
            termux-notification --title "$title" --content "$body" \
                >/dev/null 2>&1 &
        fi
    elif command -v notify-send &>/dev/null; then
        if command -v timeout &>/dev/null; then
            timeout 5 notify-send "$title" "$body" >/dev/null 2>&1 &
        else
            notify-send "$title" "$body" >/dev/null 2>&1 &
        fi
    fi

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

# Remove the remote lock file. Missing files (exit 3/4) are not errors.
remove_remote_lock() {
    local purpose="$1"
    local delete_error

    if ! delete_error=$(rclone delete "$SYNC_LOCK_REMOTE" --color NEVER 2>&1); then
        if ! is_not_found_error "$delete_error"; then
            log_msg "WARN" "Could not remove ${purpose}: ${delete_error:-unknown error}"
            return 1
        fi
    fi

    return 0
}

# Write our timestamp+machineID to the remote lock file every 5 s (background).
# Sets global $LOCK_PID. Heartbeat failures are shown once, then at most once
# per minute, so a broken Dev: remote does not flood the terminal.
start_lock_heartbeat() {
    local err_file="${TMPDIR:-/tmp}/mobilesync_lock_hb.$$.err"
    local error_flag="${TMPDIR:-/tmp}/mobilesync_lock_hb.$$.flag"

    : > "$err_file"
    rm -f "$error_flag"

    (
        local last_error_time=0

        while true; do
            local now heartbeat_error

            if echo "$(get_epoch) ${MACHINE_ID}" | rclone rcat "$SYNC_LOCK_REMOTE" --color NEVER 2>"$err_file"; then
                last_error_time=0
                rm -f "$error_flag"
            else
                : > "$error_flag"
                heartbeat_error=$(<"$err_file")
                now=$(get_epoch)

                if (( last_error_time == 0 || now - last_error_time >= 60 )); then
                    log_msg "ERROR" "Could not refresh remote lock: ${heartbeat_error:-unknown error}"
                    last_error_time=$now
                fi
            fi

            sleep 5
        done
    ) &

    LOCK_PID=$!
    LOCK_HB_ERR_FILE="$err_file"
    LOCK_HB_ERROR_FLAG="$error_flag"
    log_msg "INFO" "  └─ Heartbeat active (PID $LOCK_PID)."
}

stop_lock_heartbeat() {
    if [[ -n "${LOCK_PID:-}" ]]; then
        kill "$LOCK_PID" 2>/dev/null
        wait "$LOCK_PID" 2>/dev/null

        if [[ -n "${LOCK_HB_ERROR_FLAG:-}" && -f "$LOCK_HB_ERROR_FLAG" ]]; then
            CYCLE_ISSUES=$(( CYCLE_ISSUES + 1 ))
            rm -f "$LOCK_HB_ERROR_FLAG"
        fi

        if [[ -n "${LOCK_HB_ERR_FILE:-}" ]]; then
            rm -f "$LOCK_HB_ERR_FILE"
        fi

        if ! remove_remote_lock "remote lock"; then
            CYCLE_ISSUES=$(( CYCLE_ISSUES + 1 ))
        fi

        log_msg "INFO" "  └─ Heartbeat stopped."
        LOCK_PID=""
        LOCK_HB_ERR_FILE=""
        LOCK_HB_ERROR_FLAG=""
    fi
}

wait_for_lock() {
    log_msg "INFO" "Checking remote sync lock..."

    local attempt=0

    while true; do
        local remote_file lock_error

        # Keep stdout clean for the filename comparison. If the call fails,
        # run it again with stderr captured so the real cause can be shown.
        if ! remote_file=$(rclone lsf "$SYNC_LOCK_REMOTE" --color NEVER 2>/dev/null); then
            if lock_error=$(rclone lsf "$SYNC_LOCK_REMOTE" --color NEVER 2>&1); then
                remote_file="$lock_error"
            elif is_not_found_error "$lock_error"; then
                remote_file=""
            else
                attempt=$(( attempt + 1 ))
                log_msg "ERROR" "Could not check remote sync lock (attempt ${attempt}/${LOCK_CHECK_RETRIES}): ${lock_error:-unknown error}"

                if (( attempt >= LOCK_CHECK_RETRIES )); then
                    log_msg "ERROR" "Remote lock is unavailable. Skipping this cycle."
                    return 1
                fi

                sleep "$LOCK_CHECK_RETRY_DELAY"
                continue
            fi
        fi

        if [[ "$remote_file" != "syncTime.lock" ]]; then
            log_msg "SUCCESS" "Lock clear. Proceeding."
            return 0
        fi

        local lock_contents=""
        if ! lock_contents=$(rclone cat "$SYNC_LOCK_REMOTE" --color NEVER 2>/dev/null); then
            local cat_error
            if cat_error=$(rclone cat "$SYNC_LOCK_REMOTE" --color NEVER 2>&1); then
                lock_contents="$cat_error"
            elif is_not_found_error "$cat_error"; then
                log_msg "WARN" "Remote lock disappeared while reading it. Retrying..."
                sleep 1
                continue
            else
                attempt=$(( attempt + 1 ))
                log_msg "ERROR" "Could not read remote sync lock (attempt ${attempt}/${LOCK_CHECK_RETRIES}): ${cat_error:-unknown error}"

                if (( attempt >= LOCK_CHECK_RETRIES )); then
                    log_msg "ERROR" "Remote lock is unavailable. Skipping this cycle."
                    return 1
                fi

                sleep "$LOCK_CHECK_RETRY_DELAY"
                continue
            fi
        fi

        # Treat an itemNotFound error response as "no lock"
        if printf '%s\n' "$lock_contents" | grep -q '"error":.*"code":"itemNotFound"\|Item not found'; then
            log_msg "WARN" "Remote lock not found (API quirk). Retrying..."
            sleep 1
            continue
        fi

        local lock_epoch lock_machine
        lock_epoch=$(printf '%s\n' "$lock_contents" | awk '{print $1}')
        lock_machine=$(printf '%s\n' "$lock_contents" | awk '{print $2}')

        if [[ ! "$lock_epoch" =~ ^[0-9]+$ ]]; then
            log_msg "WARN" "Malformed remote lock (contents: '${lock_contents}'). Removing it."
            if ! remove_remote_lock "malformed remote lock"; then
                return 1
            fi
            continue
        fi

        # If the lock belongs to THIS machine it is a leftover from the previous
        # cycle that stop_lock_heartbeat hadn't fully cleaned yet — remove it and
        # proceed immediately instead of waiting 60 s.
        if [[ "$lock_machine" == "$MACHINE_ID" ]]; then
            log_msg "INFO" "Our previous lock detected. Removing."
            if ! remove_remote_lock "our previous lock"; then
                return 1
            fi
            return 0
        fi

        local age=$(( $(get_epoch) - lock_epoch ))
        log_msg "INFO" "Sync locked by ${CLR_WARN}$lock_machine${CLR_RESET} (Age: ${age}s / Max: ${LOCK_TIMEOUT}s)"

        if (( age < LOCK_TIMEOUT )); then
            notify "MobileSync" "Machine $lock_machine is syncing. Waiting 60s…"
            sleep 60
        else
            log_msg "WARN" "Stale lock from $lock_machine detected. Overriding."
            notify "MobileSync" "Overriding stale lock."
            if ! remove_remote_lock "stale remote lock"; then
                return 1
            fi
        fi
    done
}

# ── Sync cycle ─────────────────────────────────────────────────────────────────

# Run bisync for every remote. On the first call, --resync flags are applied
# then cleared so subsequent cycles run normally.
run_sync_cycle() {
    local is_first_run="${1:-false}"
    local live_log_remote="$LOG_REMOTE_PATH/LIVE_LOG.txt"
    local heartbeat_flag
    local live_snapshot
    LOCAL_LOG_FILE="${TMPDIR:-/tmp}/mobilesync_cycle.$$.${CYCLE:-0}.log"
    LIVE_LOG_SNAPSHOT="${TMPDIR:-/tmp}/mobilesync_live.$$.${CYCLE:-0}.log"
    local local_log="$LOCAL_LOG_FILE"
    live_snapshot="$LIVE_LOG_SNAPSHOT"
    heartbeat_flag="${local_log}.heartbeat_error"
    : > "$local_log"
    rm -f "$heartbeat_flag" "$live_snapshot"

    # Start background "log heartbeat" to provide live visibility.
    # Copy a stable snapshot before uploading: uploading the log while tee is
    # still appending to it makes rclone fail with "source file is being
    # updated" or a quickxor mismatch. Failures are shown once, then at most
    # once per minute.
    (
        local last_error_time=0

        while [[ -f "$local_log" ]]; do
            local now copy_error

            cp -f "$local_log" "$live_snapshot" 2>/dev/null

            if ! copy_error=$(rclone copyto "$live_snapshot" "$live_log_remote" --color NEVER 2>&1); then
                : > "$heartbeat_flag"
                now=$(get_epoch)

                if (( last_error_time == 0 || now - last_error_time >= 60 )); then
                    log_msg "WARN" "Could not update the live log: ${copy_error:-unknown error}"
                    last_error_time=$now
                fi
            else
                last_error_time=0
                rm -f "$heartbeat_flag"
            fi

            sleep 15
        done
    ) &
    LOG_HEARTBEAT_PID=$!

    for i in "${!REMOTE_NAMES[@]}"; do
        local remote="${REMOTE_NAMES[$i]}"
        local local_path="${LOCAL_PATHS[$i]}"
        local label="${REMOTE_LABELS[$i]}"
        local extra_flags=""
        local log_offset run_output run_start rc
        local failed=false
        local rc_label
        local failure_reason

        if [[ "$is_first_run" == "true" && -n "${RESYNC_FLAGS[$i]:-}" ]]; then
            extra_flags="${RESYNC_FLAGS[$i]}"
            RESYNC_FLAGS[$i]=""   # clear after first use
        fi

        log_offset=$(wc -l < "$local_log" | tr -d '[:space:]')
        printf '\n===== %s | %s | %s <-> %s =====\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$label" "$remote" "$local_path" >> "$local_log"

        log_msg "INFO" "  ┌ Syncing: ${CLR_CYAN}${label}${CLR_RESET} $extra_flags"

        # Stream rclone's output: keep the full log, show ERROR/CRITICAL/NOTICE
        # lines in the terminal as they happen. PIPESTATUS[0] is rclone's exit
        # code, because the pipeline itself would hide it.
        # shellcheck disable=SC2086
        rclone bisync "$remote" "$local_path" $BISYNC_FLAGS $extra_flags \
            --log-level INFO 2>&1 \
            | tee -a "$local_log" \
            | while IFS= read -r line; do
                case "$line" in
                    *ERROR*|*CRITICAL*|*"Failed to"*|*"fatal error"*|*"Errors:"*|*expired_access_token*|*InvalidAuthenticationToken*|*AuthenticationException*|*invalid_grant*|*"permission denied"*|*Unauthorized*|*unauthorized*|*"command not found"*)
                        printf "${CLR_ERROR}[rclone] %s${CLR_RESET}\n" "$line"
                        ;;
                    *NOTICE:*|*WARNING*)
                        printf "${CLR_WARN}[rclone] %s${CLR_RESET}\n" "$line"
                        ;;
                esac
            done
        rc=${PIPESTATUS[0]}
        rc_label="exit ${rc}"

        run_start=$(( log_offset + 1 ))
        run_output=$(tail -n "+${run_start}" "$local_log")

        if (( rc != 0 )); then
            failed=true
        fi

        if contains_resync_required "$run_output"; then
            failed=true
            if (( rc == 0 )); then
                rc_label="exit 0 but critical error logged"
            fi
        fi

        failure_reason=$(printf '%s\n' "$run_output" | grep -E 'ERROR|CRITICAL' | tail -n 1)
        if [[ -z "$failure_reason" ]]; then
            failure_reason="rclone ${rc_label}"
        fi

        if [[ "$failed" == "true" ]]; then
            log_msg "ERROR" "  └─ FAILED: ${label} (${rc_label})"
            log_msg "ERROR" "     Last error: ${failure_reason}"

            CYCLE_FAILURES=$(( CYCLE_FAILURES + 1 ))
            CYCLE_FAILED_LABELS+=("$label")
            CYCLE_FAILED_SUMMARY+=("${label} (${rc_label}): ${failure_reason}")

            if contains_auth_error "$run_output"; then
                local remote_name="${remote%%:*}"
                log_msg "ERROR" "Authentication for remote '${remote_name}' failed or expired."
                log_msg "INFO" "Fix: rclone config reconnect ${remote_name}:"
                log_msg "INFO" "Then restart MobileSync.sh and choose --resync for '${label}' if rclone requires it."
            fi

            if (( rc == 2 )); then
                log_msg "ERROR" "rclone rejected the command (exit 2). Check BISYNC_FLAGS and the remote/local paths."
            fi

            if (( rc == 7 )) || contains_resync_required "$run_output"; then
                log_msg "WARN" "'${label}' is locked out until a --resync succeeds."
                log_msg "INFO" "Resync: rclone bisync \"${remote}\" \"${local_path}\" ${BISYNC_FLAGS} --resync"
            fi

            printf 'RESULT: FAILED (%s)\n' "$rc_label" >> "$local_log"
        else
            log_msg "SUCCESS" "  └─ Done: $label"
            printf 'RESULT: OK\n' >> "$local_log"
        fi

        sleep 1
    done

    # Stop log heartbeat and finalize logs
    if [[ -n "${LOG_HEARTBEAT_PID:-}" ]]; then
        kill "$LOG_HEARTBEAT_PID" 2>/dev/null
        wait "$LOG_HEARTBEAT_PID" 2>/dev/null
        LOG_HEARTBEAT_PID=""
    fi

    rm -f "$live_snapshot"
    LIVE_LOG_SNAPSHOT=""

    if [[ -f "$heartbeat_flag" ]]; then
        CYCLE_ISSUES=$(( CYCLE_ISSUES + 1 ))
        rm -f "$heartbeat_flag"
    fi

    if [[ -f "$local_log" ]]; then
        local remote_log_name="MobileSync_$(date +%Y%m%d_%H%M%S)_${MACHINE_ID}.txt"
        local upload_error delete_error cleanup_error
        log_msg "INFO" "Uploading logs to cloud..."

        if upload_error=$(rclone copyto "$local_log" "$LOG_REMOTE_PATH/$remote_log_name" --color NEVER 2>&1); then
            if ! delete_error=$(rclone delete "$live_log_remote" --color NEVER 2>&1); then
                if ! is_not_found_error "$delete_error"; then
                    log_msg "WARN" "Could not remove the live log: ${delete_error:-unknown error}"
                    CYCLE_ISSUES=$(( CYCLE_ISSUES + 1 ))
                fi
            fi

            log_msg "INFO" "Cleaning up logs older than 1 day..."
            if ! cleanup_error=$(rclone delete "$LOG_REMOTE_PATH" --min-age 24h --color NEVER 2>&1); then
                if ! is_not_found_error "$cleanup_error"; then
                    log_msg "WARN" "Could not clean old logs: ${cleanup_error:-unknown error}"
                    CYCLE_ISSUES=$(( CYCLE_ISSUES + 1 ))
                fi
            fi

            rm -f "$local_log"
            LOCAL_LOG_FILE=""
        else
            log_msg "ERROR" "Could not upload the cycle log: ${upload_error:-unknown error}"
            log_msg "WARN" "Keeping local log: $local_log"
            LOCAL_LOG_FILE=""   # keep the file; do not let the EXIT trap delete it
            CYCLE_ISSUES=$(( CYCLE_ISSUES + 1 ))
        fi
    else
        LOCAL_LOG_FILE=""
    fi

    return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

LOCAL_LOG_FILE=""
LIVE_LOG_SNAPSHOT=""
LOG_HEARTBEAT_PID=""
LOCK_PID=""
LOCK_HB_ERR_FILE=""
LOCK_HB_ERROR_FLAG=""
CYCLE_FAILURES=0
CYCLE_ISSUES=0
CYCLE_FAILED_LABELS=()
CYCLE_FAILED_SUMMARY=()

cleanup() {
    stop_lock_heartbeat

    if [[ -n "${LOG_HEARTBEAT_PID:-}" ]]; then
        kill "$LOG_HEARTBEAT_PID" 2>/dev/null
        wait "$LOG_HEARTBEAT_PID" 2>/dev/null
        LOG_HEARTBEAT_PID=""
    fi

    if [[ -n "${LOCAL_LOG_FILE:-}" ]]; then
        rm -f "$LOCAL_LOG_FILE"
        LOCAL_LOG_FILE=""
    fi

    if [[ -n "${LIVE_LOG_SNAPSHOT:-}" ]]; then
        rm -f "$LIVE_LOG_SNAPSHOT"
        LIVE_LOG_SNAPSHOT=""
    fi

    if [[ -n "${LOCK_HB_ERR_FILE:-}" ]]; then
        rm -f "$LOCK_HB_ERR_FILE"
    fi

    if [[ -n "${LOCK_HB_ERROR_FLAG:-}" ]]; then
        rm -f "$LOCK_HB_ERROR_FLAG"
    fi

    command -v termux-wake-unlock >/dev/null && termux-wake-unlock
}

# Clean up on Ctrl+C / SIGTERM so the remote lock is always removed
trap 'echo -e "\n"; log_msg "WARN" "Interrupted. Cleaning up…"; cleanup; exit 0' INT TERM
trap 'cleanup' EXIT

# Hold a wake-lock to ensure the CPU doesn't sleep in the background
# BATTERY SAVER: Comment out the line below to let CPU sleep (saves battery, but timing becomes less accurate)
command -v termux-wake-lock >/dev/null && termux-wake-lock

# Ask the user about --resync before entering the loop
select_resync_remotes

FIRST_RUN=true
CYCLE=0

while true; do
    (( CYCLE++ ))

    CYCLE_FAILURES=0
    CYCLE_ISSUES=0
    CYCLE_FAILED_LABELS=()
    CYCLE_FAILED_SUMMARY=()

    # ── Wait for exclusive sync lock ─────────────────────────────────────────
    timestamp=$(date '+%H:%M:%S')
    echo -e "\n${CLR_BOLD}━━━━ Cycle #${CYCLE} (${timestamp})${CLR_RESET}"

    if wait_for_lock; then
        start_lock_heartbeat

        # ── Run syncs ────────────────────────────────────────────────────────
        log_msg "INFO" "Starting sync pass..."
        run_sync_cycle "$FIRST_RUN"
        FIRST_RUN=false

        # ── Release lock ─────────────────────────────────────────────────────
        stop_lock_heartbeat

        if (( CYCLE_FAILURES == 0 && CYCLE_ISSUES == 0 )); then
            log_msg "SUCCESS" "Cycle #${CYCLE} completed."
        elif (( CYCLE_FAILURES == 0 )); then
            log_msg "WARN" "Cycle #${CYCLE} completed with warnings. See the messages above."
            notify "MobileSync warning" "Cycle #${CYCLE} completed with warnings. Check the terminal."
        else
            log_msg "ERROR" "Cycle #${CYCLE} finished with ${CYCLE_FAILURES}/${#REMOTE_NAMES[@]} remotes failing."
            for summary in "${CYCLE_FAILED_SUMMARY[@]}"; do
                log_msg "ERROR" "  ✗ ${summary}"
            done

            if (( CYCLE_ISSUES > 0 )); then
                log_msg "WARN" "Additional lock/log errors occurred during this cycle."
            fi

            notify "MobileSync error" "Cycle #${CYCLE}: ${CYCLE_FAILURES}/${#REMOTE_NAMES[@]} remotes failed: ${CYCLE_FAILED_LABELS[*]}"
        fi
    else
        log_msg "ERROR" "Cycle #${CYCLE} skipped: the remote lock could not be checked."
        notify "MobileSync error" "Cycle #${CYCLE} skipped: remote lock unavailable. Retrying in ${SYNC_INTERVAL} seconds."
    fi

    echo -e ""
    UI_PAUSED=false
    for (( i=SYNC_INTERVAL; i>0; i-- )); do
        if [[ "$UI_PAUSED" == "false" ]]; then
            if [[ -t 1 ]]; then
                printf "\r${CLR_DIM}Next cycle in: %3d seconds... ${CLR_RESET}" "$i"
                echo -ne "\n${CLR_ITALIC}(Press 'S' to sync, 'P' to pause UI and scroll)${CLR_RESET}\n"
            else
                printf "${CLR_DIM}Next cycle in: %3d seconds... ${CLR_RESET}\n" "$i"
            fi
        fi

        # Wait 1 second for a character. -t 1 is the timeout, -n 1 is one
        # character. If stdin is not a terminal (nohup, pipe, service), read
        # returns immediately and the countdown would be skipped.
        key=""
        if [[ -t 0 ]]; then
            read -t 1 -n 1 key
        else
            sleep 1
        fi

        if [[ "$UI_PAUSED" == "false" && -t 1 ]]; then
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
    if [[ "$UI_PAUSED" == "false" && $i -le 0 && -t 1 ]]; then
         echo -ne "\r\033[K\n\033[K\033[F"
    fi
    echo -e "\n\r${CLR_SUCCESS}🚀 Starting next cycle!          ${CLR_RESET}"
done
