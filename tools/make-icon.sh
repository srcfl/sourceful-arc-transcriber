#!/bin/bash
# Rasterize Resources/icon-source.svg → Resources/iconfile.icns.
#
# Uses only macOS built-ins (qlmanage + sips + iconutil) — no Homebrew
# deps. Run this any time icon-source.svg changes; commit the resulting
# iconfile.icns so CI / local builds don't need to rasterize.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

SVG="$REPO_ROOT/Resources/icon-source.svg"
ICNS="$REPO_ROOT/Resources/iconfile.icns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$SVG" ]]; then
    echo "Source SVG not found at $SVG" >&2
    exit 1
fi

echo "→ Rasterising SVG at 1024×1024"
# qlmanage renders SVG via WebKit; output is named `<basename>.png`.
qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null
PNG_1024="$TMP/$(basename "$SVG").png"
[[ -f "$PNG_1024" ]] || { echo "qlmanage did not produce $PNG_1024" >&2; exit 1; }

echo "→ Building iconset"
ICONSET="$TMP/iconfile.iconset"
mkdir -p "$ICONSET"
# Apple's iconset layout: base + @2x for every size.
sips -z 16 16     "$PNG_1024" --out "$ICONSET/icon_16x16.png"       >/dev/null
sips -z 32 32     "$PNG_1024" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
sips -z 32 32     "$PNG_1024" --out "$ICONSET/icon_32x32.png"       >/dev/null
sips -z 64 64     "$PNG_1024" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
sips -z 128 128   "$PNG_1024" --out "$ICONSET/icon_128x128.png"     >/dev/null
sips -z 256 256   "$PNG_1024" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
sips -z 256 256   "$PNG_1024" --out "$ICONSET/icon_256x256.png"     >/dev/null
sips -z 512 512   "$PNG_1024" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
sips -z 512 512   "$PNG_1024" --out "$ICONSET/icon_512x512.png"     >/dev/null
cp "$PNG_1024"          "$ICONSET/icon_512x512@2x.png"

echo "→ Packaging iconfile.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

echo
echo "Wrote $ICNS ($(du -h "$ICNS" | cut -f1))"
