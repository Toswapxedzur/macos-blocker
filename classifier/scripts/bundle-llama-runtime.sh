#!/usr/bin/env bash
# Makes an assembled .app self-contained for the on-device engine: copies the
# llama.cpp / ggml runtime (core dylibs + the dlopen'd ggml backends) into
# Contents/Frameworks, rewrites every install name to @rpath so nothing loads
# from Homebrew at runtime, and repoints the app executable. Signing is the
# caller's job (sign inside-out, or `codesign --deep`).
#
# Used by Mac Vault's release build (../../scripts/release/build_app.sh), which
# hosts the classifier, and by the standalone shell packager.
#
# Usage: bundle-llama-runtime.sh <path/to/App.app> <executable name in Contents/MacOS>
set -euo pipefail

app="${1:?app bundle path}"
exe="$app/Contents/MacOS/${2:?executable name}"
[[ -f "$exe" ]] || { echo "error: missing executable $exe" >&2; exit 1; }

llama_prefix="$(brew --prefix llama.cpp 2>/dev/null || true)"
ggml_prefix="$(brew --prefix ggml 2>/dev/null || true)"
if [[ -z "$llama_prefix" || -z "$ggml_prefix" ]]; then
  echo "error: need Homebrew llama.cpp + ggml installed to source the runtime (brew install llama.cpp)." >&2
  exit 1
fi
mkdir -p "$app/Contents/Frameworks"

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
while read -r dep; do
  depbase="$(basename "$dep")"
  [[ -n "${bundled[$depbase]:-}" ]] && install_name_tool -change "$dep" "@rpath/$depbase" "$exe" 2>/dev/null || true
done < <(otool -L "$exe" | tail -n +2 | awk '{print $1}')
install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe" 2>/dev/null || true


if otool -L "$exe" "$fw"/*.dylib "$fw"/*.so | grep -q "/opt/homebrew\|/usr/local/opt"; then
  echo "error: a Homebrew path remains in the load commands:" >&2
  otool -L "$exe" "$fw"/*.dylib "$fw"/*.so | grep "/opt/homebrew\|/usr/local/opt" >&2
  exit 1
fi
echo "[bundle-llama-runtime] $(ls "$fw" | wc -l | tr -d ' ') libraries bundled; no Homebrew paths remain."
