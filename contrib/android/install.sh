#!/data/data/com.termux/files/usr/bin/bash
# Idempotent installer / reinstaller / updater for the Android self-hosted
# GitHub Actions runner on Termux. Safe to re-run on the same device.
#
# Usage:
#   GITHUB_PAT=ghp_xxx GITHUB_ORG=asd-engineering \
#       contrib/android/install.sh                     # fresh install or rebuild
#
#   contrib/android/install.sh --update                # git pull then rebuild,
#                                                      # re-register if PAT set
#
#   contrib/android/install.sh --uninstall             # stop, unregister, delete
#                                                      # _layout and boot symlink
#
# Required env vars (for install / update with re-register):
#   GITHUB_PAT       a PAT with `admin:org` (org-level) or `repo` (repo-level)
#
# One of:
#   GITHUB_ORG=<org>             register at the org level (default for us)
#   GITHUB_REPO=<owner/repo>     register at the repo level
#
# Optional env vars:
#   RUNNER_NAME      defaults to $(hostname)
#   RUNNER_LABELS    defaults to self-hosted-android
#   GIT_REMOTE       defaults to origin
#   GIT_BRANCH       defaults to the current branch
#
# What it does (in order):
#   1. Installs/updates Termux packages.
#   2. Stops any running runner on this device (idempotent).
#   3. If --update: git pull on the configured remote/branch.
#   4. Wipes _layout (critical: stale self-update artifacts have bitten us).
#   5. Stubs _dotnetsdk/8.0.419 so dev.sh accepts the system .NET 8.
#   6. Builds the layout via dev.sh.
#   7. Applies bionic patches (patch-layout.sh).
#   8. Sanity-checks the listener.
#   9. Unregisters any prior runner with the same name (best-effort) so the
#      re-register doesn't trip on stale state, then registers fresh with
#      --replace --disableupdate.
#  10. Installs the Termux:Boot symlink.
#  11. Starts the runner via runner-android-ctl.
#  12. Verifies it shows up as `online` against the GitHub API.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LAYOUT="$REPO_ROOT/_layout"
CTL="$REPO_ROOT/contrib/android/runner-android-ctl"
PATCH="$REPO_ROOT/contrib/android/patch-layout.sh"
START="$REPO_ROOT/contrib/android/start-runner.sh"

MODE="install"
for arg in "$@"; do
    case "$arg" in
        --update)    MODE="update" ;;
        --uninstall) MODE="uninstall" ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted-android}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"

# ---------- helpers ----------------------------------------------------------

resolve_token_url() {
    if [ -n "${GITHUB_REPO:-}" ]; then
        REG_URL="https://github.com/$GITHUB_REPO"
        TOKEN_URL_REG="https://api.github.com/repos/$GITHUB_REPO/actions/runners/registration-token"
        TOKEN_URL_REM="https://api.github.com/repos/$GITHUB_REPO/actions/runners/remove-token"
    elif [ -n "${GITHUB_ORG:-}" ]; then
        REG_URL="https://github.com/$GITHUB_ORG"
        TOKEN_URL_REG="https://api.github.com/orgs/$GITHUB_ORG/actions/runners/registration-token"
        TOKEN_URL_REM="https://api.github.com/orgs/$GITHUB_ORG/actions/runners/remove-token"
    else
        die "set GITHUB_ORG=<org> or GITHUB_REPO=<owner/repo>"
    fi
}

fetch_token() {
    local url="$1"
    [ -n "${GITHUB_PAT:-}" ] || die "GITHUB_PAT not set"
    local token
    token=$(curl -fsS -X POST \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        "$url" | python -c 'import sys,json;print(json.load(sys.stdin)["token"])')
    [ -n "$token" ] || die "empty token from $url"
    printf '%s' "$token"
}

stop_runner() {
    if [ -x "$CTL" ]; then
        "$CTL" stop || true
    else
        pkill -f 'dotnet .*Runner\.Listener\.dll' 2>/dev/null || true
    fi
}

unregister_existing() {
    # Best-effort: only works if .credentials still exist on disk.
    if [ -f "$LAYOUT/.credentials" ] && [ -f "$LAYOUT/bin/Runner.Listener.dll" ]; then
        log "Unregistering existing runner from GitHub"
        local rem
        rem=$(fetch_token "$TOKEN_URL_REM") || return 0
        ( cd "$LAYOUT" && dotnet ./bin/Runner.Listener.dll remove --token "$rem" ) || \
            warn "remove failed (may already be gone); continuing"
    fi
}

