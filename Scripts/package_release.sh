#!/usr/bin/env bash
#
# package_release.sh - build a universal Glint.app and package it for release.
#
# Usage:
#   Scripts/package_release.sh [--version X.Y.Z] [--formats zip,dmg] [--build-number N]
#                              [--require-universal] [--skip-build]
#
#   --version X.Y.Z       Release version. Default: the contents of VERSION.
#   --formats LIST        Comma-separated: zip, dmg. Default: zip,dmg.
#   --build-number N      CFBundleVersion, passed to build_app.sh.
#   --require-universal   Fail when the x86_64 slice cannot be built instead of shipping an
#                         arm64-only app.
#   --skip-build          Package the existing dist/Glint.app (its version must match).
#
# Outputs, all in dist/:
#   Glint-<v>.zip       + Glint-<v>.zip.sha256     (ditto archive; what the Homebrew cask installs)
#   Glint-<v>.dmg       + Glint-<v>.dmg.sha256     (drag-to-Applications disk image)
#   glint.rb                                       (Homebrew cask for the zip, when it is built)
#
# Every requested format has to succeed, otherwise the script exits non-zero.
#
# Environment: GLINT_SIGN_IDENTITY and GLINT_REQUIRE_STABLE_SIGNATURE (see build_app.sh). With
# GLINT_REQUIRE_STABLE_SIGNATURE=1 the app and the app unpacked from the zip must carry the stable
# "Glint Release Signing" signature (Scripts/verify_signature.sh --require-stable), so macOS keeps
# Screen Recording permission across the update. Releases set both.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/Glint.app"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/package_release.sh [--version X.Y.Z] [--formats zip,dmg] [--build-number N]
                                  [--require-universal] [--skip-build]

Builds a universal dist/Glint.app and packages it:
  dist/Glint-<v>.zip + .sha256, dist/Glint-<v>.dmg + .sha256, dist/glint.rb (Homebrew cask)

  --version X.Y.Z       release version (default: contents of VERSION)
  --formats LIST        comma-separated: zip, dmg (default: zip,dmg)
  --build-number N      CFBundleVersion (default: $GITHUB_RUN_NUMBER, git commit count, or 1)
  --require-universal   fail instead of shipping an arm64-only app
  --skip-build          package the existing dist/Glint.app

Environment: GLINT_SIGN_IDENTITY, GLINT_REQUIRE_STABLE_SIGNATURE=1 (fail on an ad-hoc signature).
EOF
}

VERSION=""
FORMATS="zip,dmg"
BUILD_NUMBER=""
REQUIRE_UNIVERSAL=0
SKIP_BUILD=0

while (($#)); do
  case "$1" in
    --version)
      VERSION="${2:?--version needs a value}"
      shift
      ;;
    --version=*) VERSION="${1#*=}" ;;
    --formats)
      FORMATS="${2:?--formats needs a value}"
      shift
      ;;
    --formats=*) FORMATS="${1#*=}" ;;
    --build-number)
      BUILD_NUMBER="${2:?--build-number needs a value}"
      shift
      ;;
    --build-number=*) BUILD_NUMBER="${1#*=}" ;;
    --require-universal) REQUIRE_UNIVERSAL=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

if [[ -z "$VERSION" ]]; then
  [[ -f "$ROOT/VERSION" ]] || die "no --version given and VERSION file not found"
  VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
fi
VERSION="${VERSION#v}"
version_re='^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?$'
[[ $VERSION =~ $version_re ]] || die "invalid version '$VERSION' (expected e.g. 1.2.3 or 1.2.3-beta.1)"

WANT_ZIP=0
WANT_DMG=0
IFS=',' read -r -a format_list <<<"$FORMATS"
for format in "${format_list[@]}"; do
  case "$format" in
    zip) WANT_ZIP=1 ;;
    dmg) WANT_DMG=1 ;;
    *) die "unknown format '$format' (expected zip and/or dmg)" ;;
  esac
done
((WANT_ZIP || WANT_DMG)) || die "no formats requested"

REQUIRE_STABLE=0
case "${GLINT_REQUIRE_STABLE_SIGNATURE:-}" in
  1 | true | yes) REQUIRE_STABLE=1 ;;
esac
if ((REQUIRE_STABLE)) && [[ "${GLINT_SIGN_IDENTITY:--}" == "-" ]]; then
  die "GLINT_REQUIRE_STABLE_SIGNATURE is set but GLINT_SIGN_IDENTITY is empty or ad-hoc: an ad-hoc release makes every user re-grant Screen Recording after updating (#39)"
