#!/data/data/com.termux/files/usr/bin/bash
# Start the GitHub Actions self-hosted runner on Android/Termux.
#
# Designed to be invoked from ~/.termux/boot/ on device boot, but also safe
# to run by hand for restarts.
#
# Behavior:
#   - Acquires a wake lock so Android won't suspend the runner.
#   - Refuses to start a second instance if one is already running.
#   - Logs to ~/runner-android/_layout/runner.log (rotated by truncation on
#     each start; runit/svlogger was avoided because asd-build's runit setup
#     has been unstable on this device).
#   - Uses nohup + setsid so the process survives the shell exiting.

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

# Avoid double-starts.
if pgrep -f "dotnet .*Runner\.Listener\.dll" >/dev/null 2>&1; then
    echo "runner already running (pid $(pgrep -f Runner.Listener.dll | head -1))" >&2
    exit 0
fi

# Keep the CPU awake. Safe to call repeatedly; only effective if the
# Termux:API package is installed (best-effort, ignore failure).
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock || true

cd "$LAYOUT"
: > "$LOG"
nohup setsid ./run.sh >> "$LOG" 2>&1 < /dev/null &
disown || true

echo "runner started, logging to $LOG"
