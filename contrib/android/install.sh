#!/data/data/com.termux/files/usr/bin/bash
# One-shot installer for the GitHub Actions runner on a fresh Termux device.
#
# Usage:
#   GITHUB_PAT=ghp_xxx GITHUB_ORG=asd-engineering ./contrib/android/install.sh
#
# Optional env vars:
#   RUNNER_NAME      defaults to $(hostname)
#   RUNNER_LABELS    defaults to self-hosted-android
#   GITHUB_REPO      if set, register against owner/repo instead of org level
#                    (the PAT then needs `repo` scope, not `admin:org`)
#
# What it does:
#   1. Installs Termux packages (.NET 8 SDK, node, git, build tools, libs).
#   2. Stubs $REPO/_dotnetsdk/8.0.419 so dev.sh accepts the system dotnet.
#   3. Builds the runner layout (dev.sh layout Release linux-arm64).
#   4. Runs patch-layout.sh to make the layout bionic-compatible.
#   5. Fetches a registration token from GitHub via the supplied PAT.
#   6. Registers the runner with --disableupdate (critical: stops the runner
#      from re-deploying the upstream tarball over our patched layout).
#   7. Installs the Termux:Boot symlink so the runner starts at boot.
#   8. Starts the runner.
#
# Re-running this script is safe; --replace lets us re-register cleanly.

set -euo pipefail

: "${GITHUB_PAT:?set GITHUB_PAT to a PAT with admin:org (org) or repo (repo) scope}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted-android}"

if [ -n "${GITHUB_REPO:-}" ]; then
    REG_URL="https://github.com/$GITHUB_REPO"
    TOKEN_URL="https://api.github.com/repos/$GITHUB_REPO/actions/runners/registration-token"
elif [ -n "${GITHUB_ORG:-}" ]; then
    REG_URL="https://github.com/$GITHUB_ORG"
    TOKEN_URL="https://api.github.com/orgs/$GITHUB_ORG/actions/runners/registration-token"
else
    echo "error: set GITHUB_ORG=<org> or GITHUB_REPO=<owner/repo>" >&2
    exit 1
fi

echo "==> [1/8] Installing Termux packages"
pkg update -y >/dev/null
pkg install -y dotnet-sdk-8.0 nodejs git curl python openssl libicu krb5 zlib termux-api termux-services >/dev/null

echo "==> [2/8] Stubbing _dotnetsdk so dev.sh accepts the system .NET"
mkdir -p "$REPO_ROOT/_dotnetsdk/8.0.419"
ln -sf "$(command -v dotnet)" "$REPO_ROOT/_dotnetsdk/8.0.419/dotnet"
touch "$REPO_ROOT/_dotnetsdk/8.0.419/.8.0.419"

echo "==> [3/8] Building runner layout (this takes a few minutes)"
( cd "$REPO_ROOT/src" && ./dev.sh layout Release linux-arm64 )

echo "==> [4/8] Applying bionic patches"
"$REPO_ROOT/contrib/android/patch-layout.sh"

echo "==> [5/8] Verifying listener starts"
( cd "$REPO_ROOT/_layout" && dotnet ./bin/Runner.Listener.dll --version )

echo "==> [6/8] Fetching registration token from GitHub"
REG_TOKEN="$(curl -fsS -X POST \
    -H "Authorization: token $GITHUB_PAT" \
    -H "Accept: application/vnd.github+json" \
    "$TOKEN_URL" | python -c 'import sys,json;print(json.load(sys.stdin)["token"])')"

if [ -z "$REG_TOKEN" ]; then
    echo "error: empty registration token from $TOKEN_URL" >&2
    exit 1
fi

echo "==> [7/8] Registering runner '$RUNNER_NAME' with labels '$RUNNER_LABELS'"
( cd "$REPO_ROOT/_layout" && ./config.sh \
    --url "$REG_URL" \
    --token "$REG_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --unattended --replace --disableupdate )

echo "==> [8/8] Installing Termux:Boot symlink and starting"
mkdir -p ~/.termux/boot
ln -sf "$REPO_ROOT/contrib/android/start-runner.sh" ~/.termux/boot/runner-android.sh
"$REPO_ROOT/contrib/android/runner-android-ctl" restart || \
    "$REPO_ROOT/contrib/android/start-runner.sh"

echo
echo "Done. Runner '$RUNNER_NAME' is registered and running."
echo "Control:  $REPO_ROOT/contrib/android/runner-android-ctl {start|stop|restart|status|logs}"
echo "Boot:     ~/.termux/boot/runner-android.sh (requires the Termux:Boot app)"
