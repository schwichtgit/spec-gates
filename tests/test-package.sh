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
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

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

# `if` rather than `A && B || C`: the latter is SC2015 on shellcheck 0.9.0
# (what unpinned CI used to install) even where it is harmless.
present() { # <path>
    if [[ -e "$1" ]]; then echo yes; else echo no; fi
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
cp "$REPO_ROOT/README.md" "$REPO_ROOT/LICENSE" "$REPO_ROOT/CHANGELOG.md" "$STAGE/"

echo "=== package contents ==="
expect "nested markdownlint config ships at the extension root" \
    "$(present "$STAGE/.markdownlint-cli2.jsonc")" "yes"
expect "constitution corpus ships (issue #31 regression)" \
    "$(present "$STAGE/constitution/manifest.yml")" "yes"

# Spec Kit's zip extraction keeps the execute bit only on *.sh files that
# carry it in the zip, which carries the git modes. A shipped script that is
# 100644 in git arrives 644, and project.sh then flips it to 755 inside the
# consumer's vendored copy: a mode diff in every repo that commits
# .specify/extensions/. So every shipped script is 100755 in git.
NOT_EXEC="$(cd "$REPO_ROOT" && git ls-files -s extension/runtime \
    | awk '$1 != "100755" && ($4 ~ /\.sh$/ || $4 ~ /\/hooks\/git\//) { print $4 }' | tr '\n' ' ')"
expect "every shipped runtime script is 100755 in git" "$NOT_EXEC" ""

# Spec Kit 1.x scaffolds a provides.config entry only as <id>-config.yml
# (the names `remove --keep-config` preserves) and warns on every install
# otherwise (#118). The policy lives at .specify/gates/policy.json, seeded by
# init, so the manifest declares no config file at all.
expect "extension.yml declares no provides.config" \
    "$(awk '/^provides:/ { p = 1; next } /^[^[:space:]]/ { p = 0 } p && /^  config:/ { print "yes" }' "$REPO_ROOT/extension/extension.yml")" ""

echo ""
echo "=== a consumer's repo-wide lint sweep over the installed extension ==="

if [[ -x "$BIN/markdownlint-cli2" ]]; then
    # No config at the consumer root: our nested config must carry the file.
    ML_OUT="$(cd "$WORKDIR/consumer" && "$BIN/markdownlint-cli2" '**/*.md' 2>&1)" || true
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
echo "=== we do not ship files that violate our own policy ==="

# The package carries executable shell into someone else's repository. It must
# satisfy the same shellcheck bar this project enforces on its own sources —
# at the PINNED version, because shellcheck's findings differ across releases
# (0.9.0 flags SC2015 where 0.11.0 does not, which is how an unpinned CI
# turned green local runs red).
PINNED_SC="$(awk '$1 == "shellcheck" { print $2 }' "$REPO_ROOT/.tool-versions" 2>/dev/null || true)"
expect "shellcheck version is declared in .tool-versions" \
    "$([[ -n "$PINNED_SC" ]] && echo yes || echo no)" "yes"

if command -v shellcheck >/dev/null 2>&1; then
    LOCAL_SC="$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2 }')"
    if [[ -n "$PINNED_SC" && "$LOCAL_SC" != "$PINNED_SC" ]]; then
        echo "SKIP: local shellcheck $LOCAL_SC != pinned $PINNED_SC — the parity gate reports this drift; not asserting findings against an unpinned binary"
    else
        SHIPPED_SH="$(find "$STAGE" -name '*.sh' -type f | sort)"
        SC_RC=0
        # shellcheck disable=SC2086  # deliberate word split of the file list
        shellcheck $SHIPPED_SH >"$WORKDIR/shellcheck.out" 2>&1 || SC_RC=$?
        expect "shipped shell passes shellcheck $PINNED_SC" "$SC_RC" "0"
        [[ "$SC_RC" -ne 0 ]] && head -12 "$WORKDIR/shellcheck.out" | awk '{ print "    " $0 }'
    fi
else
    echo "SKIP: shellcheck not installed"
fi

# Every shipped shell file must parse under the oldest bash it meets: hooks
# run through their shebang (#!/bin/bash), which on macOS is bash 3.2.
# 0.3.4 shipped a validate-pr.sh that only bash >= 4 could parse. Runs
# wherever a 3.x /bin/bash exists (any Mac, and the macOS CI job).
echo ""
echo "=== shipped shell parses under the stock macOS bash (3.2) ==="
if [[ -x /bin/bash ]] && /bin/bash -c '[[ ${BASH_VERSINFO[0]} -lt 4 ]]'; then
    BAD32=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in *.json | *.md | *.yml | *.yaml) continue ;; esac
        head -n 1 "$f" | grep -q 'bash' || [[ "$f" == *.sh ]] || continue
        /bin/bash -n "$f" 2>/dev/null || BAD32="$BAD32 ${f#"$REPO_ROOT"/}"
    done < <(find "$REPO_ROOT/extension/runtime" -type f | sort)
    expect "every shipped script parses under /bin/bash $(/bin/bash -c 'echo $BASH_VERSION')" "${BAD32:-none}" "none"
else
    echo "SKIP: no bash 3.x at /bin/bash (the macOS CI job covers this)"
fi

# Every script runs under pipefail. `echo "$x" | grep -q` (or `| head`)
# stops reading at the first match, the writer dies of SIGPIPE once $x
# outgrows the pipe buffer, and pipefail turns the match into a miss: the
# secret scan let a key through in any staged file over 64 KB (#117). Feed
# grep -q from a here-string instead.
echo ""
echo "=== no pipe into grep -q or head in shipped shell (#117) ==="
PIPED="$(grep -rnE '(^|[^|])[|][[:space:]]*grep[[:space:]]+-[A-Za-z]*q|(echo|printf)[^|]*[|][[:space:]]*head' \
    "$REPO_ROOT/extension/runtime" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
expect "no shipped line pipes into grep -q or head" "${PIPED:-none}" "none"
# shellcheck disable=SC2001  # sed, not ${PIPED//...}: the slow form in bash 3.2
[[ -n "$PIPED" ]] && sed "s|$REPO_ROOT/||; s/^/    /" <<<"$PIPED"

echo ""
echo "test-package: $PASS/$TOTAL passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
