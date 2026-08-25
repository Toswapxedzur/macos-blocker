#!/usr/bin/env bash
# Package Vault Classifier into a self-contained, signed macOS .app.
#
# Bundles the llama.cpp / ggml runtime (core dylibs + ggml Metal/CPU/BLAS
# backends) inside the app, rewrites their install names to @rpath so nothing
# is loaded from /opt/homebrew at runtime, includes the production native
# messaging host, and code-signs the result. Build-time still needs Homebrew's
# llama.cpp/ggml (the source of the libraries); the produced .app does not.
#
# Signing: ad-hoc by default. Set VAULT_CLASSIFIER_SIGNING_IDENTITY to a
# "Developer ID Application" identity for a distributable (still un-notarized)
# build; notarization is a separate `xcrun notarytool` step documented in the
# release notes.
#
# Usage:
#   scripts/package-macapp.sh [output_dir]      # default: ./dist
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$script_dir"

out_dir="${1:-$script_dir/dist}"
app_name="Vault Classifier"
app="$out_dir/$app_name.app"
bundle_id="com.adamancia.vault.classifier"
version="$(git -C "$script_dir" describe --tags --always 2>/dev/null || echo "0.0.0")"

llama_prefix="$(brew --prefix llama.cpp 2>/dev/null || true)"
ggml_prefix="$(brew --prefix ggml 2>/dev/null || true)"
if [[ -z "$llama_prefix" || -z "$ggml_prefix" ]]; then
  echo "error: need Homebrew llama.cpp + ggml installed to source the runtime (brew install llama.cpp)." >&2
  exit 1
fi

sign_identity="${VAULT_CLASSIFIER_SIGNING_IDENTITY:--}"   # '-' = ad-hoc
echo "• signing identity: ${sign_identity/-/ad-hoc}"

echo "• building release (production)…"
swift build -c release --product VaultClassifierApp >/dev/null
swift build -c release --product VaultLocalHubNativeHost >/dev/null   # production env (no -D dev flag)
bin="$(swift build -c release --show-bin-path)"

echo "• assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"

# --- Info.plist ---------------------------------------------------------------
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$app_name</string>
  <key>CFBundleDisplayName</key><string>$app_name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleExecutable</key><string>VaultClassifierApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# --- executables --------------------------------------------------------------
cp "$bin/VaultClassifierApp" "$app/Contents/MacOS/VaultClassifierApp"
cp "$bin/VaultLocalHubNativeHost" "$app/Contents/MacOS/VaultLocalHubNativeHost"

# --- SwiftPM resource bundles (WebAssets, Core Resources) ---------------------
shopt -s nullglob
for b in "$bin"/*.bundle; do cp -R "$b" "$app/Contents/Resources/"; done
shopt -u nullglob

# --- runtime libraries --------------------------------------------------------
fw="$app/Contents/Frameworks"
libs=(
  "$llama_prefix/lib/libllama.0.dylib"
  "$ggml_prefix/lib/libggml.0.dylib"
  "$ggml_prefix/lib/libggml-base.0.dylib"
)
# OpenMP: a shared dependency of the ggml CPU/BLAS backends.
libomp="$(brew --prefix libomp 2>/dev/null || true)/lib/libomp.dylib"
[[ -f "$libomp" ]] && libs+=("$libomp")
for d in "${libs[@]}"; do cp "$d" "$fw/$(basename "$d")"; done
# ggml backends (dlopen'd by ggml_backend_load_all_from_path at runtime)
for b in "$ggml_prefix"/libexec/libggml-*.so; do cp "$b" "$fw/$(basename "$b")"; done
chmod u+w "$fw"/*

# Every dependency whose basename we bundled is repointed to @rpath, so nothing
# resolves from Homebrew. This handles all interdependencies generically
# (llama→ggml→ggml-base, backends→ggml-base, backends→libomp, …).
declare -A bundled
for f in "$fw"/*; do bundled["$(basename "$f")"]=1; done
for f in "$fw"/*.dylib "$fw"/*.so; do
  base="$(basename "$f")"
  install_name_tool -id "@rpath/$base" "$f" 2>/dev/null || true
  while read -r dep; do
    depbase="$(basename "$dep")"
    if [[ -n "${bundled[$depbase]:-}" && "$dep" != "@rpath/$depbase" ]]; then
      install_name_tool -change "$dep" "@rpath/$depbase" "$f" 2>/dev/null || true
    fi
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
  # Backends carry an @loader_path/../lib rpath (Homebrew's lib+libexec layout);
  # here everything is flat in Frameworks, so resolve @rpath beside the backend.
  if [[ "$base" == *.so ]]; then
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
    install_name_tool -delete_rpath "@loader_path/../lib" "$f" 2>/dev/null || true
  fi
done

# --- app executable: repoint bundled deps to @rpath, add Frameworks rpath ------
exe="$app/Contents/MacOS/VaultClassifierApp"
while read -r dep; do
  depbase="$(basename "$dep")"
  [[ -n "${bundled[$depbase]:-}" ]] && install_name_tool -change "$dep" "@rpath/$depbase" "$exe" 2>/dev/null || true
done < <(otool -L "$exe" | tail -n +2 | awk '{print $1}')
install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe" 2>/dev/null || true

# --- production native-messaging-host manifest (points into the bundle) -------
manifest_dir="$app/Contents/Resources"
native_host_path="$app/Contents/MacOS/VaultLocalHubNativeHost"
sed "s|__ABSOLUTE_PATH_TO_VAULT_LOCAL_HUB_NATIVE_HOST__|$native_host_path|g" \
  "$script_dir/native-host/com.adamancia.vault.local_hub.json.template" \
  > "$manifest_dir/com.adamancia.vault.local_hub.json"

# --- code signing (inside-out) ------------------------------------------------
echo "• signing…"
for f in "$fw"/*.dylib "$fw"/*.so "$app/Contents/MacOS/VaultLocalHubNativeHost"; do
  codesign --force --timestamp=none --sign "$sign_identity" "$f"
done
codesign --force --timestamp=none --options runtime \
  --entitlements "$script_dir/native-host/vault-classifier.entitlements" \
  --sign "$sign_identity" "$exe" 2>/dev/null \
  || codesign --force --timestamp=none --sign "$sign_identity" "$exe"
codesign --force --timestamp=none --sign "$sign_identity" "$app"

echo "• verifying self-containment (no /opt/homebrew load commands)…"
if otool -L "$exe" "$fw"/*.dylib "$fw"/*.so | grep -q "/opt/homebrew\|/usr/local/opt"; then
  echo "  WARNING: a Homebrew path remains in the load commands:" >&2
  otool -L "$exe" "$fw"/*.dylib "$fw"/*.so | grep "/opt/homebrew\|/usr/local/opt" >&2
else
  echo "  ✓ no Homebrew paths remain."
fi

echo ""
echo "✓ built $app  (version $version)"
echo "  To register the browser native host for this build, copy"
echo "  $manifest_dir/com.adamancia.vault.local_hub.json into each browser's"
echo "  NativeMessagingHosts directory (an installer step)."
