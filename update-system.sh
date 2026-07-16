#!/usr/bin/env bash

# ============================================================
# Fedora Update Script (DNF + Flatpak + Firmware)  -  v3
#
#   - Package summaries via rpm/flatpak snapshot diffs (no
#     console-output parsing; immune to dnf5/flatpak format churn)
#   - Firmware detail via 'fwupdmgr get-updates --json'
#     (device name + old -> new version, no output scraping)
#   - Machine-readable sidecar (update-STAMP.summary) consumed
#     by rich_update_viewer.py
#   - Log rotation: keeps newest KEEP_RUNS log+summary pairs
#   - Auto-launches the rich viewer at the end (TTY only)
#   - fwupd progress spam filtered from screen and log
#   - Reboot detection (kernel + core userspace)
#   - Per-step timing; long lists truncated on screen
#
# Logs:    ~/.local/share/system-updates/update-YYYYmmdd-HHMMSS.log
# Summary: ~/.local/share/system-updates/update-YYYYmmdd-HHMMSS.summary
#
# Flags:
#   --security   : DNF security-only updates instead of full upgrade
#   --dry-run    : Simulate DNF (no changes) using --assumeno
#   --cleanup    : Run dnf autoremove after the upgrade
#   --no-view    : Skip launching the rich viewer at the end
# ============================================================

set -euo pipefail

# ----------------------------
# 0. CLI options & config
# ----------------------------
SECURITY_ONLY=0
DRY_RUN=0
CLEANUP=0
NO_VIEW=0

KEEP_RUNS=45   # log+summary pairs to retain
MAX_LIST=15    # packages shown per list on screen (full list in sidecar)

for arg in "$@"; do
    case "$arg" in
        --security) SECURITY_ONLY=1 ;;
        --dry-run)  DRY_RUN=1 ;;
        --cleanup)  CLEANUP=1 ;;
        --no-view)  NO_VIEW=1 ;;
        -h|--help)
            echo "Usage: $0 [--security] [--dry-run] [--cleanup] [--no-view]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--security] [--dry-run] [--cleanup] [--no-view]" >&2
            exit 2
            ;;
    esac
done

# Colors & symbols
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

TICK="${GREEN}✔${RESET}"
CROSS="${RED}✘${RESET}"
SKIP="${YELLOW}⏭${RESET}"
ARROW="${CYAN}→${RESET}"

LOG_DIR="$HOME/.local/share/system-updates"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/update-$STAMP.log"
SUM_FILE="$LOG_DIR/update-$STAMP.summary"
VIEWER="$HOME/scripts/update_script/rich_update_viewer.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------
# Cinematic pacing (interactive terminals only; instant when
# piped/cron so logs stay clean and automation stays fast)
# ------------------------------------------------------------
FX=0
[ -t 1 ] && FX=1

fx_sleep() {
    [ "$FX" -eq 1 ] && sleep "$1"
    return 0
}

fx_init_line() {
    # "Initializing package matrix" with typed dots and a
    # blinking final dot before it locks in
    printf "%s" "${CYAN}Initializing package matrix${RESET}"
    if [ "$FX" -eq 1 ]; then
        sleep 0.35; printf "%s" "${CYAN}.${RESET}"
        sleep 0.35; printf "%s" "${CYAN}.${RESET}"
        sleep 0.35
        local i
        for i in 1 2 3; do
            printf "%s" "${CYAN}.${RESET}"
            sleep 0.30
            printf "\b \b"
            sleep 0.20
        done
        printf "%s\n" "${CYAN}.${RESET}"
    else
        printf "%s\n" "${CYAN}...${RESET}"
    fi
}

