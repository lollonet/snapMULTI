#!/usr/bin/env bash
# Progress display library for snapMULTI auto-install.
#
# Provides a full-screen TUI on /dev/tty1 (HDMI console) with:
#   - ASCII progress bar with weighted percentages
#   - Step checklist ([x] done, [>] current, [ ] pending)
#   - Animated spinner for long-running operations
#   - Live log output area (last 14 lines)
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
            # Use large font if available (not all Pi OS images include it)
            if ls /usr/share/consolefonts/Uni3-TerminusBold28x14* &>/dev/null; then
                setfont Uni3-TerminusBold28x14 -C /dev/tty1 2>/dev/null || true
            elif ls /usr/share/consolefonts/Lat15-TerminusBold24x12* &>/dev/null; then
                setfont Lat15-TerminusBold24x12 -C /dev/tty1 2>/dev/null || true
            fi
        fi
    fi

    # Detect size AFTER font change — setfont alters console geometry
    _detect_tty_size
}

# Terminal dimensions — set by _detect_tty_size(), called from progress_init()
# after font setup. Defaults are 800x600 @ 8x16 = 100x37.
_tty_cols=100
_tty_rows=37
_box_width=96
_inner_width=94

_detect_tty_size() {
    if [[ -c /dev/tty1 ]]; then
        # Try stty first (works when called from tty1 directly)
        _tty_cols=$(stty -F /dev/tty1 size 2>/dev/null | awk '{print $2}') || _tty_cols=0
        _tty_rows=$(stty -F /dev/tty1 size 2>/dev/null | awk '{print $1}') || _tty_rows=0

        # Fallback: compute from framebuffer size and console font metrics.
        # stty returns empty when called via SSH or cloud-init (no controlling tty).
        if (( _tty_cols < 40 || _tty_rows < 10 )); then
            local fb_w fb_h font_w=8 font_h=16
            fb_w=$(cut -d, -f1 /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo 0)
            fb_h=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo 0)
            # Detect active font size from setfont (28x14 or 24x12 if HD)
            if (( fb_w > 1000 )); then
                if ls /usr/share/consolefonts/Uni3-TerminusBold28x14* &>/dev/null; then
                    font_w=14 font_h=28
                elif ls /usr/share/consolefonts/Lat15-TerminusBold24x12* &>/dev/null; then
                    font_w=12 font_h=24
                fi
            fi
            if (( fb_w > 0 && fb_h > 0 )); then
                _tty_cols=$(( fb_w / font_w ))
                _tty_rows=$(( fb_h / font_h ))
            fi
        fi

        # Final safety clamp + 2-col breathing room (avoid edge bleed)
        (( _tty_cols < 40 )) && _tty_cols=100
        (( _tty_rows < 10 )) && _tty_rows=37
        (( _tty_cols > 42 )) && _tty_cols=$(( _tty_cols - 2 ))
    fi
    # Layout constants (2-char margin each side)
    _box_width=$(( _tty_cols - 4 ))
    _inner_width=$(( _box_width - 2 ))
}

