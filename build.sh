#!/bin/bash
# Builds a universal Parla.app and dist/Parla.zip.
# Signing: with SIGN_P12 (path to .p12) and SIGN_PASS set, signs with that stable identity so macOS keeps
# Accessibility permission and Keychain access across updates. Otherwise signs ad-hoc (fine for local tests).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)}"
VERSION="${VERSION#v}"

swift build -c release --arch arm64 --arch x86_64

APP=dist/Parla.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Parla "$APP/Contents/MacOS/Parla"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

if [[ -n "${SIGN_P12:-}" && -n "${SIGN_PASS:-}" ]]; then
    KC="$PWD/.build/signing.keychain-db"
    rm -f "$KC"
    security create-keychain -p parla "$KC"
    security set-keychain-settings "$KC"
    security unlock-keychain -p parla "$KC"
    security import "$SIGN_P12" -k "$KC" -P "$SIGN_PASS" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k parla "$KC" >/dev/null
    IDENTITY=$(security find-identity -p codesigning "$KC" | awk '/\)/ {print $2; exit}')
    # codesign only looks at keychains in the search list — add ours temporarily.
    OLD_LIST=$(security list-keychains -d user | tr -d '"')
    security list-keychains -d user -s "$KC" $OLD_LIST
    trap 'security list-keychains -d user -s $OLD_LIST; security delete-keychain "$KC" 2>/dev/null || true' EXIT
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign -dr - "$APP" 2>&1 | tail -1

(cd dist && ditto -c -k --keepParent Parla.app Parla.zip)
echo "Built $APP ($VERSION)"
