#!/usr/bin/env bash
#
# build_app.sh - build the Glint SwiftPM product and assemble dist/Glint.app.
#
# Usage:
#   Scripts/build_app.sh [--universal] [--require-universal] [--version X.Y.Z]
#                        [--build-number N] [--configuration release|debug]
#
#   --universal           Build arm64 and x86_64 separately (--triple) and merge them with
#                         lipo. If the x86_64 build fails, fall back to an arm64-only app.
#   --require-universal   Make that fallback an error (implies --universal).
#   --version X.Y.Z       CFBundleShortVersionString. Default: the contents of VERSION.
#   --build-number N      CFBundleVersion. Default: $GITHUB_RUN_NUMBER, else the git commit
#                         count, else 1.
#   --configuration C     release (default) or debug.
#
# Environment:
#   GLINT_SIGN_IDENTITY   codesign identity (name or SHA-1). Default "-" (ad-hoc). A real
#                         identity also turns on the hardened runtime and a secure timestamp.
#   GLINT_REQUIRE_STABLE_SIGNATURE
#                         1 = fail unless the app is signed with a certificate (not ad-hoc) and,
#                         when packaging/signing/designated-requirement.txt (or
#                         $GLINT_REQUIREMENT_FILE) exists, satisfies that requirement
#                         (Scripts/verify_signature.sh --require-stable). Releases set this.
#   SWIFTW_BUILD_SYSTEM   SwiftPM build system. Default "native": per-architecture --triple
#                         builds merged with lipo behave the same on every toolchain there
#                         (see Scripts/swiftw.sh).
#
# macOS keys privacy permissions such as Screen Recording to the app's designated requirement.
# Releases use Apple Developer ID (packaging/signing/README.md), with a team-based requirement
# that survives certificate renewal. The migration from self-signed releases needs a one-time
# permission re-grant. Local builds are signed ad-hoc unless
# GLINT_SIGN_IDENTITY is set; an ad-hoc requirement pins one build's cdhash, so permissions have
# to be granted again after every rebuild.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

PRODUCT=Glint
DIST="$ROOT/dist"
APP="$DIST/$PRODUCT.app"
PLIST_SRC="$ROOT/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Resources/Glint.entitlements"
ICON_SRC="$ROOT/Resources/AppIcon.icns"
SWIFTW="$ROOT/Scripts/swiftw.sh"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/build_app.sh [--universal] [--require-universal] [--version X.Y.Z]
                            [--build-number N] [--configuration release|debug]

Builds the Glint SwiftPM product and assembles dist/Glint.app, signed ad-hoc unless
GLINT_SIGN_IDENTITY names a certificate (releases use Developer ID Application).

  --universal           arm64 + x86_64 slices merged with lipo (falls back to arm64 only
                        if the x86_64 build fails)
  --require-universal   fail instead of falling back (implies --universal)
  --version X.Y.Z       app version (default: contents of VERSION)
  --build-number N      CFBundleVersion (default: $GITHUB_RUN_NUMBER, git commit count, or 1)
  --configuration C     release (default) or debug

Environment: GLINT_SIGN_IDENTITY (default "-", ad-hoc), GLINT_REQUIRE_STABLE_SIGNATURE=1
(fail on an ad-hoc signature), SWIFTW_BUILD_SYSTEM (default native).
EOF
}

UNIVERSAL=0
REQUIRE_UNIVERSAL=0
CONFIG=release
VERSION=""
BUILD_NUMBER=""

while (($#)); do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --require-universal)
      UNIVERSAL=1
      REQUIRE_UNIVERSAL=1
      ;;
    --version)
      VERSION="${2:?--version needs a value}"
      shift
      ;;
    --version=*) VERSION="${1#*=}" ;;
    --build-number)
      BUILD_NUMBER="${2:?--build-number needs a value}"
      shift
      ;;
    --build-number=*) BUILD_NUMBER="${1#*=}" ;;
    --configuration | -c)
      CONFIG="${2:?--configuration needs a value}"
      shift
      ;;
    --configuration=*) CONFIG="${1#*=}" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

case "$CONFIG" in
  release | debug) ;;
  *) die "invalid configuration '$CONFIG' (expected release or debug)" ;;
esac

if [[ -z "$VERSION" ]]; then
  [[ -f "$ROOT/VERSION" ]] || die "no --version given and VERSION file not found"
  VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
fi
VERSION="${VERSION#v}"
version_re='^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?$'
[[ $VERSION =~ $version_re ]] || die "invalid version '$VERSION' (expected e.g. 1.2.3 or 1.2.3-beta.1)"

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="${GITHUB_RUN_NUMBER:-}"
fi
if [[ -z "$BUILD_NUMBER" && "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)" == "$ROOT" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
fi
BUILD_NUMBER="${BUILD_NUMBER:-1}"
build_re='^[0-9]+(\.[0-9]+){0,2}$'
[[ $BUILD_NUMBER =~ $build_re ]] || die "invalid build number '$BUILD_NUMBER' (digits and dots only)"

[[ -f "$PLIST_SRC" ]] || die "missing $PLIST_SRC"
[[ -f "$ENTITLEMENTS" ]] || die "missing $ENTITLEMENTS"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST_SRC")" == "$PRODUCT" ]] \
  || die "CFBundleExecutable in Resources/Info.plist must be $PRODUCT"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST_SRC")"

