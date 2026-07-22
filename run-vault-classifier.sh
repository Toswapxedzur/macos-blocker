#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

export CB_PUBLIC_SERVER_URL="${CB_PUBLIC_SERVER_URL:-http://127.0.0.1:8080}"

exec swift run VaultClassifierApp
