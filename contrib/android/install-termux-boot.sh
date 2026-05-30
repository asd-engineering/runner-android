#!/data/data/com.termux/files/usr/bin/bash
# Download the Termux:Boot APK and open Android's package installer.
#
# Termux:Boot is the Android addon that runs scripts in ~/.termux/boot/ when
# the device finishes booting. Without it, our runner-android.sh boot symlink
# is inert. It is NOT a Termux pkg — it has to be installed as an Android APK.
#
# Usage: contrib/android/install-termux-boot.sh
#
# After Android shows the install dialog, you must:
#   1. Tap "Install" (one tap)
#   2. Open the Termux:Boot app once after install — Android requires the
#      user to launch a boot receiver app at least once before the
#      BOOT_COMPLETED broadcast will fire it on subsequent reboots.
#
# Then verify with:
#   pm path com.termux.boot   # → should print the APK path

set -eu

# Pin to the same source family as Termux itself. Don't mix F-Droid and
# GitHub builds — APK signature mismatch will refuse the upgrade.
URL="${TERMUX_BOOT_APK_URL:-https://f-droid.org/repo/com.termux.boot_1000.apk}"
DEST="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/termux-boot.apk"

if pm path com.termux.boot >/dev/null 2>&1; then
    echo "Termux:Boot is already installed: $(pm path com.termux.boot)"
    exit 0
fi

if ! command -v termux-open >/dev/null 2>&1; then
    echo "error: termux-open not found. Install termux-api: pkg install termux-api" >&2
    exit 1
fi

echo "Downloading Termux:Boot APK from $URL..."
curl -fsSL -o "$DEST" "$URL"
ls -lh "$DEST"

echo
echo "Opening Android's package installer..."
echo "Tap 'Install' on the phone screen, then OPEN the Termux:Boot app once"
echo "(Android requires this for the boot receiver to register)."
termux-open "$DEST"
