#!/usr/bin/env bash
# Regenerates the website demo images: draws original sample captures, then beautifies
# them with Glint's own CLI. Needs a built Glint.app (defaults to dist/, then /Applications).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BIN="${GLINT_BIN:-}"
for candidate in dist/Glint.app/Contents/MacOS/Glint /Applications/Glint.app/Contents/MacOS/Glint; do
    [[ -z "$APP_BIN" && -x "$candidate" ]] && APP_BIN="$candidate"
done
[[ -x "$APP_BIN" ]] || { echo "Glint binary not found; run 'make app' or set GLINT_BIN" >&2; exit 1; }
command -v cwebp >/dev/null || { echo "cwebp is required (brew install webp)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT=site/assets
mkdir -p "$OUT"

swift Scripts/make_site_assets.swift "$WORK/src"

# Isolated home so a developer's own presets never leak into the published images.
export CFFIXED_USER_HOME="$WORK/home"
mkdir -p "$CFFIXED_USER_HOME"

render() { # src preset name
    "$APP_BIN" --render "$WORK/src/$1.png" "$WORK/$3.png" --preset "$2" --scale 2
    cwebp -quiet -q 86 -alpha_q 90 "$WORK/$3.png" -o "$OUT/$3.webp"
}

cwebp -quiet -q 90 "$WORK/src/terminal.png" -o "$OUT/terminal-raw.webp"
render terminal "Default" terminal-default
render terminal "Social 16:9" terminal-social
render terminal "Clean" terminal-clean
render terminal "Transparent" terminal-transparent
render dashboard "Default" dashboard-default
render dashboard "Clean" dashboard-clean

sips -s format jpeg -Z 1200 "$WORK/terminal-social.png" --out "$OUT/og.jpg" >/dev/null
sips -z 64 64 docs/assets/icon-1024.png --out site/favicon.png >/dev/null
sips -z 180 180 docs/assets/icon-1024.png --out site/apple-touch-icon.png >/dev/null
cwebp -quiet -resize 256 256 docs/assets/icon-1024.png -o "$OUT/icon-256.webp"

ls -l "$OUT"
