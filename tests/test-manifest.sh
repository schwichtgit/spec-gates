#!/bin/bash
# shellcheck disable=SC2034  # GATES_* globals set here are read by the library
set -euo pipefail

# Unit tests for lib/manifest.sh and lib/install-state.sh (feature 005):
# hashing, version order, the projection table, manifest validation and
# round trip, holds, per-file classification, and the install states.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RT="$REPO_ROOT/extension/runtime"
# shellcheck source=/dev/null
source "$RT/lib/manifest.sh"
# shellcheck source=/dev/null
source "$RT/lib/install-state.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/fixture.sh"

PASS=0
FAIL=0
TOTAL=0
ok() { # <name> <command...>: pass when the command succeeds
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
eq() { # <name> <expected> <actual>
    TOTAL=$((TOTAL + 1))
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (expected '$2', got '$3')"
        FAIL=$((FAIL + 1))
    fi
}

W="$(mktemp -d 2>/dev/null || mktemp -d -t gates-manifest)"
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || rm -rf "$W"' EXIT

echo "=== hashing and versions ==="
printf 'abc' >"$W/f"
eq "sha256 of 'abc'" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$(gates_sha256 "$W/f")"
mkdir "$W/nosha"
for t in cat sed awk head; do ln -s "$(type -P "$t")" "$W/nosha/$t"; done
rc=0
PATH="$W/nosha" gates_sha256 "$W/f" >/dev/null 2>&1 || rc=$?
ok "no sha tool -> fails" test "$rc" -ne 0
eq "0.3.6 < 0.4.0" -1 "$(gates_version_cmp 0.3.6 0.4.0)"
eq "0.10.0 > 0.9.9" 1 "$(gates_version_cmp 0.10.0 0.9.9)"
eq "0.4.0 == 0.4.0" 0 "$(gates_version_cmp 0.4.0 0.4.0)"

echo ""
echo "=== projection table ==="
T="$(gates_projection_table "$RT" 1)"
for want in ".specify/gates/verify.sh" ".specify/gates/project.sh" ".specify/gates/lib/manifest.sh" \
    ".specify/gates/policy.schema.json" ".specify/gates/hooks/commit-msg" ".specify/gates/hooks/stub.sh" \
    ".claude/hooks/gates/protect-files.sh" ".specify/gates/install-shellcheck.sh" \
    ".specify/gates/shellcheck.sha256"; do
    ok "table lists $want" grep -qF "$want" <<<"$T"
done
ok "table never lists hooks.local.d" bash -c "! grep -q hooks.local.d <<<\"\$1\"" _ "$T"
ok "table never lists policy.json" bash -c "! grep -q 'policy.json\$' <<<\"\$1\"" _ "$T"
ok "--no-agent-hooks drops .claude/hooks/gates" bash -c "! grep -q '.claude/hooks/gates' <<<\"\$1\"" _ "$(gates_projection_table "$RT" 0)"
ok "table never lists the project's own shellcheck pins" bash -c "! grep -q shellcheck.local <<<\"\$1\"" _ "$T"
ok "git hooks are exec targets" gates_is_exec_target .specify/gates/hooks/pre-commit
ok "the shellcheck installer is an exec target" gates_is_exec_target .specify/gates/install-shellcheck.sh
ok "schema is not an exec target" bash -c "source '$RT/lib/manifest.sh'; ! gates_is_exec_target .specify/gates/policy.schema.json"

echo ""
echo "=== manifest validation ==="
R="$W/root"
mkdir -p "$R/.specify/gates"
M="$R/$GATES_MANIFEST_REL"
H64="$(printf 'a%.0s' $(seq 1 64))"
gates_manifest_load "$R"
eq "absent manifest" absent "$GATES_MANIFEST_STATUS"
printf '%s  .specify/gates/verify.sh\n' "$H64" | gates_manifest_write "$R" 0.4.0
gates_manifest_load "$R"
eq "round trip status" ok "$GATES_MANIFEST_STATUS"
eq "round trip version" 0.4.0 "$GATES_MANIFEST_VERSION"
eq "round trip hash" "$H64" "$(gates_manifest_hash .specify/gates/verify.sh)"
corrupt() { # <name> <content>
    printf '%s' "$2" >"$M"
    gates_manifest_load "$R"
    eq "corrupt: $1" corrupt "$GATES_MANIFEST_STATUS"
}
corrupt "no header" "$H64  .specify/gates/verify.sh"$'\n'
corrupt "unknown header version" "# spec-gates-manifest v2 version=0.4.0"$'\n'
corrupt "short hash" "# spec-gates-manifest v1 version=0.4.0"$'\n'"abc  .specify/gates/verify.sh"$'\n'
corrupt "path outside the runtime" "# spec-gates-manifest v1 version=0.4.0"$'\n'"$H64  src/app.ts"$'\n'
corrupt "dot-dot path" "# spec-gates-manifest v1 version=0.4.0"$'\n'"$H64  .specify/gates/../x"$'\n'
corrupt "bad version" "# spec-gates-manifest v1 version=latest"$'\n'

echo ""
echo "=== holds ==="
printf '# kept on purpose\n.specify/gates/verify.sh  # local fix\nci:pr\n\n' >"$R/$GATES_HOLDS_REL"
gates_holds_load "$R"
ok "path hold read (comment stripped)" gates_is_held .specify/gates/verify.sh
ok "ci: lines are not path holds" bash -c "source '$RT/lib/manifest.sh'; gates_holds_load '$R'; ! gates_is_held ci:pr"

echo ""
echo "=== classification ==="
S="$W/src"
mkdir -p "$S"
printf 'v2\n' >"$S/a.sh"
printf '%s  .specify/gates/a.sh\n%s  .specify/gates/gone.sh\n' \
    "$(printf 'v1\n' >"$W/v1" && gates_sha256 "$W/v1")" "$H64" | gates_manifest_write "$R" 0.3.9
gates_manifest_load "$R"
rm -f "$R/$GATES_HOLDS_REL"
gates_holds_load "$R"
eq "absent target" absent "$(gates_classify "$R" "$S/a.sh" .specify/gates/new.sh)"
printf 'v1\n' >"$R/.specify/gates/a.sh"
eq "matches manifest -> pristine" pristine "$(gates_classify "$R" "$S/a.sh" .specify/gates/a.sh)"
printf 'v2\n' >"$R/.specify/gates/a.sh"
eq "equals upstream -> upstream" upstream "$(gates_classify "$R" "$S/a.sh" .specify/gates/a.sh)"
printf 'v1 plus a local fix\n' >"$R/.specify/gates/a.sh"
eq "differs from both -> edited" edited "$(gates_classify "$R" "$S/a.sh" .specify/gates/a.sh)"
eq "deleted after projection -> edited" edited "$(gates_classify "$R" "$S/a.sh" .specify/gates/gone.sh)"
printf '.specify/gates/a.sh\n' >"$R/$GATES_HOLDS_REL"
gates_holds_load "$R"
eq "held wins over edited" held "$(gates_classify "$R" "$S/a.sh" .specify/gates/a.sh)"
eq "hooks.local.d is never classified" local "$(gates_classify "$R" "$S/a.sh" .specify/gates/hooks.local.d/x/1.sh)"

echo ""
echo "=== known-release table ==="
# Fresh from the tags (it is generated) and covering every manifest-less
# release (v0.3.x; 0.4.0 and later write .projected.sha256).
if git -C "$REPO_ROOT" rev-parse -q --verify v0.3.0 >/dev/null; then
    ok "table matches a fresh build from the release tags" bash "$REPO_ROOT/scripts/known-releases.sh" --check
else
    eq "release tags present (git fetch --tags)" yes no
fi
KN="$RT/lib/known-releases.sha256"
for v in $(git -C "$REPO_ROOT" tag -l 'v0.3.*' | sed 's/^v//'); do
    ok "table covers $v" grep -q "^$v"$'\t' "$KN"
done
GATES_KNOWN_FILE="$KN"
h036="$(awk -F '\t' '$1 == "0.3.6" && $3 == ".specify/gates/verify.sh" { print $2; exit }' "$KN")"
ok "a released hash matches" gates_known_match .specify/gates/verify.sh "$h036"
ok "the same hash under another path does not" bash -c "source '$RT/lib/manifest.sh'; GATES_KNOWN_FILE='$KN'; ! gates_known_match .specify/gates/doctor.sh '$h036'"
gates_manifest_load "$W/empty-root"
mkdir -p "$W/k/.specify/gates" "$W/ksrc"
printf 'new\n' >"$W/ksrc/verify.sh"
git -C "$REPO_ROOT" show v0.3.6:extension/runtime/verify.sh >"$W/k/.specify/gates/verify.sh"
GATES_HOLDS=""
eq "no manifest, released content -> pristine" pristine "$(gates_classify "$W/k" "$W/ksrc/verify.sh" .specify/gates/verify.sh)"
printf '# edit\n' >>"$W/k/.specify/gates/verify.sh"
eq "no manifest, edited content -> edited" edited "$(gates_classify "$W/k" "$W/ksrc/verify.sh" .specify/gates/verify.sh)"
GATES_KNOWN_FILE=""

echo ""
echo "=== CI drift ==="
C="$W/ci"
mkdir -p "$C/.github/workflows" "$C/.specify/gates"
rc=0; gates_ci_files "$C" >/dev/null || rc=$?
eq "no pipeline -> gates_ci_files returns 1" 1 "$rc"
printf 'on: push\njobs:\n  lint:\n    steps:\n      - run: npm test\n' >"$C/.github/workflows/other.yml"
rc=0; gates_ci_files "$C" >/dev/null || rc=$?
eq "a pipeline without the gates step does not count" 1 "$rc"
printf 'steps:\n  - run: bash .specify/gates/verify.sh  --boundary ci\n' >"$C/.github/workflows/gates.yml"
eq "gates pipeline found" ".github/workflows/gates.yml" "$(gates_ci_files "$C")"
eq "missing steps listed" "canary pr" "$(gates_ci_missing "$C" | tr '\n' ' ' | sed 's/ $//')"
printf '  - run: bash .specify/gates/canary.sh\n' >>"$C/.github/workflows/other.yml"
printf '  - run: bash .specify/gates/verify.sh --boundary ci\n' >>"$C/.github/workflows/other.yml"
eq "steps are judged over every gates pipeline" "pr" "$(gates_ci_missing "$C")"
printf 'ci:pr\n' >"$C/$GATES_HOLDS_REL"
eq "ci:<id> acknowledges an omission" "" "$(gates_ci_missing "$C")"
rm -rf "$C/.github"
printf 'gates:\n  script:\n    - bash .specify/gates/verify.sh --boundary ci\n    - bash .specify/gates/pr-check.sh\n' >"$C/.gitlab-ci.yml"
rm -f "$C/$GATES_HOLDS_REL"
eq "GitLab pipeline" "canary" "$(gates_ci_missing "$C")"
rm -f "$C/.gitlab-ci.yml"
printf "stage('Gates') { sh 'bash .specify/gates/verify.sh --boundary ci'; sh 'bash .specify/gates/canary.sh'; sh 'bash .specify/gates/pr-check.sh' }\n" >"$C/Jenkinsfile"
eq "Jenkins pipeline with every step" "" "$(gates_ci_missing "$C")"
for tpl in github/gates.yml gitlab/gates.gitlab-ci.yml jenkins/Jenkinsfile.gates; do
    rm -rf "$C/.github" "$C/.gitlab-ci.yml" "$C/Jenkinsfile"
    case "$tpl" in
        github/*) mkdir -p "$C/.github/workflows" && cp "$REPO_ROOT/extension/ci/$tpl" "$C/.github/workflows/gates.yml" ;;
        gitlab/*) cp "$REPO_ROOT/extension/ci/$tpl" "$C/.gitlab-ci.yml" ;;
        jenkins/*) cp "$REPO_ROOT/extension/ci/$tpl" "$C/Jenkinsfile" ;;
    esac
    eq "shipped template $tpl has no drift" "" "$(gates_ci_missing "$C")"
done

echo ""
echo "=== install states ==="
D="$(fx_project)"
eq "installed, not projected -> dormant" dormant "$(gates_install_state "$D")"
printf '0.3.6\n' >"$D/.specify/gates/.runtime-version"
eq "installed and projected" installed "$(gates_install_state "$D")"
mkdir "$D/.specify/extensions/gates/.specify-dev"
eq "dev install" dev "$(gates_install_state "$D")"
rmdir "$D/.specify/extensions/gates/.specify-dev"
fx_registry "$D" 9.9.9
eq "registry/vendored disagree -> mismatch" mismatch "$(gates_install_state "$D")"
rm -rf "$D/.specify/extensions"
eq "extension removed, runtime projected -> removed" removed "$(gates_install_state "$D")"
rm -f "$D/.specify/gates/.runtime-version"
eq "nothing at all -> absent" absent "$(gates_install_state "$D")"
fx_cleanup "$D"

echo ""
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -eq 0 ]]
