#!/usr/bin/env bash
# Fetch the two upstream reference trees a 3-way merge needs.
#
#   BASE   = the upstream release our tree currently derives from
#   THEIRS = the upstream release we are bumping to
#
# The fork has no shared git history with upstream (our history is 50 commits
# deep and was never grafted onto Telegram's), so a plain `git merge` has no
# merge base. merge3.py reconstructs one per file from these two trees instead.
#
# Trees are cloned to a scratch dir on purpose: they are ~1 GB each and must not
# enter the repo. Re-run this whenever the container is recreated — the scratch
# dir is ephemeral, which is why this script lives in git and the trees do not.
#
# Usage:
#   fetch_upstream.sh                       # defaults: 12.8 -> 12.9.2
#   fetch_upstream.sh release-12.9 release-12.10
#   UPSTREAM_DIR=/some/path fetch_upstream.sh

set -euo pipefail

BASE_TAG="${1:-release-12.8}"
THEIRS_TAG="${2:-release-12.9.2}"
UPSTREAM_DIR="${UPSTREAM_DIR:-/tmp/upstream}"
REMOTE="${UPSTREAM_REMOTE:-https://github.com/TelegramMessenger/Telegram-iOS.git}"

mkdir -p "$UPSTREAM_DIR"

fetch_tag() {
    local tag="$1"
    local dest="$UPSTREAM_DIR/$tag"

    if [ -d "$dest/.git" ]; then
        local have
        have="$(git -C "$dest" describe --tags --always 2>/dev/null || echo unknown)"
        echo "== $tag already present at $dest ($have)"
        return 0
    fi

    echo "== cloning $tag -> $dest"
    rm -rf "$dest"
    # --depth 1: only the tagged tree matters, not its history.
    # No submodules: they are third-party blobs we never merge by hand.
    git clone --depth 1 --branch "$tag" --single-branch "$REMOTE" "$dest"
    echo "   $(git -C "$dest" log --format='%H %ci' -1)"
}

fetch_tag "$BASE_TAG"
fetch_tag "$THEIRS_TAG"

cat <<EOF

Ready:
  BASE   $UPSTREAM_DIR/$BASE_TAG
  THEIRS $UPSTREAM_DIR/$THEIRS_TAG

Next:
  python3 build-system/merge-tools/merge3.py --audit \\
      --base "$UPSTREAM_DIR/$BASE_TAG" --theirs "$UPSTREAM_DIR/$THEIRS_TAG"
EOF
