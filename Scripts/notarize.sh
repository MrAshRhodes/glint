#!/usr/bin/env bash
# Notarize and staple a Developer ID-signed app or disk image, never a release ZIP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# == 1 ]] || die "usage: Scripts/notarize.sh path/to/Glint.app|release.dmg|--check-credentials"
auth=()
if [[ -n "${GLINT_NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$GLINT_NOTARY_PROFILE")
  if [[ -n "${GLINT_NOTARY_KEYCHAIN:-}" ]]; then
    auth+=(--keychain "$GLINT_NOTARY_KEYCHAIN")
  fi
else
  [[ -n "${GLINT_NOTARY_KEY_PATH:-}" && -n "${GLINT_NOTARY_KEY_ID:-}" && -n "${GLINT_NOTARY_ISSUER_ID:-}" ]] \
    || die "set GLINT_NOTARY_PROFILE or all of GLINT_NOTARY_KEY_PATH, GLINT_NOTARY_KEY_ID and GLINT_NOTARY_ISSUER_ID"
  [[ -s "$GLINT_NOTARY_KEY_PATH" ]] || die "notarization private key is missing or empty"
  auth=(--key "$GLINT_NOTARY_KEY_PATH" --key-id "$GLINT_NOTARY_KEY_ID" --issuer "$GLINT_NOTARY_ISSUER_ID")
fi
command -v jq >/dev/null || die "jq is required for notarization status validation"
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
if [[ "$1" == --check-credentials ]]; then
  xcrun notarytool history "${auth[@]}" --output-format json >/dev/null
  exit 0
fi

target="${1%/}"
[[ -e "$target" ]] || die "not found: $target"
case "$target" in
  *.app) "$ROOT/Scripts/verify_signature.sh" "$target" --require-developer-id ;;
  *.dmg)
    codesign --verify --strict -R="$(cat "$ROOT/packaging/signing/developer-id-requirement.txt")" "$target"
    ;;
  *) die "expected an .app or .dmg (ZIPs cannot be stapled)" ;;
esac

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/glint-notary.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
submission="$target"
if [[ "$target" == *.app ]]; then
  submission="$work/submission.zip"
  ditto -c -k --norsrc --noextattr --keepParent "$target" "$submission"
fi

printf '==> Submitting %s to Apple\n' "$target"
submit_status=0
xcrun notarytool submit "$submission" "${auth[@]}" --wait --timeout 30m \
  --output-format json >"$work/result.json" || submit_status=$?
cat "$work/result.json"
if ((submit_status != 0)) || ! jq -e '.status == "Accepted"' "$work/result.json" >/dev/null; then
  if id="$(jq -er '.id | select(type == "string" and length > 0)' "$work/result.json" 2>/dev/null)"; then
    xcrun notarytool log "$id" "${auth[@]}" \
      || printf 'warning: could not retrieve Apple diagnostics for submission %s\n' "$id" >&2
  fi
  die "notarization did not finish with Accepted status; nothing will be published"
fi
xcrun stapler staple "$target"
xcrun stapler validate "$target"
if [[ "$target" == *.app ]]; then
  "$ROOT/Scripts/verify_signature.sh" "$target" --require-notarized
else
  codesign --verify --strict -R="$(cat "$ROOT/packaging/signing/developer-id-requirement.txt")" "$target"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
fi
