#!/bin/zsh
set -euo pipefail

app="${1:-build/Release/Beepbar.app}"
codesign --verify --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1 | rg -q '^Authority=Apple Development:'
file "$app/Contents/MacOS/Beepbar" | rg -q 'arm64'
