#!/usr/bin/env bash
#
# update_tap.sh - publish the Glint cask to the Homebrew tap repository.
#
# Usage:
#   Scripts/update_tap.sh [--version X.Y.Z] [--sha256 HEX | --zip FILE] [--repo OWNER/NAME]
#                         [--branch NAME] [--dry-run] [--create] [--skip-asset-check]
#
#   --version X.Y.Z       Release to publish. Default: the contents of VERSION.
#   --sha256 HEX          SHA-256 of Glint-<version>.zip. Default: hash dist/Glint-<version>.zip
#                         (or read dist/Glint-<version>.zip.sha256).
#   --zip FILE            Hash this release zip instead.
#   --repo OWNER/NAME     Tap repository. Default: MrAshRhodes/homebrew-tap.
#   --branch NAME         Branch to commit to. Default: the tap's default branch (main when new).
#   --dry-run             Render dist/glint.rb, print it and diff it against the tap. Never
#                         creates, commits or pushes anything.
#   --create              Create the tap repository (public) when it does not exist yet.
#   --skip-asset-check    Do not require the release zip to be downloadable before publishing.
#
# Authentication: TAP_GITHUB_TOKEN (a token that can push to the tap) is used when set,
# otherwise the local `gh auth login` session. The tap is cloned into dist/tap-work/.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

DIST="$ROOT/dist"
CASK_OUT="$DIST/glint.rb"
WORK_PARENT="$DIST/tap-work"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/update_tap.sh [--version X.Y.Z] [--sha256 HEX | --zip FILE] [--repo OWNER/NAME]
                             [--branch NAME] [--dry-run] [--create] [--skip-asset-check]

Publishes Casks/glint.rb (version + sha256) to the Homebrew tap and pushes it.

  --version X.Y.Z       release to publish (default: contents of VERSION)
  --sha256 HEX          SHA-256 of Glint-<version>.zip
  --zip FILE            hash this release zip (default: dist/Glint-<version>.zip)
  --repo OWNER/NAME     tap repository (default: MrAshRhodes/homebrew-tap)
  --branch NAME         branch to commit to (default: the tap's default branch)
  --dry-run             render + print the cask and diff it against the tap; change nothing
  --create              create the public tap repository if it does not exist
  --skip-asset-check    do not require the release zip to be downloadable first

Authentication: TAP_GITHUB_TOKEN when set, otherwise the local `gh auth login` session.
EOF
}

VERSION=""
SHA256=""
ZIP=""
REPO="MrAshRhodes/homebrew-tap"
BRANCH=""
DRY_RUN=0
CREATE=0
ASSET_CHECK=1

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
    --repo)
      REPO="${2:?--repo needs a value}"
      shift
      ;;
    --repo=*) REPO="${1#*=}" ;;
    --branch)
      BRANCH="${2:?--branch needs a value}"
      shift
      ;;
    --branch=*) BRANCH="${1#*=}" ;;
    --dry-run) DRY_RUN=1 ;;
    --create) CREATE=1 ;;
    --skip-asset-check) ASSET_CHECK=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
[[ $REPO =~ $repo_re ]] || die "invalid --repo '$REPO' (expected OWNER/NAME)"

if [[ -z "$VERSION" ]]; then
  [[ -f "$ROOT/VERSION" ]] || die "no --version given and VERSION file not found"
  VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
fi
VERSION="${VERSION#v}"

render_args=(--version "$VERSION" --output "$CASK_OUT")
if [[ -n "$SHA256" && -n "$ZIP" ]]; then
  die "pass either --sha256 or --zip, not both"
elif [[ -n "$SHA256" ]]; then
  render_args+=(--sha256 "$SHA256")
elif [[ -n "$ZIP" ]]; then
  render_args+=(--zip "$ZIP")
elif [[ -f "$DIST/Glint-$VERSION.zip" ]]; then
  render_args+=(--zip "$DIST/Glint-$VERSION.zip")
elif [[ -f "$DIST/Glint-$VERSION.zip.sha256" ]]; then
  render_args+=(--sha256 "$(cut -d' ' -f1 "$DIST/Glint-$VERSION.zip.sha256")")
else
  die "no release zip for $VERSION: pass --zip or --sha256, or run Scripts/package_release.sh first"
fi