verify_online() {
    [ -n "${GITHUB_PAT:-}" ] || return 0
    local list_url
    if [ -n "${GITHUB_REPO:-}" ]; then
        list_url="https://api.github.com/repos/$GITHUB_REPO/actions/runners"
    else
        list_url="https://api.github.com/orgs/$GITHUB_ORG/actions/runners"
    fi
    log "Polling GitHub for runner '$RUNNER_NAME' to come online"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        local status
        status=$(curl -fsS \
            -H "Authorization: token $GITHUB_PAT" \
            -H "Accept: application/vnd.github+json" \
            "$list_url" | \
            python -c "
import sys,json
for r in json.load(sys.stdin).get('runners',[]):
    if r['name']=='$RUNNER_NAME':
        print(r['status']); break
else:
    print('missing')") || status="error"
        if [ "$status" = "online" ]; then
            echo "    online (after ${i}s)"
            return 0
        fi
        sleep 1
    done
    warn "runner not yet online — check $LAYOUT/runner.log"
    return 1
}

# ---------- modes ------------------------------------------------------------

do_packages() {
    log "[pkg] Updating package lists and installing dependencies"
    pkg update -y >/dev/null
    # Runner core deps:
    #   dotnet-sdk-8.0  - .NET 8 runtime for the runner itself
    #   nodejs          - replaces the bundled glibc Node in externals/
    #   git curl python - for actions/checkout, gh CLI, parsing tokens
    #   openssl libicu krb5 zlib - .NET native dep transitive load
    #   termux-api      - termux-wake-lock used by start-runner.sh
    #
    # Build deps for the .asd Termux release pipeline (so the runner can
    # take a `runs-on: self-hosted-android` build job out of the box):
    #   jq                                  - workflows + smoke test
    #   golang clang make binutils caddy ttyd python3
    #                                       - scripts/termux/build-termux-release.sh
    pkg install -y \
        dotnet-sdk-8.0 nodejs git curl python \
        openssl libicu krb5 zlib termux-api \
        jq golang clang make binutils caddy ttyd python3 strace >/dev/null
}

do_git_update() {
    [ "$MODE" = "update" ] || return 0
    log "[git] Pulling $GIT_REMOTE/$GIT_BRANCH"
    git -C "$REPO_ROOT" fetch "$GIT_REMOTE" "$GIT_BRANCH"
    git -C "$REPO_ROOT" checkout "$GIT_BRANCH"
    git -C "$REPO_ROOT" pull --ff-only "$GIT_REMOTE" "$GIT_BRANCH"
}

do_build() {
    log "[build] Wiping _layout (stale self-update artifacts cause issues)"
    rm -rf "$LAYOUT"

    log "[build] Stubbing _dotnetsdk so dev.sh accepts the system .NET"
    mkdir -p "$REPO_ROOT/_dotnetsdk/8.0.419"
    ln -sf "$(command -v dotnet)" "$REPO_ROOT/_dotnetsdk/8.0.419/dotnet"
    touch "$REPO_ROOT/_dotnetsdk/8.0.419/.8.0.419"

    log "[build] dev.sh layout Release linux-arm64 (a few minutes)"
    ( cd "$REPO_ROOT/src" && ./dev.sh layout Release linux-arm64 )

    log "[build] Applying bionic patches"
    "$PATCH"

    log "[build] Verifying listener starts"
    ( cd "$LAYOUT" && dotnet ./bin/Runner.Listener.dll --version )
}

do_register() {
    [ -n "${GITHUB_PAT:-}" ] || die "GITHUB_PAT required for registration"
    resolve_token_url

    log "[reg] Fetching registration token from $TOKEN_URL_REG"
    local reg_token
    reg_token=$(fetch_token "$TOKEN_URL_REG")

    log "[reg] Registering '$RUNNER_NAME' with labels '$RUNNER_LABELS' (--disableupdate)"
    ( cd "$LAYOUT" && ./config.sh \
        --url "$REG_URL" \
        --token "$reg_token" \
        --name "$RUNNER_NAME" \
        --labels "$RUNNER_LABELS" \
        --unattended --replace --disableupdate )
}

do_boot_symlink() {
    log "[boot] Installing Termux:Boot symlink"
    mkdir -p "$HOME/.termux/boot"
    ln -sf "$START" "$HOME/.termux/boot/runner-android.sh"
}

do_start() {
    log "[run] Starting runner"
    "$CTL" restart || "$CTL" start
}

do_uninstall() {
    log "[uninstall] Stopping runner"
    stop_runner
    if [ -d "$LAYOUT" ]; then
        if [ -n "${GITHUB_PAT:-}" ]; then
            resolve_token_url
            unregister_existing
        else
            warn "GITHUB_PAT not set; leaving runner registered on GitHub side"
        fi
        log "[uninstall] Removing $LAYOUT"
        rm -rf "$LAYOUT"
    fi
    log "[uninstall] Removing Termux:Boot symlink"
    rm -f "$HOME/.termux/boot/runner-android.sh"
    log "[uninstall] Done"
}

# ---------- main -------------------------------------------------------------

case "$MODE" in
    uninstall)
        do_uninstall
        ;;
    install|update)
        do_packages
        do_git_update
        stop_runner
        if [ -n "${GITHUB_PAT:-}" ]; then
            resolve_token_url
            unregister_existing
        fi
        do_build
        if [ -n "${GITHUB_PAT:-}" ]; then
            do_register
        else
            warn "GITHUB_PAT not set; skipping registration. Layout is built and patched."
        fi
        do_boot_symlink
        do_start
        verify_online || true
        echo
        log "Done. '$RUNNER_NAME' is registered, started, and configured to start at boot."
        log "Control: $CTL {start|stop|restart|status|logs}"
        ;;
esac
