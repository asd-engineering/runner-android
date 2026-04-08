#!/data/data/com.termux/files/usr/bin/bash
# Convert a freshly-built _layout/ into one that runs under Termux/bionic on Android.
#
# Why this is needed:
#   - The .NET 8 self-contained linux-arm64 publish bundles glibc-linked native
#     libs (libcoreclr.so, libhostpolicy.so, ...) and an apphost binary whose
#     TLS segment alignment (8) is rejected by ARM64 bionic (requires 64).
#   - The bundled Node.js binaries are glibc-linked and segfault on bionic.
#   - The default config.sh runs ldd against the broken libs and bails.
#
# This script:
#   1. Re-publishes Runner.{Listener,Worker,PluginHost} framework-dependent
#      (no apphost, no bundled native libs) into _layout/bin so they run on
#      Termux's bionic-native dotnet runtime.
#   2. Deletes the leftover glibc-linked .so files and apphost binaries.
#   3. Drops shell shims at bin/Runner.{Listener,Worker,PluginHost} that
#      `exec dotnet *.dll "$@"` so the existing run.sh/JobDispatcher work
#      unchanged.
#   4. Symlinks externals/node{20,24}/bin/node to Termux's system node.
#   5. Disables the glibc dependency probe in config.sh.
#
# Run from the repo root after `cd src && ./dev.sh layout Release linux-arm64`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LAYOUT="$REPO_ROOT/_layout"
SRC="$REPO_ROOT/src"

if [ ! -d "$LAYOUT/bin" ]; then
    echo "error: $LAYOUT/bin not found. Run 'cd src && ./dev.sh layout Release linux-arm64' first." >&2
    exit 1
fi

echo "[1/5] Stripping bionic-incompatible native binaries from _layout/bin..."
cd "$LAYOUT/bin"
rm -f \
    libcoreclr.so libcoreclrtraceptprovider.so libclrjit.so libclrgc.so \
    libhostfxr.so libhostpolicy.so libmscordaccore.so libmscordbi.so \
    libSystem.Globalization.Native.so libSystem.IO.Compression.Native.so \
    libSystem.Native.so libSystem.Net.Security.Native.so \
    libSystem.Security.Cryptography.Native.OpenSsl.so \
    createdump Runner.Listener Runner.Worker Runner.PluginHost

echo "[2/5] Re-publishing runner exes framework-dependent (no apphost)..."
cd "$SRC"
for proj in Runner.Listener Runner.Worker Runner.PluginHost; do
    dotnet publish "$proj/$proj.csproj" \
        -c Release -r linux-arm64 \
        --self-contained false \
        -p:UseAppHost=false \
        -o "$LAYOUT/bin" >/dev/null
    echo "    published $proj"
done

echo "[3/5] Writing dotnet shims for Runner.{Listener,Worker,PluginHost}..."
for exe in Runner.Listener Runner.Worker Runner.PluginHost; do
    cat > "$LAYOUT/bin/$exe" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec dotnet "\$(dirname "\$0")/$exe.dll" "\$@"
EOF
    chmod +x "$LAYOUT/bin/$exe"
done

echo "[4/5] Symlinking Termux node into externals/node{20,24}/bin/node..."
TERMUX_NODE="$(command -v node)"
for v in node20 node24; do
    if [ -d "$LAYOUT/externals/$v/bin" ]; then
        rm -f "$LAYOUT/externals/$v/bin/node"
        ln -s "$TERMUX_NODE" "$LAYOUT/externals/$v/bin/node"
    fi
done

echo "[5/5] Patching _layout/config.sh to skip the glibc ldd probe..."
sed -i 's|if \[\[ (`uname` == "Linux") \]\]|if false|' "$LAYOUT/config.sh"

echo
echo "Done. Verify with: cd $LAYOUT && dotnet ./bin/Runner.Listener.dll --version"
echo "Then register with: ./config.sh --url ... --token ... --name ... --labels self-hosted-android --unattended --disableupdate"
