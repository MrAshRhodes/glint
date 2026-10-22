#!/usr/bin/env bash
#
# make_signing_cert.sh - create the persistent "Glint Release Signing" code-signing certificate.
#
# Run this once. Every release must be signed with the same certificate: when a user grants a
# privacy permission such as Screen Recording, macOS stores the app's designated requirement.
# For an ad-hoc signature that requirement is the cdhash of one exact build, so every update
# lost the permission (#39). For a certificate-signed app it is
#   identifier "io.github.mrashrhodes.glint" and certificate leaf = H"<certificate sha1>"
# which every later build signed with the same certificate satisfies.
#
# Usage:
#   Scripts/make_signing_cert.sh [--out DIR] [--requirement-file PATH] [--force]
#                                [--set-github-secrets] [--repo OWNER/NAME]
#
#   --out DIR                 Where the key, certificate and .p12 are written.
#                             Default: ~/.glint-signing (outside the repository; never commit them).
#   --requirement-file PATH   Where the designated requirement the certificate produces is written.
#                             Default: packaging/signing/designated-requirement.txt (commit it;
#                             releases are verified against it).
#   --force                   Replace an existing certificate and requirement file. Rotating the
#                             certificate makes every user re-grant Screen Recording once.
#   --set-github-secrets      Store GLINT_SIGNING_P12_BASE64 and GLINT_SIGNING_P12_PASSWORD as
#                             repository secrets with `gh secret set`.
#   --repo OWNER/NAME         Repository for --set-github-secrets. Default: `gh repo view`.
#
# Environment: OPENSSL (default: openssl on PATH; OpenSSL 3+ and LibreSSL both work).
#
# The certificate is self-signed: Gatekeeper treats the app exactly like an ad-hoc build (the
# Homebrew cask keeps clearing the quarantine attribute). It only makes permissions stick.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

CN="Glint Release Signing"
KEY_BITS=3072
DAYS=7300
PLIST_SRC="$ROOT/Resources/Info.plist"
OPENSSL="${OPENSSL:-openssl}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/make_signing_cert.sh [--out DIR] [--requirement-file PATH] [--force]
                                    [--set-github-secrets] [--repo OWNER/NAME]

Creates the self-signed "Glint Release Signing" certificate that every release is signed with,
so macOS keeps Screen Recording permission across updates. Run it once and keep the output safe.

  --out DIR                 output directory (default: ~/.glint-signing, outside the repository)
  --requirement-file PATH   designated requirement file to write
                            (default: packaging/signing/designated-requirement.txt)
  --force                   replace an existing certificate (every user re-grants permission once)
  --set-github-secrets      run `gh secret set` for GLINT_SIGNING_P12_BASE64 and
                            GLINT_SIGNING_P12_PASSWORD
  --repo OWNER/NAME         repository for --set-github-secrets (default: `gh repo view`)

Environment: OPENSSL (default: openssl on PATH).
EOF
}

OUT="$HOME/.glint-signing"
REQ_FILE="$ROOT/packaging/signing/designated-requirement.txt"
FORCE=0
SET_SECRETS=0
REPO=""

while (($#)); do
  case "$1" in
    --out)
      OUT="${2:?--out needs a value}"
      shift
      ;;
    --out=*) OUT="${1#*=}" ;;
    --requirement-file)
      REQ_FILE="${2:?--requirement-file needs a value}"
      shift
      ;;
    --requirement-file=*) REQ_FILE="${1#*=}" ;;
    --force) FORCE=1 ;;
    --set-github-secrets) SET_SECRETS=1 ;;
    --repo)
      REPO="${2:?--repo needs a value}"
      shift
      ;;
    --repo=*) REPO="${1#*=}" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[[ "$(uname -s)" == Darwin ]] || die "this script needs macOS (it self-tests the identity with security(1))"
command -v "$OPENSSL" >/dev/null || die "openssl not found (set OPENSSL=/path/to/openssl)"
[[ -f "$PLIST_SRC" ]] || die "missing $PLIST_SRC"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_SRC")"
[[ -n "$BUNDLE_ID" ]] || die "Resources/Info.plist has no CFBundleIdentifier"

absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}
OUT="$(absolute "$OUT")"
REQ_FILE="$(absolute "$REQ_FILE")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

