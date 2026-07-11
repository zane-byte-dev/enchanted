#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$(mktemp -t enchanted-warnings.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

cd "$ROOT"

if ! xcodebuild -quiet \
    -project Enchanted.xcodeproj \
    -scheme Enchanted \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    clean build >"$LOG" 2>&1; then
    cat "$LOG"
    exit 1
fi

if grep -q 'warning:' "$LOG"; then
    echo "Build produced warnings:"
    grep 'warning:' "$LOG"
    exit 1
fi

echo "Build passed with 0 warnings."
