#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
arch="$(/usr/bin/uname -m)"
scratch="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$scratch"' EXIT

app="$scratch/StoreSwitchPOC.app"
mkdir -p "$app/Contents/MacOS" "$scratch/module-cache"
cp "$project/Info.plist" "$app/Contents/Info.plist"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/xcrun --sdk macosx swiftc \
    -sdk "$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$scratch/module-cache" \
    -target "$arch-apple-macosx14.0" \
    -swift-version 5 -warnings-as-errors \
    -framework AppKit -framework ApplicationServices \
    "$project/Sources/App.swift" "$project/Sources/StoreAX.swift" \
    -o "$app/Contents/MacOS/StoreSwitchPOC"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
"$app/Contents/MacOS/StoreSwitchPOC" --self-check
/usr/bin/ditto "$app" "$project/StoreSwitchPOC.app"
printf 'Built %s\n' "$project/StoreSwitchPOC.app"
