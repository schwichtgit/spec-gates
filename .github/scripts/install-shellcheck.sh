#!/bin/bash
# shellcheck shell=bash
set -euo pipefail

# Install the shellcheck version pinned in .tool-versions, verified against
# the checksums pinned in .github/shellcheck.sha256 (#107).
#
# The shellcheck project publishes no checksum files, so this repository
# pins the SHA-256 of each release asset it uses, taken from GitHub's own
# asset digests. A download that does not match is never extracted. The asset follows the
# machine (linux/darwin, x86_64/aarch64); anything else fails clearly
# instead of installing a binary that cannot run.
#
# Usage:
#   install-shellcheck.sh [install-dir]   default /usr/local/bin (sudo if needed)
#   install-shellcheck.sh --update        re-pin: rewrite .github/shellcheck.sha256
#                                         for the version in .tool-versions
#
# --update reads each asset's digest from the GitHub release (needs gh) and
# checks it against a fresh download before writing, so a version bump is
# one reviewable change: .tool-versions plus the new checksums.

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUMS="$REPO/.github/shellcheck.sha256"
VERSION="$(awk '$1 == "shellcheck" { print $2 }' "$REPO/.tool-versions")"
[[ -n "$VERSION" ]] || { echo "install-shellcheck: .tool-versions declares no shellcheck version" >&2; exit 1; }
BASE="https://github.com/koalaman/shellcheck/releases/download/v$VERSION"

sha256() { # <file>
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t install-shellcheck)"
trap 'rm -rf "$TMP"' EXIT

if [[ "${1:-}" == "--update" ]]; then
    command -v gh >/dev/null 2>&1 || { echo "install-shellcheck: --update needs gh" >&2; exit 1; }
    : >"$TMP/sums"
    for plat in darwin.aarch64 darwin.x86_64 linux.aarch64 linux.x86_64; do
        asset="shellcheck-v$VERSION.$plat.tar.xz"
        digest="$(gh api "repos/koalaman/shellcheck/releases/tags/v$VERSION" \
            -q ".assets[] | select(.name == \"$asset\") | .digest" | sed 's/^sha256://')"
        [[ -n "$digest" ]] || { echo "install-shellcheck: no published digest for $asset" >&2; exit 1; }
        curl -fsSL -o "$TMP/$asset" "$BASE/$asset"
        [[ "$(sha256 "$TMP/$asset")" == "$digest" ]] \
            || { echo "install-shellcheck: $asset does not match its published digest" >&2; exit 1; }
        printf '%s  %s\n' "$digest" "$asset" >>"$TMP/sums"
    done
    cp "$TMP/sums" "$SUMS"
    echo "install-shellcheck: pinned shellcheck $VERSION in ${SUMS#"$REPO"/}"
    exit 0
fi

DEST="${1:-/usr/local/bin}"
case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) echo "install-shellcheck: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) echo "install-shellcheck: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
asset="shellcheck-v$VERSION.$os.$arch.tar.xz"
expected="$(awk -v a="$asset" '$2 == a { print $1 }' "$SUMS")"
[[ -n "$expected" ]] || {
    echo "install-shellcheck: no pinned checksum for $asset in ${SUMS#"$REPO"/} (run --update after bumping .tool-versions)" >&2
    exit 1
}

curl -fsSL -o "$TMP/$asset" "$BASE/$asset"
actual="$(sha256 "$TMP/$asset")"
if [[ "$actual" != "$expected" ]]; then
    echo "install-shellcheck: checksum mismatch for $asset" >&2
    echo "  expected $expected" >&2
    echo "  got      $actual" >&2
    exit 1
fi
tar -xJf "$TMP/$asset" -C "$TMP"
if [[ -w "$DEST" ]]; then
    install -m 0755 "$TMP/shellcheck-v$VERSION/shellcheck" "$DEST/shellcheck"
else
    sudo install -m 0755 "$TMP/shellcheck-v$VERSION/shellcheck" "$DEST/shellcheck"
fi
installed="$("$DEST/shellcheck" --version | awk '/^version:/ { print $2 }')"
[[ "$installed" == "$VERSION" ]] || { echo "install-shellcheck: installed $installed, pinned $VERSION" >&2; exit 1; }
echo "install-shellcheck: shellcheck $VERSION ($os.$arch), checksum verified"