if [[ -n "${TAP_GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="$TAP_GITHUB_TOKEN"
fi
export GIT_TERMINAL_PROMPT=0

"$ROOT/Scripts/render_cask.sh" "${render_args[@]}"

# Run git with credentials from gh, so TAP_GITHUB_TOKEN (via GH_TOKEN) or the local login is used.
git_net() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }

REPO_STATE=unknown
REPO_ERR=""
check_repo() {
  REPO_STATE=unknown
  REPO_ERR=""
  if ! command -v gh >/dev/null 2>&1; then
    REPO_ERR="the gh CLI is not installed"
    return 0
  fi
  local out
  if out="$(gh api "repos/$REPO" --silent 2>&1)"; then
    REPO_STATE=exists
  elif grep -q 'HTTP 404' <<<"$out"; then
    REPO_STATE=missing
  else
    REPO_ERR="$out"
  fi
}

# The cask downloads the release zip, so make sure that URL really serves it before the tap
# points at it.
asset_reachable() {
  local url code attempt
  url="$(sed -n 's/^  url "\(.*\)"$/\1/p' "$CASK_OUT" | head -n 1)"
  url="${url//\#\{version\}/$VERSION}"
  [[ -n "$url" ]] || return 1
  for attempt in 1 2 3; do
    code="$(curl -sL -r 0-0 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$code" == 200 || "$code" == 206 ]]; then
      return 0
    fi
    ((attempt < 3)) && sleep 5
  done
  ASSET_URL="$url"
  ASSET_CODE="$code"
  return 1
}
ASSET_URL=""
ASSET_CODE=""

if ((DRY_RUN)); then
  log "Dry run: nothing will be created, committed or pushed"
  printf -- '---- %s ----\n' "${CASK_OUT#"$ROOT"/}"
  cat "$CASK_OUT"
  printf -- '----\n'
  if ((ASSET_CHECK)) && ! asset_reachable; then
    warn "the release asset is not downloadable yet (HTTP ${ASSET_CODE:-?}): ${ASSET_URL:-unknown url}"
  fi
  check_repo
  case "$REPO_STATE" in
    exists)
      if remote="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$REPO/contents/Casks/glint.rb" 2>/dev/null)"; then
        if diff -u --label "$REPO:Casks/glint.rb" --label "new:Casks/glint.rb" \
          <(printf '%s\n' "$remote") "$CASK_OUT"; then
          log "Casks/glint.rb in $REPO is already up to date"
        else
          log "A real run would commit the change above to $REPO"
        fi
      else
        log "Casks/glint.rb does not exist in $REPO yet; a real run would add it"
      fi
      ;;
    missing)
      log "$REPO does not exist yet; a real run needs --create (or: gh repo create $REPO --public)"
      ;;
    *)
      log "Could not query $REPO (${REPO_ERR:-unknown error}); skipped the comparison"
      ;;
  esac
  exit 0
fi

if ((ASSET_CHECK)) && ! asset_reachable; then
  die "the release asset is not downloadable (HTTP ${ASSET_CODE:-?}): ${ASSET_URL:-unknown url}
publish the GitHub release first, or pass --skip-asset-check"
fi

check_repo
case "$REPO_STATE" in
  exists) ;;
  missing)
    ((CREATE)) || die "the tap repository $REPO does not exist; create it with 'gh repo create $REPO --public' or pass --create"
    log "Creating public repository $REPO"
    gh repo create "$REPO" --public --description "Homebrew tap for Glint"
    ;;
  *) die "could not query $REPO: ${REPO_ERR:-unknown error}" ;;
esac

WORK="$WORK_PARENT/${REPO#*/}"
rm -rf "$WORK"
mkdir -p "$WORK_PARENT"
log "Cloning $REPO into ${WORK#"$ROOT"/}"
git_net clone --quiet "https://github.com/$REPO.git" "$WORK"
cd "$WORK"

if git rev-parse --verify --quiet HEAD >/dev/null; then
  current_branch="$(git symbolic-ref --short HEAD)"
  BRANCH="${BRANCH:-$current_branch}"
  if [[ "$BRANCH" != "$current_branch" ]]; then
    if git rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null; then
      git checkout --quiet -B "$BRANCH" "origin/$BRANCH"
    else
      git checkout --quiet -B "$BRANCH"
    fi
  fi
else
  # A freshly created repository has no commits yet.
  BRANCH="${BRANCH:-main}"
  git symbolic-ref HEAD "refs/heads/$BRANCH"
fi

mkdir -p Casks
cp "$CASK_OUT" Casks/glint.rb

if [[ ! -f README.md ]]; then
  owner_lc="$(printf '%s' "${REPO%%/*}" | tr '[:upper:]' '[:lower:]')"
  tap_name="${owner_lc}/${REPO#*/homebrew-}"
  cat >README.md <<EOF
# ${REPO#*/}

Homebrew tap for [Glint](https://github.com/MrAshRhodes/glint), a macOS screenshot beautifier.

    brew install --cask ${tap_name}/glint

The cask in this repository is updated by Glint's release workflow.
EOF
fi

git add -A
if git diff --cached --quiet; then
  log "$REPO already has glint $VERSION; nothing to commit"
  exit 0
fi

git config user.name >/dev/null || git config user.name "github-actions[bot]"
git config user.email >/dev/null || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -c commit.gpgsign=false commit --quiet -m "glint $VERSION"
git_net push --quiet origin "HEAD:refs/heads/$BRANCH"
log "Published glint $VERSION to $REPO ($BRANCH)"
