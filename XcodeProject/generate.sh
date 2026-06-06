#!/usr/bin/env bash
#
# Generates macosBlocker.xcodeproj (app + 3 Screen Time extensions, wired to the
# shared Swift package) from project.yml using XcodeGen.
#
# Usage:
#   ./generate.sh
#
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is not installed."
  if command -v brew >/dev/null 2>&1; then
    echo "Installing via Homebrew..."
    brew install xcodegen
  else
    echo
    echo "Install it one of these ways, then re-run:"
    echo "  brew install xcodegen"
    echo "  mint install yonaskolb/XcodeGen"
    echo "  https://github.com/yonaskolb/XcodeGen#installing"
    exit 1
  fi
fi

xcodegen generate --spec project.yml
echo
echo "Generated macosBlocker.xcodeproj"
echo "Open it with:  open macosBlocker.xcodeproj"
echo
echo "Next steps in Xcode:"
echo "  1. Select each target -> Signing & Capabilities -> set your Team."
echo "  2. Confirm Family Controls + App Groups capabilities are present."
echo "  3. Replace the App Group 'group.com.example.macosBlocker' everywhere"
echo "     (XcodeScaffold/Shared/AppGroupIdentifier.swift + both .entitlements)."
echo "  4. Run on a real device (Screen Time shields do not work in Simulator)."
