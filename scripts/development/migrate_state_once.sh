#!/usr/bin/env bash
set -euo pipefail

migration_root="$HOME/Library/Application Support/AdamanciaVaultDevelopment/Migrations"
marker="$migration_root/mac-vault-environment-v1.done"
if [[ -f "$marker" ]]; then
  exit 0
fi

shared_source="$HOME/Library/Group Containers/group.com.adamancia.vault/macosBlocker"
development_store="$HOME/Library/Application Support/macosBlocker-Development"
state_source="$HOME/Library/Application Support/macosBlocker/state.json"
state_destination="$development_store/state.json"
policy_source="$HOME/Library/Application Support/Blocker/policy.json"
policy_destination="$HOME/Library/Application Support/Blocker-Development/policy.json"
files_source="$HOME/Library/Application Support/MacBlocker/LocalFiles"
files_destination="$HOME/Library/Application Support/MacBlocker-Development/LocalFiles"

if [[ -e "$shared_source" && -e "$development_store" ]]; then
  echo "Both shared and development Mac Vault stores exist; refusing to merge them." >&2
  exit 1
fi
if [[ -e "$shared_source/state.json" && -e "$state_source" ]]; then
  echo "Both App Group and fallback Mac Vault state files exist; refusing to choose or overwrite either." >&2
  exit 1
fi
if [[ -e "$state_source" && -e "$state_destination" ]]; then
  echo "Both shared and development Mac Vault state files exist; refusing to overwrite either." >&2
  exit 1
fi
if [[ -e "$policy_source" && -e "$policy_destination" ]]; then
  echo "Both shared and development policy files exist; refusing to overwrite either." >&2
  exit 1
fi
if [[ -e "$files_source" && -e "$files_destination" ]]; then
  echo "Both shared and development local-file stores exist; refusing to overwrite either." >&2
  exit 1
fi

if [[ -e "$shared_source" ]]; then
  mkdir -p "$(dirname "$development_store")"
  mv "$shared_source" "$development_store"
else
  mkdir -p "$development_store"
fi

if [[ -e "$state_source" ]]; then
  mv "$state_source" "$state_destination"
  rmdir "$(dirname "$state_source")" 2>/dev/null || true
fi
if [[ -e "$policy_source" ]]; then
  mkdir -p "$(dirname "$policy_destination")"
  mv "$policy_source" "$policy_destination"
  rmdir "$(dirname "$policy_source")" 2>/dev/null || true
fi
if [[ -e "$files_source" ]]; then
  mkdir -p "$(dirname "$files_destination")"
  mv "$files_source" "$files_destination"
  rmdir "$(dirname "$files_source")" 2>/dev/null || true
fi

mkdir -p "$migration_root"
touch "$marker"
