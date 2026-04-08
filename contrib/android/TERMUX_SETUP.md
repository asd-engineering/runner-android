# Termux setup for the asd self-hosted runner fleet

End-to-end checklist for prepping a fresh Android phone (Samsung
preferred — that's what we run) so it can join the asd-engineering
runner fleet under the `self-hosted-android` label.

If you're impatient: install the three Android apps from
[§1](#1-android-apps), then run [§4](#4-installer) and you're done.

## Required Android apps

The Termux ecosystem ships as multiple **Android packages**, not Termux
packages. They are NOT installable via `pkg install` — `pkg` only
manages packages *inside* a Termux install. The addons are separate
APKs.

| Android package | What it gives you | Required for |
|---|---|---|
| `com.termux` | The Termux terminal itself | Everything |
| `com.termux.boot` | Runs scripts in `~/.termux/boot/` on `BOOT_COMPLETED` | Auto-restart of the runner after device reboot |
| `com.termux.api` | `termux-wake-lock`, `termux-open`, etc. | Wake lock so Android doesn't suspend the runner mid-job; convenience for installing more APKs from inside Termux |

**⚠️ Don't mix sources.** All three must come from the same signing
key. If you install `com.termux` from F-Droid, install the addons from
F-Droid too; if from GitHub releases, use GitHub for all three. APK
signature mismatch will refuse the install.

The Play Store version of Termux is **abandoned and broken** — do not
use it.

## 1. Android apps — install order

### Fastest path: adb from a wired laptop (~15 sec total)

Requires the phone in **Developer mode** with **USB debugging** enabled
and the laptop fingerprint authorized once.

```bash
# On your laptop, with the phone connected via USB:
adb devices                                    # confirm the phone shows up
# Termux itself:
curl -fsSL -O https://f-droid.org/repo/com.termux_1020.apk
adb install com.termux_1020.apk
# Termux:Boot (the boot receiver):
curl -fsSL -O https://f-droid.org/repo/com.termux.boot_1000.apk
adb install com.termux.boot_1000.apk
# Termux:API (wake lock + termux-open):
curl -fsSL -O https://f-droid.org/repo/com.termux.api_51.apk
adb install com.termux.api_51.apk
```

(Version codes change. Pick the latest from
[F-Droid's Termux page](https://f-droid.org/en/packages/com.termux/) or
[the Termux GitHub releases](https://github.com/termux/termux-app/releases).)

### Wireless adb (~30 sec total)

Same idea, no cable. On Android 11+: **Settings → Developer options →
Wireless debugging → Pair device with pairing code**. Then on the
laptop:

```bash
adb pair <phone-ip>:<pairing-port>          # type the code
adb connect <phone-ip>:<adb-port>
adb install com.termux_1020.apk
adb install com.termux.boot_1000.apk
adb install com.termux.api_51.apk
```

### From inside Termux (~30 sec, needs one screen tap)

If you only have Termux already installed (not the addons), you can
fetch and install the addon APKs from inside Termux without ADB:

```bash
~/runner-android/contrib/android/install-termux-boot.sh
```

That script downloads the Termux:Boot APK from F-Droid and calls
`termux-open` on it, which fires Android's package installer — you tap
"Install" on the phone screen once. Same pattern works for Termux:API:
just `pkg install termux-api` first (which is a Termux package, that
one IS pkg-installable; the *Android* `com.termux.api` addon is
separate and only needed if you want `termux-wake-lock` to actually
hold a wake lock).

### F-Droid GUI (slowest, several minutes)

Install [F-Droid](https://f-droid.org/) first, search for "Termux",
"Termux:Boot", "Termux:API", tap install on each. Useful if you have
no laptop nearby and the phone is the only device.

## 2. Required one-time taps after addon install

Android refuses to fire `BOOT_COMPLETED` for an app that the user has
never launched. After installing Termux:Boot:

1. **Open the Termux:Boot app once.** It's a single screen with text
   like *"Termux:Boot is intended to be installed alongside Termux..."*
   — just opening it is enough, you don't have to interact.
2. **Open the Termux:API app once** (same reason, only matters if you
   want `termux-wake-lock` to function).

You also need to disable Samsung's aggressive battery optimization for
Termux, otherwise the OS will kill the runner after a few minutes
asleep:

3. **Settings → Apps → Termux → Battery → Unrestricted**.
4. Optional but recommended: **Settings → Device care → Battery →
   Background usage limits → Never sleeping apps → add Termux**.

## 3. SSH access (recommended)

For the rest of the fleet to be operable from your laptop, set up SSH
into the phone:

```bash
# Inside Termux on the phone:
pkg install openssh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# Paste your laptop's public key:
cat >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sshd     # starts on port 8022 by default
```

Add a boot script so sshd survives reboots (this is what the existing
`start-sshd.sh` in `~/.termux/boot/` already does on `asd-phone`):

```bash
cat > ~/.termux/boot/start-sshd.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sshd
EOF
chmod +x ~/.termux/boot/start-sshd.sh
```

Then on your laptop, add to `~/.ssh/config`:

```
Host my-phone
    HostName <phone-ip-or-tailscale-name>
    Port 8022
    User u0_aXXX                       # Termux uid; check `whoami` on the phone
    IdentityFile ~/.ssh/id_ed25519
```

## 4. Installer

With Termux + Termux:Boot + Termux:API installed and tapped-open, the
runner-android installer takes care of the rest:

```bash
# Inside Termux:
pkg install -y git
git clone https://github.com/asd-engineering/runner-android.git
cd runner-android
GITHUB_PAT=ghp_xxx GITHUB_ORG=asd-engineering RUNNER_NAME="$(hostname)" \
    ./contrib/android/install.sh
```

It installs all package deps (.NET 8 SDK, node, golang, clang, jq,
caddy, ttyd, …), builds the runner from source, applies the bionic
patches, registers the runner with `--disableupdate`, drops the boot
symlink at `~/.termux/boot/runner-android.sh`, and starts the watchdog.
Total time on a Note 20 Ultra: ~4 minutes.

See [README.md](README.md) for what the installer is doing under the
hood, the bun-on-Termux warning, and the day-to-day `runner-android-ctl`
commands.

## 5. Verify reboot survival

```bash
# Note the current pids:
~/runner-android/contrib/android/runner-android-ctl status
# → running (listener pid X, watchdog pid Y)

# Reboot the phone (any way you like — power menu, `reboot` from a
# rooted shell, or `adb reboot` from a wired laptop):
adb reboot                              # or use the power button

# After the phone has finished booting, ssh in (or use Termux directly):
ssh my-phone '~/runner-android/contrib/android/runner-android-ctl status'
# → running (listener pid <new>, watchdog pid <new>)   ← within ~30s of boot
```

If `status` reports `stopped`, work backwards:

1. `pm path com.termux.boot` should print a path. If empty, the addon
   is not installed (re-do §1).
2. Open the Termux:Boot app once. If you skipped §2, the receiver is
   still disabled.
3. Check `ls -la ~/.termux/boot/runner-android.sh`. If missing, the
   installer's boot-symlink step was skipped — re-run `install.sh` or
   `runner-android-ctl enable-boot`.
4. Check Samsung battery optimization (§2 step 3). If Termux is in
   "Optimized" mode, the OS killed it before our watchdog could
   establish itself.
5. Tail `~/runner-android/_layout/runner.log` for clues from the
   watchdog itself.

## 6. Bonus: keep the device useful after deploy

- Disable lock screen or set it to "Swipe" so you can see Termux's
  notification at any time.
- Plug in to mains power. The runner will pin a CPU at 100% during
  builds and a phone running on battery for an hour-long code-server
  compile is going to overheat.
- If the phone has a SIM, disable mobile data for Termux to avoid
  surprise data charges from the actions/checkout downloads.
- Tape over the camera. (Not strictly required for runner operation,
  just good hygiene for any device sitting in a server cabinet.)