case "$OUT/" in
  "$ROOT"/*) die "--out must be outside the repository ($OUT); the private key must never be committed" ;;
esac

KEY="$OUT/glint-signing.key"
CRT="$OUT/glint-signing.crt"
P12="$OUT/glint-signing.p12"
PW_FILE="$OUT/glint-signing.p12.password"
B64_FILE="$OUT/glint-signing.p12.base64"

existing=()
for file in "$KEY" "$CRT" "$P12" "$PW_FILE" "$B64_FILE" "$REQ_FILE"; do
  if [[ -e "$file" ]]; then
    existing+=("$file")
  fi
done
if ((${#existing[@]})); then
  if ((!FORCE)); then
    printf '    %s\n' "${existing[@]}" >&2
    die "a signing certificate already exists (files above). Every release must be signed with the
       same certificate, otherwise every user has to re-grant Screen Recording after updating.
       Re-run with --force only if you really mean to rotate it."
  fi
  warn "--force: replacing the existing signing certificate. Releases signed with the new"
  warn "certificate do not satisfy the old designated requirement, so every user has to re-grant"
  warn "Screen Recording once after updating. Mention that in the release notes."
fi

chmod 700 "$OUT"
umask 077

WORK="$(mktemp -d "$OUT/.make-signing-cert.XXXXXX")"
SELFTEST_KC=""
cleanup() {
  if [[ -n "$SELFTEST_KC" ]]; then
    security delete-keychain "$SELFTEST_KC" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# run_quiet CMD...: run CMD, show its output only when it fails.
run_quiet() {
  local output
  if ! output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

log "Creating a self-signed code-signing certificate for \"$CN\" (RSA $KEY_BITS, $DAYS days)"
cat >"$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
string_mask = utf8only

[dn]
CN = $CN

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
run_quiet "$OPENSSL" req -x509 -newkey "rsa:$KEY_BITS" -sha256 -days "$DAYS" -nodes \
  -config "$WORK/openssl.cnf" -keyout "$WORK/key" -out "$WORK/crt" \
  || die "openssl could not create the certificate"

P12_PASSWORD="$("$OPENSSL" rand -hex 24)"
printf '%s' "$P12_PASSWORD" >"$WORK/password"
# PBE-SHA1-3DES + SHA-1 MAC: the PKCS#12 encryption that security(1) can import. OpenSSL 3's
# default (AES-256 + PBKDF2) is rejected by older macOS releases.
GLINT_P12_PASSWORD="$P12_PASSWORD" run_quiet "$OPENSSL" pkcs12 -export \
  -inkey "$WORK/key" -in "$WORK/crt" -name "$CN" -out "$WORK/p12" \
  -passout env:GLINT_P12_PASSWORD \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  || die "openssl could not export the .p12"
"$OPENSSL" base64 -A -in "$WORK/p12" -out "$WORK/base64"

SHA1="$("$OPENSSL" x509 -in "$WORK/crt" -outform DER | shasum -a 1 | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')"
[[ $SHA1 =~ ^[0-9a-f]{40}$ ]] || die "could not compute the certificate SHA-1"
REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SHA1\""

# Self-test: the .p12 must import into a keychain and yield a code-signing identity. The
# throwaway keychain is opened by path only and never added to the keychain search list.
log "Self-testing the .p12 in a throwaway keychain"
search_list_before="$(security list-keychains -d user)"
SELFTEST_KC="$WORK/selftest.keychain-db"
selftest_kc_password="$("$OPENSSL" rand -hex 16)"
run_quiet security create-keychain -p "$selftest_kc_password" "$SELFTEST_KC" \
  || die "could not create the self-test keychain"
if [[ "$(security list-keychains -d user)" != "$search_list_before" ]]; then
  # Some macOS versions add new keychains to the search list; put the original list back.
  saved=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [[ -n "$line" ]] && saved+=("$line")
  done <<<"$search_list_before"
  security list-keychains -d user -s ${saved[@]+"${saved[@]}"}
fi
run_quiet security unlock-keychain -p "$selftest_kc_password" "$SELFTEST_KC" \
  || die "could not unlock the self-test keychain"
run_quiet security import "$WORK/p12" -k "$SELFTEST_KC" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -f pkcs12 \
  || die "security(1) could not import the .p12"
identities="$(security find-identity -p codesigning "$SELFTEST_KC")"
sha1_upper="$(printf '%s' "$SHA1" | tr '[:lower:]' '[:upper:]')"
if ! grep -q "$sha1_upper \"$CN\"" <<<"$identities"; then
  printf '%s\n' "$identities" >&2
  die "the imported .p12 does not provide a code-signing identity for \"$CN\""
fi
run_quiet security delete-keychain "$SELFTEST_KC" || warn "could not delete $SELFTEST_KC"
SELFTEST_KC=""

mv -f "$WORK/key" "$KEY"
mv -f "$WORK/crt" "$CRT"
mv -f "$WORK/p12" "$P12"
mv -f "$WORK/password" "$PW_FILE"
mv -f "$WORK/base64" "$B64_FILE"
chmod 600 "$KEY" "$CRT" "$P12" "$PW_FILE" "$B64_FILE"

mkdir -p "$(dirname "$REQ_FILE")"
(umask 022 && printf '%s\n' "$REQUIREMENT" >"$REQ_FILE")

if ((SET_SECRETS)); then
  command -v gh >/dev/null || die "gh not found; set the secrets by hand (commands below)"
  if [[ -z "$REPO" ]]; then
    REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner)" \
      || die "could not determine the repository; pass --repo OWNER/NAME"
  fi
  log "Setting the signing secrets on $REPO"
  gh secret set GLINT_SIGNING_P12_BASE64 --repo "$REPO" <"$B64_FILE"
  gh secret set GLINT_SIGNING_P12_PASSWORD --repo "$REPO" <"$PW_FILE"
fi

repo_flag=""
if [[ -n "$REPO" ]]; then
  repo_flag=" --repo $REPO"
fi

cat <<EOF

Created the "$CN" certificate.
    SHA-1 (certificate leaf):  $SHA1
    certificate:               $CRT
    private key:               $KEY
    .p12 (for CI):             $P12
    .p12 password:             $PW_FILE
    .p12 as base64:            $B64_FILE
    designated requirement:    $REQ_FILE
        $REQUIREMENT

EOF
if ((!SET_SECRETS)); then
  cat <<EOF
Store the identity as GitHub Actions secrets:
    gh secret set GLINT_SIGNING_P12_BASE64$repo_flag < "$B64_FILE"
    gh secret set GLINT_SIGNING_P12_PASSWORD$repo_flag < "$PW_FILE"

EOF
fi
case "$REQ_FILE" in
  "$ROOT"/*) printf 'Commit %s so releases are verified against it.\n\n' "${REQ_FILE#"$ROOT"/}" ;;
esac
cat <<EOF
Back up $P12 and its password (for example in a password manager).
If they are lost, the next release has to use a new certificate and every user must re-grant
Screen Recording once.
EOF
