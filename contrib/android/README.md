# Android / Termux self-hosted runner

This folder contains the device-specific glue needed to run the GitHub Actions
self-hosted runner on an Android phone (aarch64) under Termux. None of this is
relevant to the upstream `actions/runner` build — keep all changes scoped here
so the rest of the repo stays a clean fork.

## Why a fork is needed

The upstream `linux-arm64` build assumes glibc. Three things break on Termux's
bionic libc:

1. **The .NET apphost binary** (`Runner.Listener`, `Runner.Worker`,
   `Runner.PluginHost`) has an 8-byte-aligned TLS segment; bionic ARM64
   requires 64.
2. **The bundled native runtime libs** (`libcoreclr.so`, `libhostpolicy.so`, …)
   are linked against `libdl.so.2`, which doesn't exist on bionic.
3. **The bundled Node.js** in `externals/node{20,24}` is glibc-linked.

Plus two smaller papercuts:

4. `IOUtil.ValidateExecutePermission` walks parent dirs and trips on
   `/data/data` (mode 0711 by Android design).
5. `config.sh` runs `ldd` against the bundled libs and bails before we get a
   chance to register.

## Repo-level patches (already applied to source)

- `src/global.json` — relaxed SDK pin so the Termux-native `dotnet-sdk-8.0`
  (currently 8.0.125) is accepted instead of the upstream-pinned 8.0.419.
- `src/Runner.Sdk/Util/IOUtil.cs` — `ValidateExecutePermission` treats
  `/`, `/data`, `/data/data` as readable-enough (Termux dirs are mode 0711 by
  Android design and that's not a runner-permissions problem).

## Per-device setup — automated

The fast path on a fresh phone:

```bash
git clone https://github.com/asd-engineering/runner-android.git
cd runner-android
GITHUB_PAT=ghp_xxx GITHUB_ORG=asd-engineering ./contrib/android/install.sh
```

`install.sh` is fully idempotent. It installs Termux packages, stops any
existing runner, wipes `_layout` (stale self-update artifacts have bitten
us before, so we always start clean), builds the layout, applies the
bionic patches, unregisters any prior runner with the same name on the
GitHub side, registers fresh with `--disableupdate`, installs the
Termux:Boot symlink, starts the runner, and polls the GitHub API to
confirm it comes back as `online`.

Three modes:

```bash
# fresh install or full rebuild from current checkout
GITHUB_PAT=ghp_xxx GITHUB_ORG=asd-engineering ./contrib/android/install.sh

# update: git pull then full rebuild + re-register
GITHUB_PAT=ghp_xxx GITHUB_ORG=asd-engineering ./contrib/android/install.sh --update

# uninstall: stop, unregister from GitHub, delete _layout and boot symlink
GITHUB_PAT=ghp_xxx GITHUB_ORG=asd-engineering ./contrib/android/install.sh --uninstall
```

Optional env vars: `RUNNER_NAME` (default `$(hostname)`), `RUNNER_LABELS`
(default `self-hosted-android`), `GITHUB_REPO` (register at repo level
instead of org level — needs `repo` scope on the PAT instead of `admin:org`).

Day-to-day control:

```bash
./contrib/android/runner-android-ctl status        # running (pid …) | stopped
./contrib/android/runner-android-ctl start         # start (idempotent)
./contrib/android/runner-android-ctl stop          # graceful TERM, KILL after 10s
./contrib/android/runner-android-ctl restart
./contrib/android/runner-android-ctl logs          # tail -f the runner log
./contrib/android/runner-android-ctl enable-boot   # symlink into ~/.termux/boot/
./contrib/android/runner-android-ctl disable-boot
```

## Per-device setup — manual

Prereqs: Termux with `pkg install dotnet-sdk-8.0 nodejs git openssl libicu krb5`.

```bash
# 1. Build the layout (downloads glibc node tarballs into _layout — that's OK,
#    we'll overwrite the node binaries in step 2)
cd src
mkdir -p ../_dotnetsdk/8.0.419
ln -sf "$(command -v dotnet)" ../_dotnetsdk/8.0.419/dotnet
touch ../_dotnetsdk/8.0.419/.8.0.419   # bypass dev.sh's SDK auto-installer
./dev.sh layout Release linux-arm64
cd ..

# 2. Apply the bionic patches (re-publish framework-dependent, drop shims,
#    swap node, neuter the ldd probe)
./contrib/android/patch-layout.sh

# 3. Sanity check
cd _layout && dotnet ./bin/Runner.Listener.dll --version   # → 2.333.0

# 4. Register against the org. CRITICAL: --disableupdate, otherwise the
#    runner will self-update on first run and re-deploy the upstream tarball
#    over the patched layout, restoring the bionic-incompatible binaries.
./config.sh \
    --url https://github.com/<org-or-repo> \
    --token <REGISTRATION_TOKEN> \
    --name "$(hostname)" \
    --labels self-hosted-android \
    --unattended --replace --disableupdate
```

Get a registration token (org-level needs `admin:org` PAT):

```bash
curl -sS -X POST \
    -H "Authorization: token $GITHUB_PAT" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/orgs/<org>/actions/runners/registration-token
```

## Auto-start on boot

Requires the [Termux:Boot](https://wiki.termux.com/wiki/Termux:Boot) addon.

```bash
mkdir -p ~/.termux/boot
ln -sf $HOME/runner-android/contrib/android/start-runner.sh \
       ~/.termux/boot/runner-android.sh
```

The boot script:

- waits until Termux is up,
- acquires a wake lock (best-effort, only if `termux-wake-lock` is installed),
- refuses to start a second instance,
- launches `./run.sh` via `nohup setsid` (no runit — `asd-build`'s runit
  setup on this device has been unstable, so we keep this stack flat),
- appends to `_layout/runner.log`.

Manual control:

```bash
# start (also used by Termux:Boot)
~/runner-android/contrib/android/start-runner.sh

# stop
pkill -f Runner.Listener.dll

# tail logs
tail -f ~/runner-android/_layout/runner.log
```

## Caveats

- **No self-update.** When GitHub releases a new runner you must rebuild
  manually: `git pull && cd src && ./dev.sh layout Release linux-arm64 &&
  cd .. && ./contrib/android/patch-layout.sh`.
- **Termux Node is v25.** Most JS actions work; anything with strict
  `engines` may complain. If a specific action breaks, install
  `nodejs-lts` from Termux and point the symlinks at it.
- **No Docker.** `container:` and `services:` workflow keys will not work.
- **Workflows must target the label.** Use
  `runs-on: self-hosted-android`, not `runs-on: self-hosted`, to pin
  Android-specific jobs to this device.
