#!/bin/bash
set -euo pipefail

# project.sh end to end (feature 005, US1/#72): a fixture project with the
# extension installed (tests/lib/fixture.sh) is projected, re-projected,
# edited, and half-uninstalled, and each run is checked for its exit code,
# its output, and the files it left behind. The canary suite is skipped
# (GATES_TEST=1 --skip-canary) except in the cases that test the proof.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/fixture.sh"
export GATES_TEST=1
P=.specify/extensions/gates/runtime/project.sh

PASS=0
FAIL=0
TOTAL=0
ok() { # <name> <command...>
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}
rc_is() { # <name> <expected-rc> <dir> <project.sh args...>: also keeps output in $OUT
    local name="$1" want="$2" dir="$3" rc=0
    shift 3
    OUT="$(cd "$dir" && bash "$P" "$@" 2>&1)" || rc=$?
    TOTAL=$((TOTAL + 1))
    if [[ "$rc" -eq "$want" ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (exit=$rc, expect=$want)"
        printf '%s\n' "$OUT" | sed 's/^/      /'
        FAIL=$((FAIL + 1))
    fi
}
treehash() { # <dir>: content and execute bit of every file outside .git
    (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort \
        | while IFS= read -r p; do
            printf '%s %s ' "$p" "$([[ -x "$p" ]] && echo x || echo -)"
            cksum <"$p"
        done) | cksum
}
FIXTURES=""
fixture() { # -> new fixture dir in $D
    D="$(fx_project)"
    FIXTURES="$FIXTURES $D"
}
cleanup() {
    local f
    for f in $FIXTURES; do fx_cleanup "$f"; done
}
trap cleanup EXIT

echo "=== fresh projection ==="
fixture
rc_is "dry run exits 0" 0 "$D" --dry-run --skip-canary
ok "dry run lists the writes" grep -q 'write .specify/gates/verify.sh' <<<"$OUT"
ok "dry run wrote nothing" test ! -e "$D/.specify/gates/verify.sh"
ok "check exits 1 when work is pending" bash -c "cd '$D' && ! bash '$P' --check"
rc_is "projection exits 0" 0 "$D" --skip-canary
# shellcheck source=/dev/null
while IFS=$'\t' read -r _ t; do
    ok "projected $t" test -f "$D/$t"
done < <(source "$D/.specify/extensions/gates/runtime/lib/manifest.sh" \
    && gates_projection_table "$D/.specify/extensions/gates/runtime" 1)
for t in .specify/gates/verify.sh .specify/gates/project.sh .specify/gates/lib/policy.sh \
    .specify/gates/hooks/pre-commit .specify/gates/hooks/commit-msg .claude/hooks/gates/protect-files.sh; do
    ok "executable: $t" test -x "$D/$t"
done
for h in pre-commit commit-msg; do
    ok "vendored git hook $h made executable (FR-005a)" test -x "$D/.specify/extensions/gates/runtime/hooks/git/$h"
    ok "stub installed as .git/hooks/$h" cmp -s "$D/.specify/extensions/gates/runtime/hooks/git/stub.sh" "$D/.git/hooks/$h"
    ok ".git/hooks/$h executable" test -x "$D/.git/hooks/$h"
done
ok "manifest header" grep -q '^# spec-gates-manifest v1 version=' "$D/.specify/gates/.projected.sha256"
ok "manifest verifies against the tree" bash -c "cd '$D' && tail -n +2 .specify/gates/.projected.sha256 | { sha256sum -c --quiet 2>/dev/null || shasum -a 256 -c --quiet; }"
ok ".runtime-version recorded" test -s "$D/.specify/gates/.runtime-version"
ok "attestations ignored" grep -qxF attestations.jsonl "$D/.specify/gates/.gitignore"
ok "settings carry the protect-files hook" jq -e '[.hooks.PreToolUse[].hooks[].command] | any(test("protect-files"))' "$D/.claude/settings.json"
ok "policy.json untouched" grep -qx '{ "hooks": {} }' "$D/.specify/gates/policy.json"

echo ""
echo "=== vendored modes ==="
# The fixture has the modes Spec Kit's extraction produces: every *.sh
# executable, the two extension-less git hooks not. Projection may fix
# those two and must change no other mode in the vendored copy.
fixture
vmodes() { (cd "$D/.specify/extensions/gates" && find . -type f -print | LC_ALL=C sort \
    | while IFS= read -r p; do [[ -x "$p" ]] && echo "x $p" || echo "- $p"; done); }
before="$(vmodes)"
rc_is "projection for the mode check" 0 "$D" --skip-canary
changed="$({ diff <(printf '%s\n' "$before") <(vmodes) || true; } | { grep '^>' || true; } | sed 's/^> x //' | LC_ALL=C sort | tr '\n' ' ')"
ok "only the two git hooks changed mode" test "$changed" = "./runtime/hooks/git/commit-msg ./runtime/hooks/git/pre-commit "

echo ""
echo "=== idempotence ==="
before="$(treehash "$D")"
rc_is "second run exits 0" 0 "$D" --skip-canary
ok "second run says no changes" grep -q 'no changes' <<<"$OUT"
ok "second run changed nothing" test "$before" = "$(treehash "$D")"
ok "check exits 0 when current" bash -c "cd '$D' && bash '$P' --check"

echo ""
echo "=== settings merge keeps user entries ==="
fixture
mkdir -p "$D/.claude"
# shellcheck disable=SC2016  # the literal $CLAUDE_PROJECT_DIR is the settings value
printf '%s' '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-own-hook.sh"},{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/gates/validate-bash.sh"}]}]}}' \
    >"$D/.claude/settings.json"
rc_is "projection with existing settings" 0 "$D" --skip-canary
ok "user permission kept" jq -e '.permissions.allow == ["Bash(ls)"]' "$D/.claude/settings.json"
ok "user hook kept first" jq -e '.hooks.PreToolUse[0].hooks[0].command == "my-own-hook.sh"' "$D/.claude/settings.json"
ok "already-wired command not duplicated" jq -e '[.hooks.PreToolUse[].hooks[].command | select(test("validate-bash"))] | length == 1' "$D/.claude/settings.json"
ok "missing gates hooks appended" jq -e '[.hooks.PreToolUse[].hooks[].command] | any(test("protect-files"))' "$D/.claude/settings.json"
fixture
rc_is "--no-agent-hooks" 0 "$D" --skip-canary --no-agent-hooks
ok "--no-agent-hooks writes no agent hooks" test ! -e "$D/.claude/hooks/gates"
ok "--no-agent-hooks leaves settings alone" test ! -e "$D/.claude/settings.json"

OUT="$(cd "$D" && bash .specify/gates/project.sh --check --no-agent-hooks 2>&1)" && rc=0 || rc=$?
ok "projected copy --check keeps the caller's flags" test "$rc" -eq 0

echo ""
echo "=== local edits ==="
fixture
rc_is "initial projection" 0 "$D" --skip-canary
printf '# local hardening\n' >>"$D/.specify/gates/verify.sh"
printf '\n# newer upstream\n' >>"$D/.specify/extensions/gates/runtime/verify.sh"
printf '\n# newer upstream\n' >>"$D/.specify/extensions/gates/runtime/canary.sh"
edited="$(cksum <"$D/.specify/gates/verify.sh")"
pristine="$(cksum <"$D/.specify/gates/canary.sh")"
rc_is "edited file -> exit 3" 3 "$D" --skip-canary
ok "conflict names the file" grep -q '.specify/gates/verify.sh' <<<"$OUT"
ok "conflict names both flags" bash -c "grep -q -- --take-upstream <<<\"\$1\" && grep -q -- --keep-local <<<\"\$1\"" _ "$OUT"
ok "edited file untouched" test "$edited" = "$(cksum <"$D/.specify/gates/verify.sh")"
ok "nothing else written either" test "$pristine" = "$(cksum <"$D/.specify/gates/canary.sh")"
rc_is "--keep-local resolves" 0 "$D" --skip-canary --keep-local .specify/gates/verify.sh
ok "kept file untouched" test "$edited" = "$(cksum <"$D/.specify/gates/verify.sh")"
ok "kept file added to holds" grep -qxF .specify/gates/verify.sh "$D/.specify/gates/.upgrade-holds"
ok "pristine file upgraded" grep -q 'newer upstream' "$D/.specify/gates/canary.sh"
rc_is "held file stays held on the next run" 0 "$D" --skip-canary
ok "held file reported" grep -q 'held (never overwritten' <<<"$OUT"
fixture
rc_is "initial projection" 0 "$D" --skip-canary
printf '# local\n' >>"$D/.specify/gates/doctor.sh"
rc_is "--take-upstream resolves" 0 "$D" --skip-canary --take-upstream .specify/gates/doctor.sh
ok "taken file equals upstream" cmp -s "$D/.specify/extensions/gates/runtime/doctor.sh" "$D/.specify/gates/doctor.sh"
rm -f "$D/.specify/gates/contract.sh"
rc_is "deleted projected file -> exit 3" 3 "$D" --skip-canary
rc_is "a path outside the table is refused" 2 "$D" --skip-canary --take-upstream src/app.ts

echo ""
echo "=== holds: release, deletions, path forms (#132) ==="
fixture
rc_is "initial projection" 0 "$D" --skip-canary
printf '# local\n' >>"$D/.specify/gates/doctor.sh"
rc_is "a ./-prefixed path is accepted" 0 "$D" --skip-canary --keep-local ./.specify/gates/doctor.sh
ok "the hold records the path without ./" grep -qxF .specify/gates/doctor.sh "$D/.specify/gates/.upgrade-holds"
rc_is "--take-upstream on a held file resolves" 0 "$D" --skip-canary --take-upstream .specify/gates/doctor.sh
ok "the held file now equals upstream" cmp -s "$D/.specify/extensions/gates/runtime/doctor.sh" "$D/.specify/gates/doctor.sh"
ok "the hold is released" bash -c "! grep -qxF .specify/gates/doctor.sh '$D/.specify/gates/.upgrade-holds'"
printf '# local\n' >>"$D/.specify/gates/doctor.sh"
rc_is "the same path for both flags is refused" 2 "$D" --skip-canary --keep-local .specify/gates/doctor.sh --take-upstream .specify/gates/doctor.sh
ok "the refusal says to choose" grep -q 'choose one' <<<"$OUT"
rc_is "a path with a space is one path, not two" 2 "$D" --skip-canary --keep-local ".specify/gates/no such file.sh"
ok "the refusal names the whole path" grep -q 'no such file.sh is not a projected file' <<<"$OUT"
rm -f "$D/.specify/gates/contract.sh"
rc_is "a deleted projected file can be held as deleted" 0 "$D" --skip-canary --keep-local .specify/gates/doctor.sh --keep-local .specify/gates/contract.sh
ok "the deletion stays deleted" test ! -e "$D/.specify/gates/contract.sh"
rc_is "the held deletion is left alone on the next run" 0 "$D" --skip-canary
ok "still deleted" test ! -e "$D/.specify/gates/contract.sh"
chmod -x "$D/.specify/gates/verify.sh"
rc_is "a lost execute bit is planned" 0 "$D" --skip-canary --dry-run
ok "the plan names the file" grep -q 'restore the execute bit on .specify/gates/verify.sh' <<<"$OUT"
printf '9.9.9\n' >"$D/.specify/gates/.runtime-version"
rc_is "a wrong version marker is planned" 0 "$D" --skip-canary --dry-run
ok "the plan says what the marker claimed" grep -q 'runtime-version said 9.9.9' <<<"$OUT"

echo ""
echo "=== upgrading a 0.3.x projection (no manifest) ==="
# Project v0.3.6's files the way 0.3.6 did (no manifest), then upgrade:
# the known-release table must recognize every untouched file (#70).
old036() { # <dir>: lay down v0.3.6's projected files and its version marker
    local x="$1/.old036" s t
    mkdir -p "$x"
    git -C "$REPO_ROOT" archive v0.3.6 extension/runtime | tar -x -C "$x"
    while IFS=$'\t' read -r s t; do
        mkdir -p "$(dirname "$1/$t")"
        cp "$x/extension/runtime/$s" "$1/$t"
    done < <(gates_projection_table "$x/extension/runtime" 1)
    rm -rf "$x"
    printf '0.3.6\n' >"$1/.specify/gates/.runtime-version"
}
# shellcheck source=/dev/null
source "$REPO_ROOT/extension/runtime/lib/manifest.sh"
if git -C "$REPO_ROOT" rev-parse -q --verify v0.3.6 >/dev/null; then
    fixture
    old036 "$D"
    rc_is "untouched 0.3.6 projection upgrades without conflicts" 0 "$D" --skip-canary
    ok "upgraded files equal the new release" cmp -s "$D/.specify/extensions/gates/runtime/doctor.sh" "$D/.specify/gates/doctor.sh"
    ok "manifest written by the upgrade" test -f "$D/.specify/gates/.projected.sha256"
    fixture
    old036 "$D"
    printf '# local hardening\n' >>"$D/.specify/gates/hooks/pre-commit"
    rc_is "one edited 0.3.6 file -> exit 3" 3 "$D" --skip-canary
    ok "only the edited file is listed" test "$(grep -c '^project:   \.' <<<"$OUT")" -eq 1
    ok "the edited file is the one listed" grep -q '^project:   .specify/gates/hooks/pre-commit$' <<<"$OUT"
else
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "FAIL: tag v0.3.6 not present (fetch tags: git fetch --tags)"
fi

echo ""
echo "=== holds and CI drift ==="
fixture
rc_is "initial projection" 0 "$D" --skip-canary
rc_is "--keep-local on an unedited file holds it" 0 "$D" --skip-canary --keep-local .specify/gates/doctor.sh
ok "hold recorded" grep -qxF .specify/gates/doctor.sh "$D/.specify/gates/.upgrade-holds"
rc_is "a hold equal to upstream is reported stale" 0 "$D" --skip-canary
ok "stale hold named" bash -c "grep -A1 'stale holds' <<<\"\$1\" | grep -q '.specify/gates/doctor.sh'" _ "$OUT"
rc_is "--keep-local on a missing file is refused" 2 "$D" --skip-canary --keep-local .specify/gates/nope.sh
mkdir -p "$D/.github/workflows"
printf 'jobs:\n  g:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n      - run: bash .specify/gates/canary.sh\n' \
    >"$D/.github/workflows/gates.yml"
rc_is "CI drift is reported" 0 "$D" --skip-canary
ok "the missing pr step is named" grep -q '^project:   pr$' <<<"$OUT"
printf 'ci:pr  # no PRs in this repo\n' >>"$D/.specify/gates/.upgrade-holds"
rc_is "an acknowledged omission is not reported" 0 "$D" --skip-canary
ok "no drift reported after ci:pr" bash -c "! grep -q 'lacks these template steps' <<<\"\$1\"" _ "$OUT"
fixture
printf '#!/bin/sh\necho mine\n' >"$D/.git/hooks/pre-commit"
chmod +x "$D/.git/hooks/pre-commit"
rc_is "projection with a foreign hook" 1 "$D" --skip-canary
OUT="$(cd "$D" && bash "$P" --check 2>&1)" && rc=0 || rc=$?
ok "--check exits 1 while a git hook is unwired" test "$rc" -eq 1

echo ""
echo "=== hooks.local.d and policy notices (#71) ==="
fixture
rc_is "initial projection" 0 "$D" --skip-canary
mkdir -p "$D/.specify/gates/hooks.local.d/validate-bash"
printf 'exit 0\n' >"$D/.specify/gates/hooks.local.d/validate-bash/10-mine.sh"
localsum="$(cksum <"$D/.specify/gates/hooks.local.d/validate-bash/10-mine.sh")"
printf '\n# newer upstream\n' >>"$D/.specify/extensions/gates/runtime/verify.sh"
rc_is "upgrade with local rules present" 0 "$D" --skip-canary
ok "local rule untouched" test "$localsum" = "$(cksum <"$D/.specify/gates/hooks.local.d/validate-bash/10-mine.sh")"
ok "local rule not reported" bash -c "! grep -q hooks.local.d <<<\"\$1\"" _ "$OUT"
ok "local rule not in the manifest" bash -c "! grep -q hooks.local.d '$D/.specify/gates/.projected.sha256'"
fixture
sed -i.b 's/^  version: .*/  version: "0.4.0"/' "$D/.specify/extensions/gates/extension.yml" && rm -f "$D/.specify/extensions/gates/extension.yml.b"
fx_registry "$D" 0.4.0
printf '0.3.6\n' >"$D/.specify/gates/.runtime-version"
polsum="$(cksum <"$D/.specify/gates/policy.json")"
rc_is "upgrade from 0.3.6 lists new policy settings" 0 "$D" --skip-canary
ok "the new setting is named" grep -q 'git.block_bulk_staging (since 0.4.0, default false)' <<<"$OUT"
ok "policy.json unchanged" test "$polsum" = "$(cksum <"$D/.specify/gates/policy.json")"
fixture
sed -i.b 's/^  version: .*/  version: "0.4.0"/' "$D/.specify/extensions/gates/extension.yml" && rm -f "$D/.specify/extensions/gates/extension.yml.b"
fx_registry "$D" 0.4.0
printf '0.3.6\n' >"$D/.specify/gates/.runtime-version"
printf '{ "hooks": {}, "git": { "block_bulk_staging": false } }\n' >"$D/.specify/gates/policy.json"
rc_is "a setting the policy already has is not listed" 0 "$D" --skip-canary
ok "no notice for a set key" bash -c "! grep -q 'new policy settings' <<<\"\$1\"" _ "$OUT"
fixture
rc_is "a fresh install lists no settings" 0 "$D" --skip-canary
ok "no notice on a fresh install" bash -c "! grep -q 'new policy settings' <<<\"\$1\"" _ "$OUT"

echo ""
echo "=== lint scope (#73) ==="
fixture
rc_is "no prettier in the repo: nothing reported" 0 "$D" --skip-canary
ok "no .prettierignore advice without prettier" bash -c "! grep -q prettierignore <<<\"\$1\"" _ "$OUT"
fixture
printf '{ "devDependencies": { "prettier": "3.3.3" } }\n' >"$D/package.json"
printf 'dist/' >"$D/.prettierignore"
rc_is "prettier in package.json: missing ignores reported" 0 "$D" --skip-canary
ok "each vendored path is named" bash -c "grep -q '^project:   .specify/extensions/\$' <<<\"\$1\" && grep -q '^project:   .claude/hooks/gates/\$' <<<\"\$1\"" _ "$OUT"
ok ".prettierignore untouched without the flag" test "$(cat "$D/.prettierignore")" = "dist/"
rc_is "--add-lint-ignores appends them" 0 "$D" --skip-canary --add-lint-ignores
ok "existing entry kept, last line not run together" grep -qx 'dist/' "$D/.prettierignore"
ok "all three paths added" test "$(grep -cE '^(\.specify/gates/|\.specify/extensions/|\.claude/hooks/gates/)$' "$D/.prettierignore")" -eq 3
rc_is "next run is quiet" 0 "$D" --skip-canary
ok "nothing reported once ignored" bash -c "! grep -q prettierignore <<<\"\$1\"" _ "$OUT"
before="$(cksum <"$D/.prettierignore")"
rc_is "--add-lint-ignores again changes nothing" 0 "$D" --skip-canary --add-lint-ignores
ok ".prettierignore unchanged on the second add" test "$before" = "$(cksum <"$D/.prettierignore")"

echo ""
echo "=== git probe in the proof (#74) ==="
fixture
rc_is "projection proves both git hooks" 0 "$D" --skip-canary
ok "pre-commit probe reported" grep -q 'git probe: pre-commit reaches the gates hook' <<<"$OUT"
ok "commit-msg probe reported" grep -q 'git probe: commit-msg reaches the gates hook' <<<"$OUT"
# A locally edited hook that no longer answers the probe (still valid bash).
sed 's/GATES_PROBE:-/GATES_PROBE_OFF:-/' "$D/.specify/gates/hooks/commit-msg" >"$D/cm.tmp"
cp "$D/cm.tmp" "$D/.specify/gates/hooks/commit-msg"
rc_is "a projected hook that cannot answer fails the proof" 1 "$D" --skip-canary --keep-local .specify/gates/hooks/commit-msg
ok "the failing hook is named" grep -q 'FAILED: git probe: git runs .git/hooks/commit-msg, but it does not reach the gates commit-msg hook' <<<"$OUT"

echo ""
echo "=== hook managers (#74b) ==="
# yamlq <file> <js-expression over doc>: parse the YAML with js-yaml (from the
# pinned toolchain) and print the expression; empty when node is missing.
JSYAML="$REPO_ROOT/node_modules/js-yaml"
yamlq() {
    [[ -d "$JSYAML" ]] && command -v node >/dev/null 2>&1 || return 0
    node -e "const y=require('$JSYAML');const doc=y.load(require('fs').readFileSync(process.argv[1],'utf8'));console.log($2)" "$1"
}
have_yaml() { [[ -d "$JSYAML" ]] && command -v node >/dev/null 2>&1; }

# husky 9 layout: generated shims in .husky/_ (core.hooksPath), the user's
# scripts in .husky/<hook>. The shim records that it ran.
fixture
mkdir -p "$D/.husky/_"
for h in pre-commit commit-msg; do
    # shellcheck disable=SC2016  # literal script or message text
    printf '#!/bin/sh\ntouch "$(git rev-parse --show-toplevel)/ran.txt"\ns="$(dirname "$(dirname "$0")")/$(basename "$0")"\n[ -f "$s" ] || exit 0\nsh -e "$s" "$@"\n' >"$D/.husky/_/$h"
    chmod +x "$D/.husky/_/$h"
done
printf 'npm test\n' >"$D/.husky/pre-commit"
git -C "$D" config core.hooksPath .husky/_
shims="$(cat "$D/.husky/_/pre-commit" "$D/.husky/_/commit-msg" | cksum)"
rc_is "husky without --wire-manager -> exit 1" 1 "$D" --skip-canary
ok "husky: the entry and file are printed" grep -q 'pre-commit: add to .husky/pre-commit' <<<"$OUT"
ok "husky: .husky/pre-commit untouched without the flag" test "$(cat "$D/.husky/pre-commit")" = "npm test"
rc_is "husky with --wire-manager" 0 "$D" --skip-canary --wire-manager
ok "husky: user script keeps its line and gains the call-through" bash -c "head -n 1 '$D/.husky/pre-commit' | grep -qx 'npm test' && grep -qF '.specify/gates/hooks/pre-commit' '$D/.husky/pre-commit'"
ok "husky: commit-msg script created with the call-through" grep -qF '.specify/gates/hooks/commit-msg' "$D/.husky/commit-msg"
ok "husky: generated shims untouched" test "$shims" = "$(cat "$D/.husky/_/pre-commit" "$D/.husky/_/commit-msg" | cksum)"
ok "husky: nothing written into .git/hooks" bash -c "! ls '$D/.git/hooks' | grep -qx pre-commit"
ok "husky: the hooks were checked statically, not run" test ! -e "$D/ran.txt"
rc_is "husky: a second run changes nothing" 0 "$D" --skip-canary --wire-manager
ok "husky: still one call-through line" test "$(grep -cF '.specify/gates/hooks/pre-commit' "$D/.husky/pre-commit")" -eq 1

# lefthook: config at the root, generated scripts in .git/hooks.
fixture
printf 'colors: false\n' >"$D/lefthook.yml"
rc_is "lefthook without --wire-manager -> exit 1" 1 "$D" --skip-canary
rc_is "lefthook with --wire-manager" 1 "$D" --skip-canary --wire-manager
# shellcheck disable=SC2016  # literal script or message text
ok "lefthook: tells the user to run lefthook install" grep -q 'now run `lefthook install`' <<<"$OUT"
if have_yaml; then
    ok "lefthook: the result parses and runs the gates pre-commit" test "$(yamlq "$D/lefthook.yml" 'doc["pre-commit"].commands["spec-gates"].run')" = "bash .specify/gates/hooks/pre-commit"
    ok "lefthook: commit-msg passes the message file" test "$(yamlq "$D/lefthook.yml" 'doc["commit-msg"].commands["spec-gates"].run')" = "bash .specify/gates/hooks/commit-msg {1}"
    ok "lefthook: existing keys kept" test "$(yamlq "$D/lefthook.yml" 'doc.colors')" = "false"
else
    echo "SKIP: no node + js-yaml; lefthook YAML not parsed"
fi
fixture
printf 'pre-commit:\n  commands:\n    lint:\n      run: npm run lint\n' >"$D/lefthook.yml"
cfg="$(cksum <"$D/lefthook.yml")"
printf '#!/bin/sh\n# lefthook generated\nexit 0\n' >"$D/.git/hooks/pre-commit"
chmod +x "$D/.git/hooks/pre-commit"
rc_is "lefthook: an existing pre-commit key is not edited -> exit 1" 1 "$D" --skip-canary --wire-manager
ok "lefthook: the by-hand entry is printed" grep -q 'add this by hand' <<<"$OUT"
ok "lefthook: the existing block is untouched" bash -c "head -n 4 '$D/lefthook.yml' | cksum | grep -q '$(printf '%s' "$cfg" | cut -d' ' -f1)'"
ok "lefthook: the absent commit-msg key was still added" grep -q '^commit-msg:' "$D/lefthook.yml"
if have_yaml; then
    ok "lefthook: the file still parses (no duplicate key)" test "$(yamlq "$D/lefthook.yml" 'doc["pre-commit"].commands.lint.run')" = "npm run lint"
fi
ok "lefthook: the generated hook is untouched" grep -q 'lefthook generated' "$D/.git/hooks/pre-commit"

# pre-commit framework: .pre-commit-config.yaml; repos: last, both indents.
for ind in "" "  "; do
    fixture
    printf 'default_stages: [pre-commit]\nrepos:\n%s- repo: https://github.com/pre-commit/pre-commit-hooks\n%s  rev: v4.6.0\n%s  hooks:\n%s    - id: trailing-whitespace\n' \
        "$ind" "$ind" "$ind" "$ind" >"$D/.pre-commit-config.yaml"
    rc_is "pre-commit (indent '${#ind}') with --wire-manager" 1 "$D" --skip-canary --wire-manager
    if have_yaml; then
        ok "pre-commit (indent '${#ind}'): parses with three repos" test "$(yamlq "$D/.pre-commit-config.yaml" 'doc.repos.length')" = "3"
        ok "pre-commit (indent '${#ind}'): the gates pre-commit hook" test "$(yamlq "$D/.pre-commit-config.yaml" 'doc.repos[1].hooks[0].id + " " + doc.repos[1].hooks[0].stages')" = "spec-gates-pre-commit pre-commit"
        ok "pre-commit (indent '${#ind}'): the gates commit-msg hook" test "$(yamlq "$D/.pre-commit-config.yaml" 'doc.repos[2].hooks[0].entry')" = "bash .specify/gates/hooks/commit-msg"
    fi
    ok "pre-commit (indent '${#ind}'): install hint for commit-msg" grep -q 'pre-commit install --hook-type commit-msg' <<<"$OUT"
done
fixture
printf 'repos:\n- repo: local\n  hooks: []\nci:\n  autofix_prs: false\n' >"$D/.pre-commit-config.yaml"
cfg="$(cksum <"$D/.pre-commit-config.yaml")"
rc_is "pre-commit: repos: not last -> not edited, exit 1" 1 "$D" --skip-canary --wire-manager
ok "pre-commit: file untouched" test "$cfg" = "$(cksum <"$D/.pre-commit-config.yaml")"
ok "pre-commit: by-hand entry printed" grep -q 'add this by hand' <<<"$OUT"

# Doctor reads the managers' config statically.
fixture
printf 'colors: false\n' >"$D/lefthook.yml"
rc_is "lefthook wired for doctor" 1 "$D" --skip-canary --wire-manager
for h in pre-commit commit-msg; do
    # shellcheck disable=SC2016  # literal script or message text
    printf '#!/bin/sh\n# lefthook\ntouch "$(git rev-parse --show-toplevel)/ran.txt"\n' >"$D/.git/hooks/$h"
    chmod +x "$D/.git/hooks/$h"
done
OUT="$(cd "$D" && CLAUDE_PROJECT_DIR="$D" bash .specify/gates/doctor.sh 2>&1)" || true
ok "doctor: lefthook entry found statically" grep -q 'commit-msg (static): another tool owns the hook and calls the gates commit-msg hook' <<<"$OUT"
ok "doctor: lefthook hooks not run" test ! -e "$D/ran.txt"

echo ""
echo "=== refusals before writing ==="
fixture
rm -f "$D/.specify/gates/policy.json"
rc_is "no policy.json -> exit 2" 2 "$D" --skip-canary
ok "nothing projected without a policy" test ! -e "$D/.specify/gates/verify.sh"
# An invalid policy would leave every boundary refusing to run (#124).
for bad in '{"version":' '{}' '{ "hooks": {}, "attestation": { "max_records": 0 } }'; do
    fixture
    printf '%s' "$bad" >"$D/.specify/gates/policy.json"
    rc_is "invalid policy $bad -> exit 2" 2 "$D" --skip-canary
    ok "invalid policy $bad: refusal names it" grep -qF 'the policy is invalid; fix it before projecting' <<<"$OUT"
    ok "invalid policy $bad: nothing projected" test ! -e "$D/.specify/gates/verify.sh"
done
ok "invalid policy: the validator's error is shown" grep -qF 'attestation: max_records must be an integer >= 1' <<<"$OUT"
fixture
fx_registry "$D" 9.9.9
rc_is "registry/vendored mismatch -> exit 2" 2 "$D" --skip-canary
fixture
rc_is "initial projection" 0 "$D" --skip-canary
printf 'garbage\n' >"$D/.specify/gates/.projected.sha256"
rc_is "corrupt manifest -> exit 2" 2 "$D" --skip-canary
ok "corrupt manifest kept" grep -qx garbage "$D/.specify/gates/.projected.sha256"
fixture
rc_is "initial projection" 0 "$D" --skip-canary
sed -i.bak '1s/version=.*/version=99.0.0/' "$D/.specify/gates/.projected.sha256" && rm -f "$D/.specify/gates/.projected.sha256.bak"
rc_is "newer manifest -> exit 2" 2 "$D" --skip-canary
rc_is "--allow-downgrade accepts it" 0 "$D" --skip-canary --allow-downgrade
fixture
OUT="$(cd "$D" && env -u GATES_TEST bash "$P" --skip-canary 2>&1)" && rc=0 || rc=$?
ok "--skip-canary needs GATES_TEST=1" test "$rc" -eq 2

echo ""
echo "=== half-done remove + add ==="
fixture
rc_is "initial projection" 0 "$D" --skip-canary
rm -rf "$D/.specify/extensions"
OUT="$(cd "$D" && bash .specify/gates/project.sh --check 2>&1)" && rc=0 || rc=$?
ok "projected copy reports the half-done upgrade (exit 2)" test "$rc" -eq 2
ok "it prints the add command" grep -q 'specify extension add gates --from' <<<"$OUT"

echo ""
echo "=== git boundary ==="
fixture
printf '#!/bin/sh\necho mine\n' >"$D/.git/hooks/pre-commit"
chmod +x "$D/.git/hooks/pre-commit"
rc_is "foreign pre-commit hook -> exit 1" 1 "$D" --skip-canary
ok "foreign hook untouched" grep -q 'echo mine' "$D/.git/hooks/pre-commit"
ok "call-through printed" grep -q '.specify/gates/hooks/pre-commit' <<<"$OUT"
ok "commit-msg still wired" cmp -s "$D/.specify/extensions/gates/runtime/hooks/git/stub.sh" "$D/.git/hooks/commit-msg"
# shellcheck disable=SC2016  # the call-through line is written literally
printf 'bash "$(git rev-parse --show-toplevel)/.specify/gates/hooks/pre-commit" "$@" || exit $?\n' >>"$D/.git/hooks/pre-commit"
# Leave a trace when the hook runs, before the call-through (the probe
# makes the gates hook exit, so anything after it never runs).
# shellcheck disable=SC2016  # the hook line is written literally
{ head -n 1 "$D/.git/hooks/pre-commit"; printf 'touch "$(git rev-parse --show-toplevel)/ran.txt"\n'; tail -n +2 "$D/.git/hooks/pre-commit"; } >"$D/hook.tmp"
cp "$D/hook.tmp" "$D/.git/hooks/pre-commit"
rc_is "foreign hook with the call-through -> exit 0" 0 "$D" --skip-canary
ok "the foreign hook is checked statically" grep -q 'git check (static): another tool owns pre-commit and calls the gates hook' <<<"$OUT"
ok "projection did not run the foreign hook" test ! -e "$D/ran.txt"
rc_is "--probe-git runs the full chain" 0 "$D" --skip-canary --probe-git
ok "--probe-git ran the foreign hook" test -e "$D/ran.txt"
ok "--probe-git reports the probe" grep -q 'git probe: pre-commit reaches the gates hook' <<<"$OUT"
fixture
cp "$D/.specify/extensions/gates/runtime/hooks/git/commit-msg" "$D/.git/hooks/commit-msg"
rc_is "a copied gates hook is migrated to the stub" 0 "$D" --skip-canary
ok "copied hook replaced by the stub" cmp -s "$D/.specify/extensions/gates/runtime/hooks/git/stub.sh" "$D/.git/hooks/commit-msg"
fixture
git -C "$D" config core.hooksPath .husky/_
rc_is "core.hooksPath owned by another tool -> exit 1" 1 "$D" --skip-canary
ok "nothing written into the other tool's directory" test ! -e "$D/.husky"

echo ""
echo "=== proof ==="
fixture
if python3 -c 'import json, re' >/dev/null 2>&1; then
    rc_is "projection with the canary suite" 0 "$D"
    ok "canary suite ran" grep -q 'canary: .* run, .* blocked, 0 accepted' <<<"$OUT"
else
    # Without python3 the PR hook refuses every PR command (#66), so the
    # prhook canary reports a gap and the proof must fail (#86).
    rc_is "projection without python3 fails its proof" 1 "$D"
    ok "the failure names the PR hook canary" grep -q 'prhook -- ACCEPTED' <<<"$OUT"
fi
fixture
# A hook that allows everything must fail the projection's proof.
printf '#!/bin/bash\nexit 0\n' >"$D/.specify/extensions/gates/runtime/hooks/claude/validate-bash.sh"
rc_is "an accepted canary fails the projection" 1 "$D"
ok "the failure names the canary" grep -q 'bash -- ACCEPTED' <<<"$OUT"

echo ""
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -eq 0 ]]
