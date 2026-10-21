#!/usr/bin/env bash
#
# render_cask.sh - render the Homebrew cask for Glint from packaging/homebrew/glint.rb.tmpl.
#
# Usage:
#   Scripts/render_cask.sh --version X.Y.Z (--sha256 HEX | --zip FILE)
#                          [--output FILE] [--template FILE]
#
#   --version X.Y.Z   Release version (a leading "v" is ignored).
#   --sha256 HEX      SHA-256 of the release zip, 64 hex characters.
#   --zip FILE        Compute the SHA-256 from the release zip instead.
#   --output FILE     Write the cask here (parent directories are created). Default: stdout.
#   --template FILE   Default: packaging/homebrew/glint.rb.tmpl.
#
# The template placeholders are {{VERSION}} and {{SHA256}}. The rendered cask is syntax-checked
# with `ruby -c` before anything is written.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/render_cask.sh --version X.Y.Z (--sha256 HEX | --zip FILE)
                              [--output FILE] [--template FILE]

Renders the Homebrew cask for Glint from packaging/homebrew/glint.rb.tmpl.

  --version X.Y.Z   release version (a leading "v" is ignored)
  --sha256 HEX      SHA-256 of the release zip (64 hex characters)
  --zip FILE        compute the SHA-256 from the release zip instead
  --output FILE     write the cask here (default: stdout)
  --template FILE   cask template (default: packaging/homebrew/glint.rb.tmpl)
EOF
}

VERSION=""
SHA256=""
ZIP=""
OUTPUT=""
TEMPLATE="$ROOT/packaging/homebrew/glint.rb.tmpl"

while (($#)); do
  case "$1" in
    --version)
      VERSION="${2:?--version needs a value}"
      shift
      ;;
    --version=*) VERSION="${1#*=}" ;;
    --sha256)
      SHA256="${2:?--sha256 needs a value}"
      shift
      ;;
    --sha256=*) SHA256="${1#*=}" ;;
    --zip)
      ZIP="${2:?--zip needs a value}"
      shift
      ;;
    --zip=*) ZIP="${1#*=}" ;;
    --output)
      OUTPUT="${2:?--output needs a value}"
      shift
      ;;
    --output=*) OUTPUT="${1#*=}" ;;
    --template)
      TEMPLATE="${2:?--template needs a value}"
      shift
      ;;
    --template=*) TEMPLATE="${1#*=}" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[[ -n "$VERSION" ]] || die "--version is required"
VERSION="${VERSION#v}"
version_re='^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?$'
[[ $VERSION =~ $version_re ]] || die "invalid version '$VERSION' (expected e.g. 1.2.3)"

if [[ -n "$SHA256" && -n "$ZIP" ]]; then
  die "pass either --sha256 or --zip, not both"
fi
if [[ -n "$ZIP" ]]; then
  [[ -f "$ZIP" ]] || die "zip not found: $ZIP"
  SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
fi
[[ -n "$SHA256" ]] || die "--sha256 or --zip is required"
SHA256="$(printf '%s' "$SHA256" | tr '[:upper:]' '[:lower:]')"
sha_re='^[0-9a-f]{64}$'
[[ $SHA256 =~ $sha_re ]] || die "invalid sha256 '$SHA256' (expected 64 hex characters)"

[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

# VERSION and SHA256 were validated above, so they cannot contain sed metacharacters.
rendered="$(sed -e "s|{{VERSION}}|$VERSION|g" -e "s|{{SHA256}}|$SHA256|g" "$TEMPLATE")"

# Homebrew's own install-time tokens in *_steps blocks are lowercase ({{appdir}}); only this
# template's uppercase placeholders must be fully resolved.
if grep -Eq '\{\{[A-Z][A-Z0-9_]*\}\}' <<<"$rendered"; then
  die "unresolved placeholder left in $TEMPLATE"
fi

if command -v ruby >/dev/null 2>&1; then
  printf '%s\n' "$rendered" | ruby -c >/dev/null || die "the rendered cask is not valid Ruby"
else
  printf 'warning: ruby not found, skipping the cask syntax check\n' >&2
fi

if [[ -n "$OUTPUT" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  printf '%s\n' "$rendered" >"$OUTPUT"
  printf 'Wrote %s (glint %s, sha256 %s)\n' "$OUTPUT" "$VERSION" "$SHA256" >&2
else
  printf '%s\n' "$rendered"
fi
