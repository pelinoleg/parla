#!/bin/bash
# Installs (or updates) the latest Parla into /Applications.
set -euo pipefail

REPO="pelinoleg/parla"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Ask the API for the newest tag — the /latest/download redirect can lag behind for a few minutes.
TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
echo "↓ Downloading Parla ${TAG}…"
curl -fsSL "https://github.com/$REPO/releases/download/$TAG/Parla.zip" -o "$TMP/Parla.zip"

pkill -x Parla 2>/dev/null || true
rm -rf /Applications/Parla.app
ditto -x -k "$TMP/Parla.zip" /Applications
xattr -dr com.apple.quarantine /Applications/Parla.app 2>/dev/null || true

open /Applications/Parla.app
echo "✓ Parla ${TAG} installed — look for the speech bubble in the menu bar."
