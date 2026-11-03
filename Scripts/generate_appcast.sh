#!/usr/bin/env bash
#
# generate_appcast.sh - sign the release ZIP and publish-ready appcast for Glint's Sparkle updater.
#
# Usage:
#   Scripts/generate_appcast.sh X.Y.Z
#
# Run it only after Scripts/package_release.sh has produced the final, notarized dist/Glint-X.Y.Z.zip,
# and never modify the ZIP or the appcast afterwards: both carry an EdDSA signature.
#
# Environment (both required; there is no Keychain fallback):
#   GLINT_SPARKLE_PRIVATE_KEY   the private key exported by Sparkle's generate_keys -x, read from the
#                               environment and handed to the tools on stdin, never written to disk
#   GLINT_SPARKLE_PUBLIC_KEY    the matching base64 public key, which must equal the SUPublicEDKey
#                               that the packaged app carries
#
# Output: dist/appcast.xml (signed, with this release's notes embedded) and dist/appcast.xml.sha256.
# The feed lists only this release (--maximum-versions 1) and no delta updates. Prereleases are
# refused: the appcast URL points at the latest non-prerelease release.

set -euo pipefail
set +x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# == 1 ]] || die "usage: Scripts/generate_appcast.sh X.Y.Z"
VERSION="${1#v}"
version_re='^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?$'
[[ $VERSION =~ $version_re ]] || die "invalid version '$VERSION' (expected e.g. 1.2.3)"
[[ $VERSION != *-* ]] || die "$VERSION is a prerelease; only stable releases are published to the update feed"

: "${GLINT_SPARKLE_PRIVATE_KEY:?Missing Sparkle private key (the output of generate_keys -x)}"
: "${GLINT_SPARKLE_PUBLIC_KEY:?Missing Sparkle public key}"
command -v python3 >/dev/null || die "python3 is required to validate the generated feed"
command -v node >/dev/null || die "node is required to read the release notes and verify the archive signature"

TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$TOOLS/generate_appcast" && -x "$TOOLS/sign_update" ]] \
  || die "Sparkle's tools are missing from ${TOOLS#"$ROOT"/}: run 'swift build' to resolve the package first"

ARCHIVE="$ROOT/dist/Glint-$VERSION.zip"
[[ -s "$ARCHIVE" ]] || die "missing packaged ZIP: ${ARCHIVE#"$ROOT"/} (run Scripts/package_release.sh first)"

STAGE="$(mktemp -d "$ROOT/dist/appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$ARCHIVE" "$STAGE/"
node "$ROOT/.github/scripts/changelog.cjs" notes "$VERSION" >"$STAGE/Glint-$VERSION.md"

PREFIX="https://github.com/MrAshRhodes/glint/releases/download/v$VERSION/"
printf '%s' "$GLINT_SPARKLE_PRIVATE_KEY" | "$TOOLS/generate_appcast" \
  --ed-key-file - --maximum-deltas 0 --maximum-versions 1 --embed-release-notes \
  --download-url-prefix "$PREFIX" \
  --link "https://github.com/MrAshRhodes/glint/releases/tag/v$VERSION" \
  "$STAGE"

# Validate the generated entry against the exact final archive, not just the generator's exit status.
signature="$(python3 - "$STAGE/appcast.xml" "$ARCHIVE" "$VERSION" "$PREFIX" <<'PY'
import os
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile

feed, archive, version, prefix = sys.argv[1:]
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
with zipfile.ZipFile(archive) as package:
    info = plistlib.loads(package.read("Glint.app/Contents/Info.plist"))
assert info.get("SUPublicEDKey") == os.environ["GLINT_SPARKLE_PUBLIC_KEY"], "archive public key mismatch"
assert info.get("SURequireSignedFeed") is True, "archive must require a signed feed"
assert info.get("SUVerifyUpdateBeforeExtraction") is True, "archive must verify before extraction"
assert info.get("CFBundleShortVersionString") == version, "archive version mismatch"
items = ET.parse(feed).findall("./channel/item")
assert len(items) == 1, "expected exactly one update"
item = items[0]
enclosure = item.find("enclosure")
assert enclosure is not None, "missing update enclosure"
assert enclosure.get("url") == prefix + os.path.basename(archive), "incorrect download URL"
assert enclosure.get("length") == str(os.path.getsize(archive)), "incorrect archive length"
assert item.findtext(ns + "version") == info["CFBundleVersion"], "incorrect build number"
assert item.findtext(ns + "shortVersionString") == version, "incorrect display version"
assert item.findtext(ns + "minimumSystemVersion") == info["LSMinimumSystemVersion"], "incorrect OS requirement"
assert item.find(ns + "releaseNotesLink") is None, "release notes must be embedded"
assert (item.findtext("description") or "").strip(), "missing embedded release notes"
assert enclosure.get(ns + "edSignature"), "missing archive signature"
print(enclosure.get(ns + "edSignature"))
PY
)"

# Verify against the PUBLIC key embedded in the app, which catches a mismatched private key / public key pair.
GLINT_ARCHIVE_SIGNATURE="$signature" node - "$ARCHIVE" <<'JS'
const { createPublicKey, verify } = require("node:crypto");
const { readFileSync } = require("node:fs");
const raw = Buffer.from(process.env.GLINT_SPARKLE_PUBLIC_KEY, "base64");
if (raw.length !== 32) throw new Error("Invalid Sparkle public key");
const key = createPublicKey({
  key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]),
  format: "der", type: "spki",
});
if (!verify(null, readFileSync(process.argv[2]), key,
  Buffer.from(process.env.GLINT_ARCHIVE_SIGNATURE, "base64"))) {
  throw new Error("Archive signature does not match the app's public key");
}
JS
printf '%s' "$GLINT_SPARKLE_PRIVATE_KEY" | "$TOOLS/sign_update" --ed-key-file - --verify "$STAGE/appcast.xml"

mv "$STAGE/appcast.xml" "$ROOT/dist/appcast.xml"
(cd "$ROOT/dist" && shasum -a 256 appcast.xml >appcast.xml.sha256)
printf 'Verified signed appcast: dist/appcast.xml\n'
