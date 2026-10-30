#!/usr/bin/env bash
#
# verify_signature.sh - check Glint.app's code signature and that updates keep their permissions.
#
# Usage:
#   Scripts/verify_signature.sh path/to/Glint.app [--require-stable] [--requirement-file PATH]
#
#   --require-stable          Fail unless the app is signed with a certificate, i.e. its designated
#                             requirement does not pin one build's cdhash. macOS keys privacy
#                             permissions such as Screen Recording to that requirement, so an
#                             ad-hoc release makes every user re-grant them after updating (#39).
#   --requirement-file PATH   Also require the app to satisfy the designated requirement in PATH
#                             (what earlier releases were signed to). Default: $GLINT_REQUIREMENT_FILE,
#                             else packaging/signing/designated-requirement.txt when it exists
#                             and --require-stable is given.
#
# Always runs `codesign --verify --deep --strict` and prints the signature summary and the
# designated requirement.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEFAULT_REQ_FILE="$ROOT/packaging/signing/designated-requirement.txt"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/verify_signature.sh path/to/Glint.app [--require-stable|--require-developer-id|--require-notarized] [--requirement-file PATH]

Verifies the code signature of Glint.app and prints its designated requirement.

  --require-stable          fail if the app is signed ad-hoc (its requirement pins a cdhash, so
                            macOS drops Screen Recording permission on every update)
  --require-developer-id    require Glint's Apple Developer ID, hardened runtime and timestamp
  --require-notarized       also validate the stapled ticket and Gatekeeper assessment
  --requirement-file PATH   also require the designated requirement in PATH (default:
                            $GLINT_REQUIREMENT_FILE, else packaging/signing/designated-requirement.txt
                            when it exists and --require-stable is given)
EOF
}

APP=""
REQUIRE_STABLE=0
REQUIRE_DEVELOPER_ID=0
REQUIRE_NOTARIZED=0
REQ_FILE="${GLINT_REQUIREMENT_FILE:-}"

while (($#)); do
  case "$1" in
    --require-stable) REQUIRE_STABLE=1 ;;
    --require-developer-id) REQUIRE_STABLE=1; REQUIRE_DEVELOPER_ID=1 ;;
    --require-notarized) REQUIRE_STABLE=1; REQUIRE_DEVELOPER_ID=1; REQUIRE_NOTARIZED=1 ;;
    --requirement-file)
      REQ_FILE="${2:?--requirement-file needs a value}"
      shift
      ;;
    --requirement-file=*) REQ_FILE="${1#*=}" ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *)
      [[ -z "$APP" ]] || die "more than one app given: $APP, $1"
      APP="$1"
      ;;
  esac
  shift
done

[[ -n "$APP" ]] || {
  usage >&2
  exit 2
}
APP="${APP%/}"
[[ -d "$APP" ]] || die "no such app bundle: $APP"

# Prints a GitHub Actions annotation as well when running there.
fail() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::error title=Code signature::%s\n' "$1"
  fi
  die "$1"
}

codesign --verify --deep --strict "$APP" || fail "$APP has an invalid code signature"

details="$(codesign --display --verbose=4 "$APP" 2>&1)" || fail "codesign cannot read the signature of $APP"
requirement="$(codesign --display --requirements - "$APP" 2>&1 | sed -n 's/^[# ]*designated => //p')"
[[ -n "$requirement" ]] || fail "$APP has no designated requirement"

field() { sed -n "s/^$1=//p" <<<"$details" | head -n 1; }
authority="$(field Authority)"
signature="$(field Signature)"
flags="$(sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p' <<<"$details" | head -n 1)"
log "Signature of $APP"
printf '    identifier:  %s\n' "$(field Identifier)"
printf '    signed by:   %s\n' "${authority:-${signature:-unknown}}"
printf '    cdhash:      %s\n' "$(field CDHash)"
printf '    flags:       %s\n' "${flags:-none}"
printf '    timestamp:   %s\n' "$(field Timestamp)"
printf '    designated:  %s\n' "$requirement"

adhoc=0
if [[ "$signature" == adhoc || "$requirement" == *cdhash* ]]; then
  adhoc=1
fi

if ((REQUIRE_STABLE)); then
  if ((adhoc)); then
    fail "$APP is signed ad-hoc: sign releases with Developer ID (GLINT_SIGN_IDENTITY; see packaging/signing/README.md)."
  fi

  if ((REQUIRE_DEVELOPER_ID)); then
    codesign --verify --deep --strict -R="$(cat "$ROOT/packaging/signing/developer-id-requirement.txt")" "$APP" \
      || fail "$APP is not signed with Glint's Apple Developer ID"
    [[ "$(field Identifier)" == io.github.mrashrhodes.glint ]] || fail "unexpected bundle identifier"
    archs="$(lipo -archs "$APP/Contents/MacOS/Glint")" || fail "cannot read executable architectures"
    [[ -n "$archs" ]] || fail "the executable has no architectures"
    for arch in $archs; do
      arch_details="$(codesign --display --arch "$arch" --verbose=4 "$APP" 2>&1)"
      grep -q '^CodeDirectory .*flags=.*runtime' <<<"$arch_details" || fail "$arch is missing the hardened runtime"
      grep -q '^Timestamp=.' <<<"$arch_details" || fail "$arch is missing a secure timestamp"
    done
    REQ_FILE="$DEFAULT_REQ_FILE"
  fi
  if [[ "$flags" != *runtime* ]]; then
    warn "$APP is not signed with the hardened runtime"
  fi
  if [[ -z "$REQ_FILE" && -f "$DEFAULT_REQ_FILE" ]]; then
    REQ_FILE="$DEFAULT_REQ_FILE"
  fi
fi

if [[ -n "$REQ_FILE" ]]; then
  [[ -f "$REQ_FILE" ]] || fail "requirement file not found: $REQ_FILE"
  expected="$(sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$REQ_FILE")"
  [[ -n "$expected" ]] || fail "$REQ_FILE is empty"
  if ! codesign --verify --deep --strict -R="$expected" "$APP"; then
    fail "$APP does not satisfy ${REQ_FILE#"$ROOT"/}. Use the intended signing identity; do not replace the production requirement with a self-signed test certificate."
  fi
  log "Satisfies the designated requirement in ${REQ_FILE#"$ROOT"/}"
elif ((REQUIRE_STABLE)); then
  msg="No ${DEFAULT_REQ_FILE#"$ROOT"/}: cannot check signing continuity."
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::warning title=Code signature::%s\n' "$msg"
  else
    warn "$msg"
  fi

fi

if ((REQUIRE_NOTARIZED)); then
  xcrun stapler validate "$APP" || fail "$APP has no valid stapled notarization ticket"
  spctl --assess --type execute --verbose=2 "$APP" || fail "$APP failed Gatekeeper assessment"
fi

if ((REQUIRE_STABLE)); then
  log "Stable signature: builds signed with the same certificate keep Screen Recording permission"
elif ((adhoc)); then
  log "Ad-hoc signature: macOS ties privacy permissions to this exact build"
fi
