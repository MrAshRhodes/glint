#!/usr/bin/env bash
#
# check_signing_continuity.sh - prove that an update keeps the permissions granted to the previous
# build, the way macOS checks it.
#
# Usage:
#   Scripts/check_signing_continuity.sh [--previous APP] [--configuration release|debug]
#                                       [--skip-adhoc-check]
#
#   --previous APP        The "installed" build. Default: build one now with build_app.sh.
#   --configuration C     Passed to build_app.sh. Default: release.
#   --skip-adhoc-check    Skip the negative check that ad-hoc signatures break continuity.
#
# Environment:
#   GLINT_SIGN_IDENTITY     Required: a certificate identity (SHA-1 or name), not "-" (ad-hoc).
#   GLINT_REQUIREMENT_FILE  Optional: both builds must also satisfy this designated requirement.
#
# macOS stores an app's designated requirement with every privacy grant (Screen Recording,
# TCC) and honours the grant for any later build that satisfies it. This script rebuilds
# dist/Glint.app with a different build number and asserts that the new build has a different
# cdhash (so a cdhash-pinned grant would be lost) yet satisfies the previous build's designated
# requirement (so the certificate-based grant survives). See #39.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

APP="$ROOT/dist/Glint.app"
WORK="$ROOT/dist/signing-continuity"
ENTITLEMENTS="$ROOT/Resources/Glint.entitlements"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::error title=Signing continuity::%s\n' "$*"
  fi
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/check_signing_continuity.sh [--previous APP] [--configuration release|debug]
                                           [--skip-adhoc-check]

Rebuilds dist/Glint.app with a new build number and checks that it satisfies the previous
build's designated requirement, i.e. that macOS keeps Screen Recording permission across the
update. Needs GLINT_SIGN_IDENTITY (a certificate, not ad-hoc); honours GLINT_REQUIREMENT_FILE.

  --previous APP        previous build to compare against (default: build one first)
  --configuration C     release (default) or debug
  --skip-adhoc-check    skip the check that ad-hoc signatures do break continuity
EOF
}

PREVIOUS=""
CONFIG=release
ADHOC_CHECK=1

while (($#)); do
  case "$1" in
    --previous)
      PREVIOUS="${2:?--previous needs a value}"
      shift
      ;;
    --previous=*) PREVIOUS="${1#*=}" ;;
    --configuration | -c)
      CONFIG="${2:?--configuration needs a value}"
      shift
      ;;
    --configuration=*) CONFIG="${1#*=}" ;;
    --skip-adhoc-check) ADHOC_CHECK=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

if [[ -n "$PREVIOUS" && "$PREVIOUS" != /* ]]; then
  PREVIOUS="$PWD/$PREVIOUS"
fi
cd "$ROOT"

[[ "${GLINT_SIGN_IDENTITY:--}" != "-" ]] \
  || die "set GLINT_SIGN_IDENTITY to a certificate identity (see Scripts/import_signing_identity.sh)"
export GLINT_REQUIRE_STABLE_SIGNATURE=1

designated_requirement() {
  codesign --display --requirements - "$1" 2>&1 | sed -n 's/^[# ]*designated => //p'
}
cdhash() {
  codesign --display --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1
}
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}
# satisfies APP REQUIREMENT: what macOS evaluates before honouring an existing privacy grant.
satisfies() {
  codesign --verify --deep --strict -R="$2" "$1" 2>/dev/null
}

rm -rf "$WORK"
mkdir -p "$WORK"

if [[ -n "$PREVIOUS" ]]; then
  PREVIOUS="${PREVIOUS%/}"
  [[ -d "$PREVIOUS" ]] || die "no such app bundle: $PREVIOUS"
else
  log "Building the previous version"
  "$ROOT/Scripts/build_app.sh" --configuration "$CONFIG"
  PREVIOUS="$APP"
fi
# build_app.sh replaces dist/Glint.app, so keep a copy of the previous build.
ditto "$PREVIOUS" "$WORK/previous/Glint.app"
PREVIOUS="$WORK/previous/Glint.app"
"$ROOT/Scripts/verify_signature.sh" "$PREVIOUS" --require-stable

prev_requirement="$(designated_requirement "$PREVIOUS")"
prev_cdhash="$(cdhash "$PREVIOUS")"
prev_version="$(plist_value "$PREVIOUS" CFBundleShortVersionString)"
prev_build="$(plist_value "$PREVIOUS" CFBundleVersion)"
[[ -n "$prev_requirement" && -n "$prev_cdhash" ]] || die "cannot read the signature of $PREVIOUS"
[[ "$prev_requirement" != *cdhash* ]] \
  || die "the previous build's designated requirement pins its cdhash: $prev_requirement"

next_build="$((${prev_build%%.*} + 1))"
log "Building the update: version $prev_version, build $prev_build -> $next_build"
"$ROOT/Scripts/build_app.sh" --configuration "$CONFIG" --version "$prev_version" --build-number "$next_build"
next_cdhash="$(cdhash "$APP")"
next_requirement="$(designated_requirement "$APP")"

[[ "$next_cdhash" != "$prev_cdhash" ]] \
  || die "the rebuilt app has the same cdhash ($next_cdhash); the check would prove nothing"
satisfies "$APP" "$prev_requirement" \
  || die "the update does not satisfy the previous build's designated requirement ($prev_requirement): macOS would drop Screen Recording permission after updating"
log "Update keeps permissions: new cdhash $next_cdhash, satisfies \"$prev_requirement\""
if [[ "$next_requirement" != "$prev_requirement" ]]; then
  warn "the designated requirement changed: \"$prev_requirement\" -> \"$next_requirement\""
fi

if ((ADHOC_CHECK)); then
  # Negative control: the same two builds signed ad-hoc (what releases used to be) must fail the
  # check, otherwise it would not detect a broken release.
  log "Negative control: re-signing both builds ad-hoc"
  ditto "$PREVIOUS" "$WORK/adhoc-previous/Glint.app"
  ditto "$APP" "$WORK/adhoc-next/Glint.app"
  for copy in "$WORK/adhoc-previous/Glint.app" "$WORK/adhoc-next/Glint.app"; do
    codesign --force --deep --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$copy" 2>/dev/null
  done
  adhoc_requirement="$(designated_requirement "$WORK/adhoc-previous/Glint.app")"
  [[ "$adhoc_requirement" == *cdhash* ]] \
    || die "expected an ad-hoc designated requirement to pin a cdhash, got: $adhoc_requirement"
  if satisfies "$WORK/adhoc-next/Glint.app" "$adhoc_requirement"; then
    die "an ad-hoc rebuild satisfied the previous ad-hoc requirement; the continuity check is not meaningful"
  fi
  if satisfies "$WORK/adhoc-next/Glint.app" "$prev_requirement"; then
    die "an ad-hoc build satisfied the certificate requirement ($prev_requirement)"
  fi
  log "Ad-hoc rebuilds lose permissions, as expected (that was #39)"
fi

rm -rf "$WORK"
log "Signing continuity OK: an update signed with the same certificate keeps Screen Recording permission"
