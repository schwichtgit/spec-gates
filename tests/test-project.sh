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
echo "=== refusals before writing ==="
fixture
rm -f "$D/.specify/gates/policy.json"
rc_is "no policy.json -> exit 2" 2 "$D" --skip-canary
ok "nothing projected without a policy" test ! -e "$D/.specify/gates/verify.sh"
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
rc_is "foreign hook with the call-through -> exit 0" 0 "$D" --skip-canary
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