fi

# verify_stable APP: the release signature check (see Scripts/verify_signature.sh).
verify_stable() {
  if ((REQUIRE_STABLE)); then
    "$ROOT/Scripts/verify_signature.sh" "$1" --require-stable
  fi
}

ZIP="$DIST/Glint-$VERSION.zip"
DMG="$DIST/Glint-$VERSION.dmg"
STAGE="$DIST/dmg-stage"
VERIFY_DIR="$DIST/zip-verify"

if ((SKIP_BUILD)); then
  [[ -d "$APP" ]] || die "--skip-build was given but $APP does not exist"
else
  build_args=(--universal --configuration release --version "$VERSION")
  if [[ -n "$BUILD_NUMBER" ]]; then
    build_args+=(--build-number "$BUILD_NUMBER")
  fi
  if ((REQUIRE_UNIVERSAL)); then
    build_args+=(--require-universal)
  fi
  "$ROOT/Scripts/build_app.sh" "${build_args[@]}"
fi

built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$built_version" == "$VERSION" ]] \
  || die "$APP is version $built_version, expected $VERSION (rebuild without --skip-build)"
codesign --verify --deep --strict "$APP" || die "$APP has an invalid code signature"
verify_stable "$APP"

archs="$(lipo -archs "$APP/Contents/MacOS/Glint")"
if ((REQUIRE_UNIVERSAL)) && [[ " $archs " != *" x86_64 "* || " $archs " != *" arm64 "* ]]; then
  die "the app is not universal (archs: $archs)"
fi
log "Packaging Glint $VERSION (archs: $archs)"

write_checksum() {
  local file="$1"
  (cd "$(dirname "$file")" && shasum -a 256 "$(basename "$file")" >"$(basename "$file").sha256")
}

if ((WANT_ZIP)); then
  log "Creating ${ZIP#"$ROOT"/}"
  rm -f "$ZIP" "$ZIP.sha256"
  # --norsrc/--noextattr keep macOS provenance attributes out of the archive; they would
  # otherwise become ._* entries that plain `unzip` extracts into the signed bundle.
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  write_checksum "$ZIP"
  if unzip -Z1 "$ZIP" | grep -Eq '(^|/)\._|^__MACOSX/'; then
    die "${ZIP#"$ROOT"/} contains AppleDouble (._*) entries"
  fi

  # The archive must unpack (with plain unzip, as Homebrew does) into an intact signed bundle.
  rm -rf "$VERIFY_DIR"
  mkdir -p "$VERIFY_DIR"
  unzip -q "$ZIP" -d "$VERIFY_DIR"
  codesign --verify --deep --strict "$VERIFY_DIR/Glint.app" \
    || die "the app extracted from ${ZIP#"$ROOT"/} fails signature verification"
  verify_stable "$VERIFY_DIR/Glint.app"
  rm -rf "$VERIFY_DIR"
fi

if ((WANT_DMG)); then
  log "Creating ${DMG#"$ROOT"/}"
  rm -rf "$STAGE"
  rm -f "$DMG" "$DMG.sha256"
  mkdir -p "$STAGE"
  ditto --norsrc --noextattr "$APP" "$STAGE/Glint.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Glint $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$DMG"
  rm -rf "$STAGE"
  if [[ -n "${GLINT_SIGN_IDENTITY:-}" && "$GLINT_SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$GLINT_SIGN_IDENTITY" --timestamp "$DMG"
  fi
  hdiutil verify -quiet "$DMG" || die "${DMG#"$ROOT"/} failed hdiutil verify"
  write_checksum "$DMG"
fi

if ((WANT_ZIP)); then
  "$ROOT/Scripts/render_cask.sh" --version "$VERSION" --zip "$ZIP" --output "$DIST/glint.rb"
fi

log "Release artifacts for Glint $VERSION"
for artifact in "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256" "$DIST/glint.rb"; do
  [[ -f "$artifact" ]] || continue
  printf '    %-28s %6s\n' "${artifact#"$ROOT"/}" "$(du -h "$artifact" | cut -f1)"
done
if ((WANT_ZIP)); then
  printf '    sha256 (zip): %s\n' "$(cut -d' ' -f1 "$ZIP.sha256")"
fi