SIGN_IDENTITY="${GLINT_SIGN_IDENTITY:--}"
REQUIRE_STABLE=0
case "${GLINT_REQUIRE_STABLE_SIGNATURE:-}" in
  1 | true | yes) REQUIRE_STABLE=1 ;;
esac
if ((REQUIRE_STABLE)) && [[ "$SIGN_IDENTITY" == "-" ]]; then
  die "GLINT_REQUIRE_STABLE_SIGNATURE is set but GLINT_SIGN_IDENTITY is empty or ad-hoc: an ad-hoc release makes every user re-grant Screen Recording after updating (#39). Import the release identity (Scripts/import_signing_identity.sh) and pass its SHA-1."
fi

export SWIFTW_BUILD_SYSTEM="${SWIFTW_BUILD_SYSTEM:-native}"

# build_slice [arch]: builds every target for one architecture (host arch when empty).
# On success SLICE_BIN_DIR points at the directory holding the executable and resource bundles.
SLICE_BIN_DIR=""
build_slice() {
  local arch="${1:-}"
  local flags=(-c "$CONFIG")
  if [[ -n "$arch" ]]; then
    flags+=(--triple "${arch}-apple-macosx${MIN_MACOS}")
  fi
  log "swift build ${flags[*]}"
  "$SWIFTW" build "${flags[@]}" || return 1
  SLICE_BIN_DIR="$("$SWIFTW" build "${flags[@]}" --show-bin-path 2>/dev/null)" || return 1
  [[ -x "$SLICE_BIN_DIR/$PRODUCT" ]] || {
    warn "no $PRODUCT executable in $SLICE_BIN_DIR"
    return 1
  }
  if [[ -n "$arch" && " $(lipo -archs "$SLICE_BIN_DIR/$PRODUCT" 2>/dev/null) " != *" $arch "* ]]; then
    warn "$SLICE_BIN_DIR/$PRODUCT is not an $arch binary"
    return 1
  fi
}

ARM_DIR=""
X86_DIR=""
RESOURCE_DIR=""

if ((UNIVERSAL)); then
  build_slice arm64 || die "the arm64 build failed"
  ARM_DIR="$SLICE_BIN_DIR"
  RESOURCE_DIR="$ARM_DIR"
  if build_slice x86_64; then
    X86_DIR="$SLICE_BIN_DIR"
  elif ((REQUIRE_UNIVERSAL)); then
    die "the x86_64 build failed and --require-universal was given"
  else
    warn "the x86_64 build failed (see the errors above)."
    warn "Continuing with an arm64-only app; pass --require-universal to make this fatal."
  fi
else
  build_slice || die "the build failed"
  RESOURCE_DIR="$SLICE_BIN_DIR"
fi

log "Assembling ${APP#"$ROOT"/}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ -n "$X86_DIR" ]]; then
  lipo -create "$ARM_DIR/$PRODUCT" "$X86_DIR/$PRODUCT" -output "$APP/Contents/MacOS/$PRODUCT"
else
  cp "$RESOURCE_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
fi
chmod 755 "$APP/Contents/MacOS/$PRODUCT"

PLIST="$APP/Contents/Info.plist"
cp "$PLIST_SRC" "$PLIST"
set_plist_string() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}
set_plist_string CFBundleShortVersionString "$VERSION"
set_plist_string CFBundleVersion "$BUILD_NUMBER"
plutil -lint "$PLIST" >/dev/null
printf 'APPL????' >"$APP/Contents/PkgInfo"

if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
else
  warn "Resources/AppIcon.icns not found (run 'make icon'); the app will have no icon"
fi

# SwiftPM puts one <Package>_<Target>.bundle next to the executable for every target with
# resources; Bundle.module looks for them in Contents/Resources of the app.
bundles=0
for bundle in "$RESOURCE_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
  bundles=$((bundles + 1))
done
log "Copied $bundles SwiftPM resource bundle(s)"

sign_flags=(--force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  sign_flags+=(--timestamp=none)
  log "Signing ad-hoc (privacy permissions such as Screen Recording must be re-granted after every rebuild)"
else
  sign_flags+=(--options runtime --timestamp)
  log "Signing with '$SIGN_IDENTITY' (hardened runtime)"
fi
xattr -cr "$APP"
codesign "${sign_flags[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
log "Designated requirement: $(codesign --display --requirements - "$APP" 2>&1 | sed -n 's/^[# ]*designated => //p')"
if ((REQUIRE_STABLE)); then
  "$ROOT/Scripts/verify_signature.sh" "$APP" --require-stable
fi

archs="$(lipo -archs "$APP/Contents/MacOS/$PRODUCT")"
if ((UNIVERSAL)) && [[ -z "$X86_DIR" ]]; then
  archs="$archs (arm64 only: the x86_64 build failed)"
fi
log "Built ${APP#"$ROOT"/}  version $VERSION ($BUILD_NUMBER)  archs: $archs  size: $(du -sh "$APP" | cut -f1)"
