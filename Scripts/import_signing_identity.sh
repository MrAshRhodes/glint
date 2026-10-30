#!/usr/bin/env bash
#
# import_signing_identity.sh - make a release or test identity available to codesign.
#
# Usage:
#   Scripts/import_signing_identity.sh [--p12 FILE] [--password-env VAR] [--name CN]
#   Scripts/import_signing_identity.sh --cleanup [KEYCHAIN]
#
#   (default)            Decode the .p12 from $GLINT_SIGNING_P12_BASE64 (the GitHub secret)
#                        with the password in $GLINT_SIGNING_P12_PASSWORD, import it into a new
#                        temporary keychain and put that keychain first in the user keychain
#                        search list (codesign only finds identities in the search list).
#   --p12 FILE           Import this .p12 file instead of $GLINT_SIGNING_P12_BASE64.
#   --password-env VAR   Read the .p12 password from $VAR. Default: GLINT_SIGNING_P12_PASSWORD.
#   --name CN            Identity to look for. Default: "Glint Test Signing" (when the
#                        keychain holds exactly one code-signing identity it is used regardless).
#   --cleanup [KEYCHAIN] Delete the temporary keychain and remove it from the search list, keeping
#                        every other entry. Default: $GLINT_SIGNING_KEYCHAIN, else every
#                        glint-signing.keychain-db in the search list.
#
# Prints the identity's SHA-1 (pass it as GLINT_SIGN_IDENTITY). When $GITHUB_OUTPUT is set it
# also writes identity=<sha1> and keychain=<path> step outputs. The keychain lives in
# $RUNNER_TEMP (else $TMPDIR) and has a random password.

set -euo pipefail

KEYCHAIN_NAME="glint-signing.keychain-db"

# Progress goes to stderr: stdout carries only the identity SHA-1.
log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/import_signing_identity.sh [--p12 FILE] [--password-env VAR] [--name CN]
       Scripts/import_signing_identity.sh --cleanup [KEYCHAIN]

Imports the release signing .p12 ($GLINT_SIGNING_P12_BASE64, password $GLINT_SIGNING_P12_PASSWORD)
into a temporary keychain at the front of the keychain search list and prints the identity SHA-1.

  --p12 FILE           import this .p12 instead of $GLINT_SIGNING_P12_BASE64
  --password-env VAR   environment variable holding the password (default GLINT_SIGNING_P12_PASSWORD)
  --name CN            identity common name (default "Glint Test Signing")
  --require-developer-id  accept only a valid Developer ID Application identity for Glint's team
  --cleanup [KEYCHAIN] delete the temporary keychain and drop it from the search list
EOF
}

P12_FILE=""
PASSWORD_ENV="GLINT_SIGNING_P12_PASSWORD"
CN="Glint Test Signing"
CLEANUP=0
CLEANUP_KEYCHAIN=""
REQUIRE_DEVELOPER_ID=0