# Render progress display to tty1
#
# Layout (full width, dynamic log area):
#   Row 1:    header box (title centered)
#   Row 2:    elapsed + progress bar + percentage + spinner
#   Row 3-N:  step checklist
#   Row N+1:  separator
#   Row N+2:  log lines (fills remaining rows)
#   Last row: bottom border
render_progress() {
    local step=$1 pct=$2 elapsed=$3 spinner=${4:-}
    local total=${#STEP_NAMES[@]}

    [[ -c /dev/tty1 ]] || return

    # Clamp pct to 0-100
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100

    # Build progress bar (fills available width minus elapsed label)
    # "  00:00  [####----]" = 12 chars overhead
    local bar_width=$(( _box_width - 12 ))
    (( bar_width < 20 )) && bar_width=20
    local filled=$(( pct * bar_width / 100 ))
    local empty=$(( bar_width - filled ))
    local bar pad
    printf -v bar '%*s' "$filled" ''; bar="${bar// /#}"
    printf -v pad '%*s' "$empty" ''; bar+="${pad// /-}"

    # Calculate rows used by header + steps
    # header(3) + elapsed+bar(1) + pct(1) + blank(1) + steps(total) + blank(1) + separator(1) + footer(1) = total+9
    local fixed_rows=$(( total + 9 ))
    local log_rows=$(( _tty_rows - fixed_rows ))
    (( log_rows < 4 )) && log_rows=4
    (( log_rows > 14 )) && log_rows=14

    # Get last N lines of log for output area
    local log_lines=""
    if [[ -f "$PROGRESS_LOG" ]]; then
        log_lines=$(tail -"$log_rows" "$PROGRESS_LOG" 2>/dev/null | cut -c1-"$_inner_width" || true)
    fi

    local hline
    printf -v hline '%*s' "$_box_width" ''; hline="${hline// /-}"

    {
        printf '\033[2J\033[H'
        printf '  +%s+\n' "$hline"
        printf '  | \033[1m%-*.*s\033[0m |\n' "$_inner_width" "$_inner_width" "$PROGRESS_TITLE"
        printf '  +%s+\n' "$hline"
        printf '  \033[36m%02d:%02d\033[0m  \033[33m[%s]\033[0m\n' \
            $((elapsed/60)) $((elapsed%60)) "$bar"
        printf '  %3d%% %s\n' "$pct" "$spinner"
        printf '\n'
        for i in $(seq 1 "$total"); do
            local name="${STEP_NAMES[$((i-1))]}"
            if (( i < step )); then   printf '  \033[32m[x]\033[0m %s\n' "$name"
            elif (( i == step )); then printf '  \033[33m[>]\033[0m %s\n' "$name"
            else                       printf '  [ ] %s\n' "$name"
            fi
        done
        printf '\n'
        local log_label="  Log  "
        local log_lpad=$(( (_box_width - ${#log_label}) / 2 ))
        local log_rpad=$(( _box_width - ${#log_label} - log_lpad ))
        printf '  +%s%s%s+\n' "${hline:0:$log_lpad}" "$log_label" "${hline:0:$log_rpad}"
        if [[ -n "$log_lines" ]]; then
            while IFS= read -r line; do
                printf '  | \033[90m%-*s\033[0m |\n' "$_inner_width" "$line"
            done <<< "$log_lines"
        fi
        local line_count=0
        [[ -n "$log_lines" ]] && line_count=$(printf '%s' "$log_lines" | grep -c '^' || true)
        for ((i=line_count; i<log_rows; i++)); do
            printf '  | %-*s |\n' "$_inner_width" ""
        done
        printf '  +%s+\n' "$hline"
    } > /dev/tty1
}

log_progress() {
    echo "$*" >> "$PROGRESS_LOG"
    # Also echo to stdout so firstboot's pipe filter can capture it for the install log
    echo "[INFO] $*"
}

# Display a key milestone message with a brief pause so users can read it.
# Stops the spinner, renders the message, and waits. Animation is NOT resumed —
# the caller is expected to call next_step() or start_progress_animation() after.
milestone() {
    local step=$1 msg="$2" pause=${3:-2}

    log_progress "$msg"
    # Skip rendering when parent owns the display
    [[ -n "${PROGRESS_MANAGED:-}" ]] && return

    stop_progress_animation

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
    # Skip animation when parent (firstboot.sh) owns the display
    [[ -n "${PROGRESS_MANAGED:-}" ]] && return
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
    # Skip rendering when parent owns the display
    [[ -n "${PROGRESS_MANAGED:-}" ]] && return

    local total=${#STEP_NAMES[@]}
    local now_mono
    now_mono=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    local elapsed=$(( now_mono - PROGRESS_START_MONO ))

    [[ -c /dev/tty1 ]] || return

    local bar_width=$(( _box_width - 12 ))
    (( bar_width < 20 )) && bar_width=20
    local bar
    printf -v bar '%*s' "$bar_width" ''; bar="${bar// /#}"

    # Collect running container names for the summary
    local services=""
    if command -v docker &>/dev/null; then
        services=$(docker ps --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ', ' | sed 's/,$//')
    fi

    local hline
    printf -v hline '%*s' "$_box_width" ''; hline="${hline// /-}"

    {
        printf '\033[2J\033[H'
        printf '  +%s+\n' "$hline"
        printf '  | \033[1m%-*.*s\033[0m |\n' "$_inner_width" "$_inner_width" "$PROGRESS_TITLE"
        printf '  +%s+\n' "$hline"
        printf '  \033[36m%02d:%02d\033[0m  \033[32m[%s]\033[0m\n' \
            $((elapsed/60)) $((elapsed%60)) "$bar"
        printf '  100%%\n'
        for i in $(seq 1 "$total"); do
            printf '  \033[32m[x]\033[0m %s\n' "${STEP_NAMES[$((i-1))]}"
        done
        printf '\n'
        printf '  \033[32m>>> Installation complete! <<<\033[0m\n'
        printf '\n'
        local sum_label="  Summary  "
        local sum_lpad=$(( (_box_width - ${#sum_label}) / 2 ))
        local sum_rpad=$(( _box_width - ${#sum_label} - sum_lpad ))
        printf '  +%s%s%s+\n' "${hline:0:$sum_lpad}" "$sum_label" "${hline:0:$sum_rpad}"
        local summary_rows=$(( _tty_rows - total - 10 ))
        (( summary_rows < 6 )) && summary_rows=6
        local used_lines=0
        printf '  | \033[32m%-*s\033[0m |\n' "$_inner_width" "All steps completed successfully"
        (( used_lines++ ))
        if [[ -n "$services" ]]; then
            printf '  | %-*s |\n' "$_inner_width" ""
            (( used_lines++ ))
            printf '  | \033[36m%-*s\033[0m |\n' "$_inner_width" "Running services:"
            (( used_lines++ ))
            local line=""
            local max_svc_width=$(( _inner_width - 2 ))
            for svc in ${services//,/ }; do
                if [[ $(( ${#line} + ${#svc} + 2 )) -gt $max_svc_width ]]; then
                    printf '  |   \033[36m%-*s\033[0m |\n' "$(( _inner_width - 2 ))" "$line"
                    (( used_lines++ ))
                    line="$svc"
                else
                    [[ -n "$line" ]] && line="$line, $svc" || line="$svc"
                fi
            done
            if [[ -n "$line" ]]; then
                printf '  |   \033[36m%-*s\033[0m |\n' "$(( _inner_width - 2 ))" "$line"
                (( used_lines++ ))
            fi
        fi
        printf '  | %-*s |\n' "$_inner_width" ""
        (( used_lines++ ))
        printf '  | \033[33m%-*s\033[0m |\n' "$_inner_width" "System will reboot shortly..."
        (( used_lines++ ))
        for ((i=used_lines; i<summary_rows; i++)); do
            printf '  | %-*s |\n' "$_inner_width" ""
        done
        printf '  +%s+\n' "$hline"
        printf '\n'
        printf '  \033[1;32m  snapMULTI ready\033[0m\n'
    } > /dev/tty1
}
