#!/usr/bin/env bash
# Progress display library for snapMULTI auto-install.
#
# Provides a full-screen TUI on /dev/tty1 (HDMI console) with:
#   - ASCII progress bar with weighted percentages
#   - Step checklist ([x] done, [>] current, [ ] pending)
#   - Animated spinner for long-running operations
#   - Live log output area (last 8 lines)
#   - Elapsed time tracking
#
# The caller sets STEP_NAMES and STEP_WEIGHTS arrays before sourcing.
#
# Usage:
#   STEP_NAMES=("Network" "Docker" "Deploy")
#   STEP_WEIGHTS=(5 35 60)
#   source scripts/common/progress.sh
#   progress_init
#   progress 1 "Waiting for network..."
#   start_progress_animation 1 0 5
#   ...
#   progress_complete

# Use monotonic counter (clock may be wrong on first boot)
PROGRESS_START_MONO=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
PROGRESS_ANIM_PID=""

# Title displayed in the TUI header (can be overridden before progress_init)
PROGRESS_TITLE="${PROGRESS_TITLE:-snapMULTI Auto-Install}"

# Default steps — fallback for standalone testing only.
# Callers (firstboot.sh) always set STEP_NAMES/STEP_WEIGHTS before sourcing.
if [[ ${#STEP_NAMES[@]} -eq 0 ]]; then
    STEP_NAMES=("Network connectivity" "Copy project files" "Install Docker"
                "Deploy & pull images" "Verify containers")
    STEP_WEIGHTS=(5 2 35 50 8)
fi

# Log file for capturing output to display
PROGRESS_LOG="/tmp/snapmulti-progress.log"

progress_init() {
    : > "$PROGRESS_LOG"

    # On HD screens the default 8x16 font yields 240 columns — far too small.
    # Uni3-TerminusBold28x14 gives ~137 cols x 38 rows on 1080p, enough
    # for the 74-char wide TUI layout.
    if [[ -c /dev/tty1 ]]; then
        local fb_width
        fb_width=$(cut -d, -f1 /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo 0)
        if (( fb_width > 1000 )); then
            setfont Uni3-TerminusBold28x14 -C /dev/tty1 2>/dev/null || true
        fi
    fi
}

# Render progress display to tty1
render_progress() {
    local step=$1 pct=$2 elapsed=$3 spinner=${4:-}
    local total=${#STEP_NAMES[@]}

    [[ -c /dev/tty1 ]] || return

    # Clamp pct to 0-100
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100

    # Build progress bar (50 chars wide)
    local bar_width=50
    local filled=$(( pct * bar_width / 100 ))
    local empty=$(( bar_width - filled ))
    local bar pad
    printf -v bar '%*s' "$filled" ''; bar="${bar// /#}"
    printf -v pad '%*s' "$empty" ''; bar+="${pad// /-}"

    # Get last 8 lines of log for output area
    local log_lines=""
    if [[ -f "$PROGRESS_LOG" ]]; then
        log_lines=$(tail -8 "$PROGRESS_LOG" 2>/dev/null | cut -c1-68 || true)
    fi

    {
        printf '\033[2J\033[H'
        printf '\n'
        printf '  +----------------------------------------------------------------------+\n'
        # Box interior = 70 chars: 21 leading spaces + 38 title field + 11 trailing spaces
        printf '  |                     \033[1m%-38.38s\033[0m           |\n' "$PROGRESS_TITLE"
        printf '  +----------------------------------------------------------------------+\n'
        printf '\n'
        printf '  \033[36mElapsed: %02d:%02d\033[0m\n\n' $((elapsed/60)) $((elapsed%60))
        printf '  \033[33m[%s]\033[0m %3d%% %s\n\n' "$bar" "$pct" "$spinner"
        for i in $(seq 1 "$total"); do
            local name="${STEP_NAMES[$((i-1))]}"
            if (( i < step )); then   printf '  \033[32m[x]\033[0m %s\n' "$name"
            elif (( i == step )); then printf '  \033[33m[>]\033[0m %s\n' "$name"
            else                       printf '  [ ] %s\n' "$name"
            fi
        done
        printf '\n'
        printf '  +------------------------------- Output -------------------------------+\n'
        if [[ -n "$log_lines" ]]; then
            while IFS= read -r line; do
                printf '  | \033[90m%-68s\033[0m |\n' "$line"
            done <<< "$log_lines"
        fi
        local line_count
        line_count=$(printf '%s' "$log_lines" | grep -c '^' || true)
        for ((i=line_count; i<8; i++)); do
            printf '  | %-68s |\n' ""
        done
        printf '  +----------------------------------------------------------------------+\n'
    } > /dev/tty1
}

log_progress() {
    echo "$*" >> "$PROGRESS_LOG"
}

# Display a key milestone message with a brief pause so users can read it.
# Stops the spinner, renders the message, waits, then resumes animation.
milestone() {
    local step=$1 msg="$2" pause=${3:-2}

    stop_progress_animation

    log_progress "$msg"

    local now_mono elapsed
    now_mono=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    elapsed=$(( now_mono - PROGRESS_START_MONO ))

    # Calculate weighted percentage
    local total=${#STEP_NAMES[@]}
    local weight_sum=0 total_weight=0
    for ((i=0; i<total; i++)); do
        total_weight=$(( total_weight + STEP_WEIGHTS[i] ))
        if (( i < step - 1 )); then
            weight_sum=$(( weight_sum + STEP_WEIGHTS[i] ))
        fi
    done
    local pct=0
    (( total_weight > 0 )) && pct=$(( weight_sum * 100 / total_weight ))

    render_progress "$step" "$pct" "$elapsed" "*"
    sleep "$pause"
}

start_progress_animation() {
    local step=$1 base_pct=$2 step_weight=$3

    stop_progress_animation

    (
        local spinners=('|' '/' '-' '\')
        local spin_idx=0
        local step_start
        step_start=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)

        while true; do
            local now_mono elapsed step_elapsed pct_in_step current_pct
            now_mono=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
            elapsed=$(( now_mono - PROGRESS_START_MONO ))
            step_elapsed=$(( now_mono - step_start ))

            # Ease-out curve: max 90% of step weight
            if (( step_elapsed < 300 )); then
                pct_in_step=$(( step_weight * step_elapsed * 9 / 3000 ))
            else
                pct_in_step=$(( step_weight * 9 / 10 ))
            fi
            current_pct=$(( base_pct + pct_in_step ))

            render_progress "$step" "$current_pct" "$elapsed" "${spinners[$spin_idx]}"
            spin_idx=$(( (spin_idx + 1) % 4 ))
            sleep 1
        done
    ) &
    PROGRESS_ANIM_PID=$!
}

stop_progress_animation() {
    if [[ -n "$PROGRESS_ANIM_PID" ]]; then
        kill "$PROGRESS_ANIM_PID" 2>/dev/null || true
        wait "$PROGRESS_ANIM_PID" 2>/dev/null || true
        PROGRESS_ANIM_PID=""
    fi
}

progress() {
    local step=$1 msg="$2"
    local total=${#STEP_NAMES[@]}

    stop_progress_animation

    local now_mono
    now_mono=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    local elapsed=$(( now_mono - PROGRESS_START_MONO ))

    # Calculate weighted percentage (sum weights of completed steps)
    local weight_sum=0 total_weight=0
    for ((i=0; i<total; i++)); do
        total_weight=$(( total_weight + STEP_WEIGHTS[i] ))
        if (( i < step - 1 )); then
            weight_sum=$(( weight_sum + STEP_WEIGHTS[i] ))
        fi
    done
    local pct=0
    (( total_weight > 0 )) && pct=$(( weight_sum * 100 / total_weight ))

    # Plain-text summary to stdout (goes to log file)
    echo "=== Step $step/$total: $msg ($((elapsed/60))m$((elapsed%60))s) ==="

    render_progress "$step" "$pct" "$elapsed"
}

progress_complete() {
    stop_progress_animation

    local total=${#STEP_NAMES[@]}
    local now_mono
    now_mono=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    local elapsed=$(( now_mono - PROGRESS_START_MONO ))

    [[ -c /dev/tty1 ]] || return

    local bar
    printf -v bar '%*s' 50 ''; bar="${bar// /#}"

    # Collect running container names for the summary
    local services=""
    if command -v docker &>/dev/null; then
        services=$(docker ps --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ', ' | sed 's/,$//')
    fi

    {
        printf '\033[2J\033[H'
        printf '\n'
        printf '  +----------------------------------------------------------------------+\n'
        printf '  |                     \033[1m%-38.38s\033[0m           |\n' "$PROGRESS_TITLE"
        printf '  +----------------------------------------------------------------------+\n'
        printf '\n'
        printf '  \033[36mElapsed: %02d:%02d\033[0m\n\n' $((elapsed/60)) $((elapsed%60))
        printf '  \033[32m[%s]\033[0m 100%%\n\n' "$bar"
        for i in $(seq 1 "$total"); do
            printf '  \033[32m[x]\033[0m %s\n' "${STEP_NAMES[$((i-1))]}"
        done
        printf '\n'
        printf '  \033[32m>>> Installation complete! <<<\033[0m\n'
        printf '\n'
        printf '  +------------------------------- Summary -------------------------------+\n'
        printf '  | \033[32m%-68s\033[0m |\n' "All steps completed successfully"
        if [[ -n "$services" ]]; then
            printf '  | %-68s |\n' ""
            printf '  | \033[36m%-68s\033[0m |\n' "Running services:"
            # Wrap service names to fit the box (68 chars per line)
            local line=""
            for svc in ${services//,/ }; do
                if [[ $(( ${#line} + ${#svc} + 2 )) -gt 64 ]]; then
                    printf '  |   \033[36m%-66s\033[0m |\n' "$line"
                    line="$svc"
                else
                    [[ -n "$line" ]] && line="$line, $svc" || line="$svc"
                fi
            done
            [[ -n "$line" ]] && printf '  |   \033[36m%-66s\033[0m |\n' "$line"
        fi
        printf '  | %-68s |\n' ""
        printf '  | \033[33m%-68s\033[0m |\n' "System will reboot shortly..."
        # Fill remaining lines
        local used_lines=4
        [[ -n "$services" ]] && used_lines=6
        for ((i=used_lines; i<8; i++)); do
            printf '  | %-68s |\n' ""
        done
        printf '  +----------------------------------------------------------------------+\n'
        printf '\n'
        printf '  \033[1;32m  snapMULTI ready\033[0m\n'
    } > /dev/tty1
}