while (($#)); do
  case "$1" in
    --p12)
      P12_FILE="${2:?--p12 needs a value}"
      shift
      ;;
    --p12=*) P12_FILE="${1#*=}" ;;
    --password-env)
      PASSWORD_ENV="${2:?--password-env needs a value}"
      shift
      ;;
    --password-env=*) PASSWORD_ENV="${1#*=}" ;;
    --name)
      CN="${2:?--name needs a value}"
      shift
      ;;
    --name=*) CN="${1#*=}" ;;
    --require-developer-id)
      REQUIRE_DEVELOPER_ID=1
      CN="Developer ID Application: Ashley Rhodes (TB3Z5R7SY8)"
      ;;
    --cleanup)
      CLEANUP=1
      if [[ $# -gt 1 && "$2" != -* ]]; then
        CLEANUP_KEYCHAIN="$2"
        shift
      fi
      ;;
    --cleanup=*)
      CLEANUP=1
      CLEANUP_KEYCHAIN="${1#*=}"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[[ "$(uname -s)" == Darwin ]] || die "this script needs macOS"

# SEARCH_LIST: the user keychain search list. security(1) prints one quoted, indented path per line.
SEARCH_LIST=()
read_search_list() {
  local line
  SEARCH_LIST=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#\"}"
    line="${line%\"}"
    [[ -n "$line" ]] && SEARCH_LIST+=("$line")
  done < <(security list-keychains -d user)
}

# set_search_list PATH...: replace the user search list; an empty list falls back to login.
set_search_list() {
  if (($#)); then
    security list-keychains -d user -s "$@"
  else
    security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db"
  fi
}

# remove_from_search_list PATH: keep every other entry, in order.
remove_from_search_list() {
  local target="$1" entry kept=()
  read_search_list
  for entry in ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}; do
    [[ "$entry" == "$target" ]] || kept+=("$entry")
  done
  if ((${#kept[@]} != ${#SEARCH_LIST[@]})); then
    set_search_list ${kept[@]+"${kept[@]}"}
  fi
}

if ((CLEANUP)); then
  keychains=()
  if [[ -n "$CLEANUP_KEYCHAIN" ]]; then
    keychains+=("$CLEANUP_KEYCHAIN")
  elif [[ -n "${GLINT_SIGNING_KEYCHAIN:-}" ]]; then
    keychains+=("$GLINT_SIGNING_KEYCHAIN")
  else
    read_search_list
    for entry in ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}; do
      [[ "$(basename "$entry")" == "$KEYCHAIN_NAME" ]] && keychains+=("$entry")
    done
  fi
  if ((${#keychains[@]} == 0)); then
    log "No temporary signing keychain to remove"
    exit 0
  fi
  for keychain in "${keychains[@]}"; do
    # Never touch a keychain this script did not create (login.keychain-db and friends).
    [[ "$(basename "$keychain")" == "$KEYCHAIN_NAME" ]] \
      || die "refusing to delete $keychain: not a $KEYCHAIN_NAME created by this script"
    log "Removing the temporary signing keychain $keychain"
    remove_from_search_list "$keychain"
    if [[ -e "$keychain" ]]; then
      security delete-keychain "$keychain" 2>/dev/null || rm -f "$keychain"
    fi
    remove_from_search_list "$keychain"
    # The mktemp directory from the import (security(1) leaves lock files in it).
    keychain_dir="$(dirname "$keychain")"
    if [[ "$(basename "$keychain_dir")" == glint-signing.?????? ]]; then
      rm -rf "$keychain_dir"
    fi
  done
  exit 0
fi

[[ $PASSWORD_ENV =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid --password-env name '$PASSWORD_ENV'"
PASSWORD="$(printenv "$PASSWORD_ENV" || true)"
[[ -n "$PASSWORD" ]] || die "\$$PASSWORD_ENV is empty: set it to the .p12 password"

WORK_PARENT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORK_PARENT="${WORK_PARENT%/}"
WORK="$(mktemp -d "$WORK_PARENT/glint-signing.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
KEYCHAIN="$WORK/$KEYCHAIN_NAME"
P12="$WORK/identity.p12"
IMPORTED=0

on_exit() {
  rm -f "$P12"
  if ((!IMPORTED)); then
    remove_from_search_list "$KEYCHAIN" 2>/dev/null || true
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "keychain=$KEYCHAIN" >>"$GITHUB_OUTPUT"
fi

if [[ -n "$P12_FILE" ]]; then
  [[ -f "$P12_FILE" ]] || die "no such .p12: $P12_FILE"
  (umask 077 && cp "$P12_FILE" "$P12")
else
  [[ -n "${GLINT_SIGNING_P12_BASE64:-}" ]] \
    || die "\$GLINT_SIGNING_P12_BASE64 is empty: set it to the base64 of the .p12 (or pass --p12 FILE)"
  (umask 077 && printf '%s' "$GLINT_SIGNING_P12_BASE64" | tr -d '[:space:]' | base64 --decode >"$P12") \
    || die "GLINT_SIGNING_P12_BASE64 is not valid base64"
fi
[[ -s "$P12" ]] || die "the .p12 is empty"

KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"

read_search_list
ORIGINAL_SEARCH_LIST=(${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"})

log "Creating the temporary keychain $KEYCHAIN"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# Lock after 6 hours or on sleep; long enough for any build.
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign -f pkcs12 >/dev/null \
  || die "could not import the .p12 (wrong password, or not a PKCS#12 file?)"
rm -f "$P12"
# Lets codesign use the private key without a UI prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

new_list=("$KEYCHAIN")
for entry in ${ORIGINAL_SEARCH_LIST[@]+"${ORIGINAL_SEARCH_LIST[@]}"}; do
  [[ "$entry" == "$KEYCHAIN" ]] || new_list+=("$entry")
done
set_search_list "${new_list[@]}"

# A self-signed identity is listed as CSSMERR_TP_NOT_TRUSTED (not under "valid identities"),
# which is fine for codesign. Lines look like:   1) <SHA-1> "<common name>" (...)
if ((REQUIRE_DEVELOPER_ID)); then
  identities="$(security find-identity -v -p codesigning "$KEYCHAIN")"
else
  identities="$(security find-identity -p codesigning "$KEYCHAIN")"
fi
hashes=()
named=""
while IFS= read -r line; do
  if [[ $line =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+\"(.*)\" ]]; then
    hash="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    case " ${hashes[*]-} " in
      *" $hash "*) ;;
      *) hashes+=("$hash") ;;
    esac
    if [[ "$name" == "$CN" && -z "$named" ]]; then
      named="$hash"
    fi
  fi
done <<<"$identities"

IDENTITY="$named"
if [[ -z "$IDENTITY" ]]; then
  if ((!REQUIRE_DEVELOPER_ID)) && ((${#hashes[@]} == 1)); then
    IDENTITY="${hashes[0]}"
    warn "no identity named \"$CN\"; using the only code-signing identity in the .p12"
  else
    printf '%s\n' "$identities" >&2
    IMPORTED=0
    die "expected a code-signing identity named \"$CN\" in the .p12 (found ${#hashes[@]})"
  fi
fi

log "Imported code-signing identity $IDENTITY (\"$CN\")"
log "Keychain search list: $(security list-keychains -d user | tr -s '[:space:]' ' ')"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "identity=$IDENTITY"
    echo "keychain=$KEYCHAIN"
  } >>"$GITHUB_OUTPUT"
fi
printf '%s\n' "$IDENTITY"
IMPORTED=1
