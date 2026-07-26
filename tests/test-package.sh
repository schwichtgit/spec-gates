#!/bin/bash
set -euo pipefail

# Package tests: what a CONSUMER's repo sees after installing the extension.
#
# Projection puts our files in someone else's tree, so their repo-wide lint
# runs reach our vendored content. Formatting cannot solve that in general
# (any style we pick fails somebody's config) — but our shipped markdown must
# at least be clean under DEFAULT tooling, and the nested markdownlint config
# that keeps it that way must actually be in the package. Both are asserted
# here against a staged copy that mirrors the release workflow exactly.
#
# Skips (never fails) when the pinned linters are not installed.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/node_modules/.bin"

PASS=0
FAIL=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-package-test)"
trap '[[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT

expect() { # <name> <actual> <wanted>
    TOTAL=$((TOTAL + 1))
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (got '$2', want '$3')"
        FAIL=$((FAIL + 1))
    fi
}

# Stage the package exactly as .github/workflows/release.yml does.
STAGE="$WORKDIR/consumer/.specify/extensions/gates"
mkdir -p "$STAGE"
cp -R "$REPO_ROOT/extension/extension.yml" "$REPO_ROOT/extension/commands" \
    "$REPO_ROOT/extension/runtime" "$REPO_ROOT/extension/ci" \
    "$REPO_ROOT/extension/constitution" "$STAGE/"
# Tolerated so a MISSING file is reported by the assertions below rather than
# aborting the suite — the assertions are the diagnostic, not the copy.
cp "$REPO_ROOT/extension/.markdownlint-cli2.jsonc" "$STAGE/" 2>/dev/null || true
cp "$REPO_ROOT/README.md" "$REPO_ROOT/LICENSE" "$STAGE/"

echo "=== package contents ==="
expect "nested markdownlint config ships at the extension root" \
    "$([[ -f "$STAGE/.markdownlint-cli2.jsonc" ]] && echo yes || echo no)" "yes"
expect "constitution corpus ships (issue #31 regression)" \
    "$([[ -f "$STAGE/constitution/manifest.yml" ]] && echo yes || echo no)" "yes"

echo ""
echo "=== a consumer's repo-wide lint sweep over the installed extension ==="

if [[ -x "$BIN/markdownlint-cli2" ]]; then
    # No config at the consumer root: our nested config must carry the file.
    ML_OUT="$(cd "$WORKDIR/consumer" && "$BIN/markdownlint-cli2" '**/*.md' 2>&1 || true)"
    ML_ERRORS="$(printf '%s\n' "$ML_OUT" | grep -cE ' (error|warning) MD[0-9]+' || true)"
    expect "shipped markdown has zero markdownlint errors under consumer defaults" \
        "$ML_ERRORS" "0"
    if [[ "$ML_ERRORS" != "0" ]]; then
        printf '%s\n' "$ML_OUT" | grep -E ' (error|warning) MD[0-9]+' | head -5 | awk '{ print "    " $0 }'
    fi
else
    echo "SKIP: markdownlint-cli2 not installed (npm ci to enable this check)"
fi

if [[ -x "$BIN/prettier" ]]; then
    # Default prettier settings: our files are authored with defaults, so a
    # consumer running stock prettier must see a clean tree. (A consumer with
    # a CUSTOM config is handled by the .prettierignore seeding in init step
    # 3c — no shipped formatting can satisfy every config.)
    PR_RC=0
    (cd "$WORKDIR/consumer" && "$BIN/prettier" --check . >"$WORKDIR/prettier.out" 2>&1) || PR_RC=$?
    expect "shipped files are clean under default prettier" "$PR_RC" "0"
    [[ "$PR_RC" -ne 0 ]] && grep '^\[warn\]' "$WORKDIR/prettier.out" | head -5 | awk '{ print "    " $0 }'
else
    echo "SKIP: prettier not installed (npm ci to enable this check)"
fi

echo ""
echo "test-package: $PASS/$TOTAL passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