fx_type() {
    # Typewriter print, no trailing newline: fx_type <color> <text>
    local color="$1" text="$2"
    printf "%s" "$color"
    if [ "$FX" -eq 1 ]; then
        local i
        for (( i=0; i<${#text}; i++ )); do
            printf "%s" "${text:i:1}"
            sleep 0.022
        done
    else
        printf "%s" "$text"
    fi
    printf "%s" "$RESET"
}

fx_channel() {
    # "  · LABEL ......... [ LINKED ]" with animated dot leader
    local label="$1"
    local width=24
    local dots=$(( width - ${#label} ))
    [ "$dots" -lt 3 ] && dots=3
    printf "  %s%s%s " "$CYAN" "· $label" "$RESET"
    if [ "$FX" -eq 1 ]; then
        local i
        for (( i=0; i<dots; i++ )); do
            printf "%s.%s" "$DIM" "$RESET"
            sleep 0.06
        done
        sleep 0.30
    else
        printf "%s" "$DIM"
        printf '%*s' "$dots" '' | tr ' ' '.'
        printf "%s" "$RESET"
    fi
    printf " %s[ LINKED ]%s\n" "$GREEN" "$RESET"
}

fx_cursor_blink() {
    # Blinking block cursor, then erased (interactive only)
    [ "$FX" -eq 1 ] || return 0
    local i
    for i in 1 2 3; do
        printf "%s█%s" "$GREEN" "$RESET"
        sleep 0.25
        printf "\b \b"
        sleep 0.18
    done
}

fx_sync_box() {
    # SYNC art: letters decrypt out of random glyphs and lock in
    # left to right, then "channel uplink" resolves from noise.
    # Static box when non-interactive.
    local pad="             "
    if [ "$FX" -eq 0 ]; then
        echo -e "${CYAN}${pad}.━━━━━━━━━━━━━━━━━━━━━━.${RESET}"
        echo -e "${CYAN}${pad}|  _   _   _   _       |${RESET}"
        echo -e "${CYAN}${pad}| / \\ / \\ / \\ / \\      |${RESET}"
        echo -e "${CYAN}${pad}|( S | Y | N | C )     |${RESET}"
        echo -e "${CYAN}${pad}| \\_/ \\_/ \\_/ \\_/      |${RESET}"
        echo -e "${CYAN}${pad}|   channel uplink     |${RESET}"
        echo -e "${CYAN}${pad}'━━━━━━━━━━━━━━━━━━━━━━'${RESET}"
        return 0
    fi

    local glyphs='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#$%&*+=?'
    local nglyphs=${#glyphs}
    local target=(S Y N C)
    local cur=("?" "?" "?" "?")
    local locked=(0 0 0 0)

    _sync_row() {
        local out="${pad}${CYAN}|(${RESET}" i
        for i in 0 1 2 3; do
            if [ "${locked[i]}" -eq 1 ]; then
                out+=" ${BOLD}${GREEN}${target[i]}${RESET} "
            else
                out+=" ${DIM}${cur[i]}${RESET} "
            fi
            [ "$i" -lt 3 ] && out+="${CYAN}|${RESET}"
        done
        out+="${CYAN})     |${RESET}"
        printf "\r%s" "$out"
    }

    echo -e "${CYAN}${pad}.━━━━━━━━━━━━━━━━━━━━━━.${RESET}"
    echo -e "${CYAN}${pad}|  _   _   _   _       |${RESET}"
    echo -e "${CYAN}${pad}| / \\ / \\ / \\ / \\      |${RESET}"

    local frame i lockidx=0
    for frame in $(seq 1 16); do
        for i in 0 1 2 3; do
            [ "${locked[i]}" -eq 0 ] && cur[i]="${glyphs:$(( RANDOM % nglyphs )):1}"
        done
        if [ $(( frame % 4 )) -eq 0 ] && [ "$lockidx" -lt 4 ]; then
            locked[lockidx]=1
            lockidx=$(( lockidx + 1 ))
        fi
        _sync_row
        sleep 0.08
    done
    _sync_row
    printf "\n"

    echo -e "${CYAN}${pad}| \\_/ \\_/ \\_/ \\_/      |${RESET}"

    local text="channel uplink"
    local n=${#text} k j noise out
    for (( k=0; k<=n; k++ )); do
        noise=""
        for (( j=k; j<n; j++ )); do
            noise+="${glyphs:$(( RANDOM % nglyphs )):1}"
        done
        out="${pad}${CYAN}|${RESET}   ${GREEN}${text:0:k}${RESET}${DIM}${noise}${RESET}${CYAN}     |${RESET}"
        printf "\r%s" "$out"
        sleep 0.06
    done
    printf "\n"

    echo -e "${CYAN}${pad}'━━━━━━━━━━━━━━━━━━━━━━'${RESET}"
    fx_sleep 0.30
}

SUCCESS_STEPS=()
FAILED_STEPS=()
SKIPPED_STEPS=()

section_header() {
    local title="$1"
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}  $title${RESET}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" | tee -a "$LOG_FILE"
}

# log_run <label> [--filter <ERE>] <cmd...>
#
# Terminal-aware: if the command prints anything, the first line is
# pushed onto a fresh line (so it never lands on the "  -> label" stub),
# all output is indented, and the label stub is re-printed afterwards
# so the caller's done/FAILED still lands aligned.
log_run() {
    local label="$1"; shift
    local filter=""
    if [ "${1:-}" = "--filter" ]; then
        filter="$2"; shift 2
    fi
    {
        echo ""
        echo "[$(date '+%F %T')] $label"
        echo "CMD: $*"
    } >> "$LOG_FILE"
    local flag rc
    flag=$(mktemp)
    if [ -n "$filter" ]; then
        "$@" 2>&1 | grep --line-buffered -vE "$filter" | tee -a "$LOG_FILE" \
            | awk -v f="$flag" 'NR==1 { printf "\n"; print "x" > f; close(f) } { print "      " $0; fflush() }'
        rc="${PIPESTATUS[0]}"
    else
        "$@" 2>&1 | tee -a "$LOG_FILE" \
            | awk -v f="$flag" 'NR==1 { printf "\n"; print "x" > f; close(f) } { print "      " $0; fflush() }'
        rc="${PIPESTATUS[0]}"
    fi
    if [ -s "$flag" ]; then
        printf "  %s %-44s" "$ARROW" "$label"
    fi
    rm -f "$flag"
    return "$rc"
}

log_since_line_has() {
    tail -n "+$(($1 + 1))" "$LOG_FILE" | grep -Eq "$2"
}

get_log_line_count() {
    wc -l < "$LOG_FILE"
}

rpm_snapshot() {
    rpm -qa --qf '%{NAME}.%{ARCH} %{EVR}\n' | LC_ALL=C sort
}

flatpak_snapshot() {
    flatpak list --columns=ref,active 2>/dev/null | awk '{print $1, $2}' | LC_ALL=C sort
}

# print_list <color> <array-name>  (entries: "key old new" or "key ver")
print_list() {
    local color="$1"
    local -n _arr="$2"
    local shown=0
    local total="${#_arr[@]}"
    local entry key old new
    for entry in "${_arr[@]}"; do
        shown=$((shown + 1))
        if [ "$shown" -gt "$MAX_LIST" ]; then
            echo -e "      ${DIM}… and $((total - MAX_LIST)) more (run 'update-view' or see log)${RESET}"
            break
        fi
        read -r key old new <<< "$entry"
        if [ -n "${new:-}" ]; then
            echo -e "      ${color}•${RESET} $key ${DIM}$old →${RESET} $new"
        else
            echo -e "      ${color}•${RESET} $key ${DIM}$old${RESET}"
        fi
    done
}

# ------------------------------------------------------------
# Banner (shown before any sudo prompt)
# ------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}+━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━+${RESET}"
echo -e "${BOLD}${CYAN}|                  SYSTEM UPDATE                   |${RESET}"
echo -e "${BOLD}${CYAN}+━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━+${RESET}"
fx_init_line
fx_sync_box
fx_sleep 0.45
echo ""
fx_type "${BOLD}${CYAN}" "> ESTABLISHING UPLINK"
echo ""
fx_sleep 0.30
fx_channel "DNF"
fx_channel "Flatpak"
fx_channel "Firmware (LVFS)"
fx_sleep 0.40
fx_type "${BOLD}${CYAN}" "> HANDSHAKE ACCEPTED"
echo ""
fx_sleep 0.55
fx_type "${BOLD}${GREEN}" "> ACCESS GRANTED :: WE'RE IN "
fx_cursor_blink
echo ""
echo ""
fx_sleep 0.35
echo -e "  ${ARROW} ${BOLD}Sudo access is required${RESET}; password prompt incoming."
echo ""

# ============================================================
# [ 0/3 ] Pre-flight
# ============================================================
section_header "[ 0/3 ] Pre-flight Health Check"

echo -n "  ${ARROW} sudo auth check                             "
SUDO_PROMPTED=0
if ! sudo -n true 2>/dev/null; then
    # Password required; sudo prompts on the TTY, so give it its
    # own line and re-print the label stub once auth completes.
    SUDO_PROMPTED=1
    echo ""
fi
if log_run "Sudo auth check" sudo -v; then
    SUCCESS_STEPS+=("Sudo auth check")
    [ "$SUDO_PROMPTED" -eq 1 ] && printf "  %s %-44s" "$ARROW" "sudo auth check"
    echo -e "${GREEN}ok${RESET}"
else
    FAILED_STEPS+=("Sudo auth check")
    [ "$SUDO_PROMPTED" -eq 1 ] && printf "  %s %-44s" "$ARROW" "sudo auth check"
    echo -e "${RED}FAILED${RESET}"
    echo -e "  ${RED}Could not obtain sudo credentials. Aborting updates.${RESET}"
    exit 1
fi

echo -n "  ${ARROW} dnf check (rpmdb sanity)                    "
if log_run "DNF pre-flight check" sudo dnf check; then
    SUCCESS_STEPS+=("DNF pre-flight check")
    echo -e "${GREEN}ok${RESET}"
else
    FAILED_STEPS+=("DNF pre-flight check")
    echo -e "${RED}FAILED${RESET}"
    echo -e "  ${RED}Pre-flight check failed; see log. Aborting updates.${RESET}"
    exit 1
fi

# Snapshots BEFORE anything changes
rpm_snapshot     > "$WORK/rpm_before"
flatpak_snapshot > "$WORK/fp_before" || true

# ============================================================
# [ 1/3 ] DNF System Packages
# ============================================================
section_header "[ 1/3 ] DNF System Packages"

DNF_CMD=(sudo dnf upgrade --refresh -y)
DNF_LABEL="DNF upgrade"

if [ "$SECURITY_ONLY" -eq 1 ]; then
    DNF_CMD=(sudo dnf upgrade --security --refresh -y)
    DNF_LABEL="DNF security update"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    DNF_CMD+=("--assumeno")
    DNF_LABEL="$DNF_LABEL (dry-run)"
fi

STEP_T0=$SECONDS
echo -e "  ${ARROW} ${DNF_LABEL}"
DNF_LOG_START="$(get_log_line_count)"
if log_run "$DNF_LABEL" "${DNF_CMD[@]}"; then
    SUCCESS_STEPS+=("DNF packages")
    echo -e "  ${TICK} DNF ${GREEN}done${RESET} ${DIM}($((SECONDS - STEP_T0))s)${RESET}"
else
    if [ "$DRY_RUN" -eq 1 ] && \
       log_since_line_has "$DNF_LOG_START" 'Operation aborted\.|Nothing to do\.|No packages marked for'; then
        SKIPPED_STEPS+=("DNF packages (dry-run simulation)")
        echo -e "  ${SKIP} DNF ${YELLOW}skipped${RESET} (simulation complete)"
    else
        FAILED_STEPS+=("DNF packages")
        echo -e "  ${CROSS} DNF ${RED}FAILED${RESET}"
    fi
fi

# Cleanup BEFORE the after-snapshot so its removals land in the diff
if [ "$CLEANUP" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo -n "  ${ARROW} dnf autoremove (cleanup)                    "
    if log_run "DNF autoremove" sudo dnf autoremove -y; then
        SUCCESS_STEPS+=("DNF cleanup")
        echo -e "${GREEN}done${RESET}"
    else
        FAILED_STEPS+=("DNF cleanup")
        echo -e "${RED}FAILED${RESET}"
    fi
fi

# ---- DNF change summary from rpm snapshot diff ----
rpm_snapshot > "$WORK/rpm_after"
LC_ALL=C comm -23 "$WORK/rpm_before" "$WORK/rpm_after" > "$WORK/rpm_gone"
LC_ALL=C comm -13 "$WORK/rpm_before" "$WORK/rpm_after" > "$WORK/rpm_new"

declare -A GONE_VER NEW_VER
while read -r k v; do [ -n "$k" ] && GONE_VER["$k"]="$v"; done < "$WORK/rpm_gone"
while read -r k v; do [ -n "$k" ] && NEW_VER["$k"]="$v";  done < "$WORK/rpm_new"

DNF_UPG=()   # "key oldver newver"
DNF_INS=()   # "key ver"
DNF_REM=()   # "key ver"

for k in "${!NEW_VER[@]}"; do
    if [[ -v GONE_VER[$k] ]]; then
        DNF_UPG+=("$k ${GONE_VER[$k]} ${NEW_VER[$k]}")
    else
        DNF_INS+=("$k ${NEW_VER[$k]}")
    fi
done
for k in "${!GONE_VER[@]}"; do
    [[ -v NEW_VER[$k] ]] || DNF_REM+=("$k ${GONE_VER[$k]}")
done

if [ "${#DNF_UPG[@]}" -gt 0 ]; then mapfile -t DNF_UPG < <(printf '%s\n' "${DNF_UPG[@]}" | LC_ALL=C sort); fi
if [ "${#DNF_INS[@]}" -gt 0 ]; then mapfile -t DNF_INS < <(printf '%s\n' "${DNF_INS[@]}" | LC_ALL=C sort); fi
if [ "${#DNF_REM[@]}" -gt 0 ]; then mapfile -t DNF_REM < <(printf '%s\n' "${DNF_REM[@]}" | LC_ALL=C sort); fi

DNF_CHANGED=$(( ${#DNF_UPG[@]} + ${#DNF_INS[@]} + ${#DNF_REM[@]} ))

if [ "$DNF_CHANGED" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    SKIPPED_STEPS+=("DNF packages (no changes)")
fi

# Archive the authoritative transaction record (not parsed)
if [ "$DNF_CHANGED" -gt 0 ]; then
    {
        echo ""
        echo "===== DNF HISTORY (last transaction) ====="
        sudo dnf history info last 2>&1 || true
    } >> "$LOG_FILE"
fi

# ============================================================
# [ 2/3 ] Flatpak Apps
# ============================================================
section_header "[ 2/3 ] Flatpak Apps"

FLATPAK_UPDATES=()

if command -v flatpak >/dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
    STEP_T0=$SECONDS
    echo -n "  ${ARROW} Flatpak update                              "
    if log_run "Flatpak update" flatpak update -y --noninteractive; then
        SUCCESS_STEPS+=("Flatpak apps")
        echo -e "${GREEN}done${RESET} ${DIM}($((SECONDS - STEP_T0))s)${RESET}"
    else
        FAILED_STEPS+=("Flatpak apps")
        echo -e "${RED}FAILED${RESET}"
    fi

    flatpak_snapshot > "$WORK/fp_after" || true
    while read -r ref _; do
        [ -n "$ref" ] && FLATPAK_UPDATES+=("$ref")
    done < <(LC_ALL=C comm -13 "$WORK/fp_before" "$WORK/fp_after")

    if [ "${#FLATPAK_UPDATES[@]}" -eq 0 ]; then
        SKIPPED_STEPS+=("Flatpak (no changes)")
    fi
elif command -v flatpak >/dev/null 2>&1 && [ "$DRY_RUN" -eq 1 ]; then
    SKIPPED_STEPS+=("Flatpak apps (dry-run)")
    echo -e "  ${ARROW} Flatpak update                              ${YELLOW}skipped${RESET} (dry-run)"
else
    SKIPPED_STEPS+=("Flatpak apps (flatpak not installed)")
    echo -e "  ${ARROW} Flatpak update                              ${YELLOW}skipped${RESET} (flatpak not installed)"
fi

# ============================================================
# [ 3/3 ] Firmware (fwupd)
# ============================================================
section_header "[ 3/3 ] Firmware (fwupd)"

FWU_STATUS="not run"
FWU_UPDATES=()   # "DeviceName|old|new"
FWU_FILTER='^(Downloading…|Idle…|Waiting…|Verifying…|Decompressing…|Writing…|Restarting device…)'

if command -v fwupdmgr >/dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
    echo -n "  ${ARROW} fwupdmgr refresh                            "
    if log_run "fwupdmgr refresh" --filter "$FWU_FILTER" sudo fwupdmgr refresh --force; then
        echo -e "${GREEN}done${RESET}"
    else
        echo -e "${YELLOW}skipped${RESET} (refresh failed, continuing)"
    fi

    # Structured list of pending firmware updates (device|old|new).
    # get-updates exits non-zero when nothing is updatable; that is fine.
    echo -n "  ${ARROW} fwupdmgr get-updates                        "
    sudo fwupdmgr get-updates --json > "$WORK/fw_pending.json" 2>>"$LOG_FILE" || true
    {
        echo ""
        echo "[$(date '+%F %T')] fwupdmgr get-updates --json"
        cat "$WORK/fw_pending.json" 2>/dev/null || echo "(no output)"
    } >> "$LOG_FILE"

    python3 - "$WORK/fw_pending.json" > "$WORK/fw_pending" 2>/dev/null <<'PYEOF' || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
for dev in data.get("Devices", []):
    rels = dev.get("Releases") or []
    new = rels[0].get("Version", "?") if rels else "?"
    name = dev.get("Name", "?").replace("|", "/")
    old = dev.get("Version", "?")
    print(name + "|" + old + "|" + new)
PYEOF

    while IFS= read -r line; do
        [ -n "$line" ] && FWU_UPDATES+=("$line")
    done < "$WORK/fw_pending"
    echo -e "${GREEN}done${RESET} ${DIM}(${#FWU_UPDATES[@]} device(s) pending)${RESET}"

    if [ "${#FWU_UPDATES[@]}" -gt 0 ]; then
        echo -n "  ${ARROW} fwupdmgr update                             "
        if log_run "fwupdmgr update" --filter "$FWU_FILTER" sudo fwupdmgr update -y; then
            SUCCESS_STEPS+=("Firmware")
            FWU_STATUS="updated (${#FWU_UPDATES[@]} device(s))"
            echo -e "${GREEN}done${RESET}"
        else
            FAILED_STEPS+=("Firmware")
            FWU_STATUS="update failed (see log)"
            echo -e "${RED}FAILED${RESET}"
        fi
    else
        SKIPPED_STEPS+=("Firmware (no updates)")
        FWU_STATUS="no updates available"
        echo -e "  ${ARROW} fwupdmgr update                             ${YELLOW}skipped${RESET} (no updates)"
    fi
elif command -v fwupdmgr >/dev/null 2>&1 && [ "$DRY_RUN" -eq 1 ]; then
    SKIPPED_STEPS+=("Firmware (dry-run)")
    FWU_STATUS="dry-run (not executed)"
    echo -e "  ${ARROW} Firmware update                             ${YELLOW}skipped${RESET} (dry-run)"
else
    SKIPPED_STEPS+=("Firmware (fwupdmgr not installed)")
    FWU_STATUS="fwupdmgr not installed"
    echo -e "  ${ARROW} Firmware update                             ${YELLOW}skipped${RESET} (fwupdmgr not installed)"
fi

# ============================================================
# Reboot detection
# ============================================================
REBOOT_REASON=""

RUNNING_KERNEL="$(uname -r)"
NEWEST_KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -n1 || true)"
if [ -n "$NEWEST_KERNEL" ] && [ "$NEWEST_KERNEL" != "$RUNNING_KERNEL" ]; then
    REBOOT_REASON="kernel $RUNNING_KERNEL → $NEWEST_KERNEL"
fi

for core in glibc systemd dbus-broker openssl-libs; do
    if [ "${#DNF_UPG[@]}" -gt 0 ] && printf '%s\n' "${DNF_UPG[@]}" | grep -q "^${core}\."; then
        REBOOT_REASON="${REBOOT_REASON:+$REBOOT_REASON; }$core upgraded"
    fi
done

# Firmware updates frequently require a reboot to apply
if [[ "$FWU_STATUS" == updated* ]]; then
    REBOOT_REASON="${REBOOT_REASON:+$REBOOT_REASON; }firmware staged"
fi

# ============================================================
# Machine-readable sidecar (consumed by rich_update_viewer.py)
# ============================================================
HEALTH="OK"
[ "${#FAILED_STEPS[@]}" -gt 0 ] && HEALTH="ATTENTION"

{
    echo "meta|timestamp|$(date '+%Y-%m-%d %H:%M:%S')"
    echo "meta|log|$LOG_FILE"
    echo "meta|health|$HEALTH"
    echo "meta|reboot|${REBOOT_REASON:-none}"
    echo "meta|firmware|$FWU_STATUS"
    for e in "${DNF_UPG[@]}";  do read -r k o n <<< "$e"; echo "dnf_upg|$k|$o|$n"; done
    for e in "${DNF_INS[@]}";  do read -r k v   <<< "$e"; echo "dnf_ins|$k|$v"; done
    for e in "${DNF_REM[@]}";  do read -r k v   <<< "$e"; echo "dnf_rem|$k|$v"; done
    for a in "${FLATPAK_UPDATES[@]}"; do echo "flatpak|$a"; done
    for f in "${FWU_UPDATES[@]}";     do echo "fw_upd|$f"; done
    for s in "${SUCCESS_STEPS[@]}"; do echo "step_ok|$s"; done
    for s in "${SKIPPED_STEPS[@]}"; do echo "step_skip|$s"; done
    for s in "${FAILED_STEPS[@]}";  do echo "step_fail|$s"; done
} > "$SUM_FILE"

# ============================================================
# Decide output mode: rich viewer replaces the plain summary
# ============================================================
WILL_VIEW=0
if [ "$NO_VIEW" -eq 0 ] && [ -t 1 ] && [ -f "$VIEWER" ] \
   && python3 -c 'import rich' 2>/dev/null; then
    WILL_VIEW=1
fi

# ============================================================
# Plain summary (fallback only: --no-view, piped/cron, no rich)
# ============================================================
if [ "$WILL_VIEW" -eq 0 ]; then
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}${CYAN}  Update Summary  •  $(date '+%Y-%m-%d %H:%M')${RESET}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Log file: ${DIM}$LOG_FILE${RESET}"
    echo -e "  Summary : ${DIM}$SUM_FILE${RESET}"
    echo ""

    printf "  ${TICK}  ${BOLD}Steps OK${RESET}     : ${GREEN}%d${RESET}\n"  "${#SUCCESS_STEPS[@]}"
    printf "  ${SKIP}  ${BOLD}Steps Skipped${RESET}: ${YELLOW}%d${RESET}\n" "${#SKIPPED_STEPS[@]}"
    printf "  ${CROSS}  ${BOLD}Steps Failed${RESET} : ${RED}%d${RESET}\n"   "${#FAILED_STEPS[@]}"

    echo ""
    echo -e "  ${BOLD}DNF (system packages)${RESET}  ${DIM}${#DNF_UPG[@]} upgraded, ${#DNF_INS[@]} installed, ${#DNF_REM[@]} removed${RESET}"
    if [ "$DNF_CHANGED" -eq 0 ]; then
        echo -e "    ${DIM}No package changes in this run.${RESET}"
    else
        if [ "${#DNF_UPG[@]}" -gt 0 ]; then
            echo -e "    ${GREEN}Upgraded:${RESET}"
            print_list "$GREEN" DNF_UPG
        fi
        if [ "${#DNF_INS[@]}" -gt 0 ]; then
            echo -e "    ${CYAN}Installed:${RESET}"
            print_list "$CYAN" DNF_INS
        fi
        if [ "${#DNF_REM[@]}" -gt 0 ]; then
            echo -e "    ${YELLOW}Removed:${RESET}"
            print_list "$YELLOW" DNF_REM
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Flatpak${RESET}  ${DIM}${#FLATPAK_UPDATES[@]} updated${RESET}"
    if [ "${#FLATPAK_UPDATES[@]}" -gt 0 ]; then
        for a in "${FLATPAK_UPDATES[@]}"; do
            echo -e "      ${GREEN}•${RESET} $a"
        done
    else
        echo -e "    ${DIM}No Flatpak changes in this run.${RESET}"
    fi

    echo ""
    echo -e "  ${BOLD}Firmware (fwupd)${RESET}  ${DIM}$FWU_STATUS${RESET}"
    if [ "${#FWU_UPDATES[@]}" -gt 0 ]; then
        for f in "${FWU_UPDATES[@]}"; do
            IFS='|' read -r dev old new <<< "$f"
            echo -e "      ${GREEN}•${RESET} $dev ${DIM}$old →${RESET} $new"
        done
    fi

    if [ -n "$REBOOT_REASON" ]; then
        echo ""
        echo -e "  ${RED}${BOLD}Reboot recommended:${RESET} $REBOOT_REASON"
    fi

    if [ "${#SKIPPED_STEPS[@]}" -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}${BOLD}Skipped steps:${RESET}"
        for s in "${SKIPPED_STEPS[@]}"; do
            echo -e "    ${SKIP}  ${DIM}$s${RESET}"
        done
    fi

    if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
        echo ""
        echo -e "  ${RED}${BOLD}Failed steps:${RESET}"
        for f in "${FAILED_STEPS[@]}"; do
            echo -e "    ${CROSS}  ${RED}$f${RESET}"
        done
    fi
fi

# ============================================================
# Log rotation: keep the newest KEEP_RUNS runs
# ============================================================
PRUNED=0
while read -r old_log; do
    rm -f -- "$old_log" "${old_log%.log}.summary"
    PRUNED=$((PRUNED + 1))
done < <(ls -1t "$LOG_DIR"/update-*.log 2>/dev/null | tail -n "+$((KEEP_RUNS + 1))")
if [ "$PRUNED" -gt 0 ]; then
    echo -e "  ${DIM}Pruned $PRUNED old update log(s); keeping last $KEEP_RUNS.${RESET}"
fi

# ============================================================
# Hand off to the rich report
# ============================================================
if [ "$WILL_VIEW" -eq 1 ]; then
    echo ""
    echo -e "  ${TICK} ${BOLD}All steps complete${RESET} ${DIM}• rendering report…${RESET}"
    python3 "$VIEWER" "$SUM_FILE"
else
    echo ""
fi
