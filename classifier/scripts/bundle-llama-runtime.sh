#!/usr/bin/env bash
# Bundle only the pinned, verified source runtime; stock macOS Bash 3.2 works.
set -euo pipefail
app="${1:?app bundle path}"
exe="$app/Contents/MacOS/${2:?executable name}"
[[ -f "$exe" ]] || { echo "error: missing executable $exe" >&2; exit 1; }
prefix="${VAULT_LLAMA_PREFIX:?set VAULT_LLAMA_PREFIX to the pinned source runtime}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
architecture="$(lipo -archs "$exe")"
python3 "$root/scripts/release/verify-macos-runtime.py" --prefix "$prefix" --architecture "$architecture"
fw="$app/Contents/Frameworks"
mkdir -p "$fw"
shopt -s nullglob
libs=("$prefix/lib/libllama.0.dylib" "$prefix/lib/libggml.0.dylib" "$prefix/lib/libggml-base.0.dylib" "$prefix/lib/libomp.dylib" "$prefix/lib"/libggml-*.so)
for library in "${libs[@]}"; do
  cp -L "$library" "$fw/$(basename "$library")"
done
chmod u+w "$fw"/*
# Basename membership uses file checks instead of Bash 4 associative arrays.
for library in "$fw"/*.dylib "$fw"/*.so; do
  base="$(basename "$library")"
  install_name_tool -id "@rpath/$base" "$library"
  while read -r dependency; do
    depbase="$(basename "$dependency")"
    if [[ -f "$fw/$depbase" && "$dependency" != "@rpath/$depbase" ]]; then
      install_name_tool -change "$dependency" "@rpath/$depbase" "$library"
    fi
  done < <(otool -L "$library" | tail -n +2 | awk '{print $1}')
  if ! otool -l "$library" | grep -A 2 LC_RPATH | grep -q 'path @loader_path (offset'; then
    install_name_tool -add_rpath "@loader_path" "$library"
  fi
done
while read -r dependency; do
  depbase="$(basename "$dependency")"
  if [[ -f "$fw/$depbase" && "$dependency" != "@rpath/$depbase" ]]; then
    install_name_tool -change "$dependency" "@rpath/$depbase" "$exe"
  fi
done < <(otool -L "$exe" | tail -n +2 | awk '{print $1}')
if ! otool -l "$exe" | grep -A 2 LC_RPATH | grep -q 'path @executable_path/../Frameworks (offset'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe"
fi
notices="$app/Contents/Resources/ThirdPartyNotices"
mkdir -p "$notices"
cp "$prefix/share/vault-notices/"* "$notices/"
cp "$prefix/vault-runtime.json" "$notices/build-receipt.json"
echo "[bundle-llama-runtime] ${#libs[@]} pinned libraries and notices bundled."
