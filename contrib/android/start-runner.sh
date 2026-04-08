#!/data/data/com.termux/files/usr/bin/bash
# Start the GitHub Actions self-hosted runner on Android/Termux as a service.
#
# Designed to be invoked from ~/.termux/boot/ on device boot, but also safe
# to run by hand for restarts.
#
# Service semantics:
#   - Acquires a wake lock so Android won't suspend the runner.
#   - Refuses to start a second watchdog if one is already running.
#   - Wraps run.sh in a watchdog loop with exponential backoff: if run.sh
#     exits for any reason (crash, kill, network blip, exit-on-unknown-code),
#     the watchdog respawns it. This is the "service" behavior — without
#     this, run.sh's `exit 0` on unknown codes leaves nothing running.
#   - Logs everything to ~/runner-android/_layout/runner.log.
#   - Marks its own process via the RUNNER_ANDROID_WATCHDOG env var so the
#     ctl wrapper can find and kill the loop (not just the listener).
#
# We deliberately do NOT use runit (`sv`) here; the existing runit setup on
# the dev device (asd-build) has been unstable, so we keep this stack flat:
# nohup + setsid + a tiny watchdog loop.

set -eu

export HOME="${HOME:-/data/data/com.termux/files/home}"
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export PATH="$PREFIX/bin:$PATH"
export TMPDIR="$PREFIX/tmp"

LAYOUT="$HOME/runner-android/_layout"
LOG="$LAYOUT/runner.log"

if [ ! -x "$LAYOUT/run.sh" ]; then
    echo "error: $LAYOUT/run.sh not found. Build the runner first." >&2
    exit 1
fi

# If we're the watchdog (re-exec'd below with --watchdog), enter the loop.
# We use an argv flag rather than an env var because pgrep -f matches against
# /proc/PID/cmdline, which only contains argv.
if [ "${1:-}" = "--watchdog" ]; then
    cd "$LAYOUT"
    backoff=1
    max_backoff=60
    while true; do
        echo "[watchdog $(date -Iseconds)] starting run.sh" >> "$LOG"
        start=$(date +%s)
        ./run.sh >> "$LOG" 2>&1 || true
        end=$(date +%s)
        elapsed=$(( end - start ))
        echo "[watchdog $(date -Iseconds)] run.sh exited after ${elapsed}s; restarting in ${backoff}s" >> "$LOG"
        # If the runner stayed up >5 min, treat as healthy and reset backoff.
        if [ "$elapsed" -gt 300 ]; then
            backoff=1
        fi
        sleep "$backoff"
        backoff=$(( backoff * 2 ))
        [ "$backoff" -gt "$max_backoff" ] && backoff="$max_backoff"
    done
fi

# Foreground entry point: refuse double-start, set up wake lock, fork the
# watchdog, return.
if pgrep -f "start-runner\.sh --watchdog" >/dev/null 2>&1; then
    echo "watchdog already running (pid $(pgrep -f 'start-runner\.sh --watchdog' | head -1))" >&2
    exit 0
fi

# Best-effort wake lock; only effective with the Termux:API addon installed.
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock || true

cd "$LAYOUT"
: > "$LOG"
nohup setsid "$0" --watchdog >> "$LOG" 2>&1 < /dev/null &
disown || true

echo "runner watchdog started, logging to $LOG"
