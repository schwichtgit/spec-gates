#!/bin/bash
set -euo pipefail

# verify.sh gate-behaviour tests: the orchestrator dispatch itself.
#
# Regression guard for three bugs found while wiring the boundaries:
#   - the default `none` orchestrator was a silent no-op (formatter-dispatch
#     had no --check CLI), so every file "passed";
#   - the `custom` orchestrator read the wrong policy field and never ran;
#   - an empty gate set crashed verify.sh under bash 3.2.
#
# Tool-dependent checks are skipped (not failed) when the tool is absent, so
# the suite stays portable; CI has the tools installed and exercises them.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-gate)"
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

# Project the runtime into <dir> with a caller-supplied policy body. Also link
# the repo's pinned node_modules so the gate resolves the same prettier /
# markdownlint-cli2 the product uses (the check-mode never auto-downloads).
project() { # <dir> <policy-json>
    local dir="$1" policy="$2"
    mkdir -p "$dir/.specify/gates/lib"
    cp "$REPO_ROOT/extension/runtime/verify.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    printf '%s' "$policy" >"$dir/.specify/gates/policy.json"
    if [[ -d "$REPO_ROOT/node_modules" ]]; then
        ln -sfn "$REPO_ROOT/node_modules" "$dir/node_modules"
    fi
}

# True if the pinned node linters are installed (npm ci has run).
have_node_linters() { [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; }

# Run verify.sh in <dir> and echo its exit code.
gate() { # <dir> [flag...]
    local dir="$1"
    shift
    local rc=0
    CLAUDE_PROJECT_DIR="$dir" bash "$dir/.specify/gates/verify.sh" \
        --boundary ci "$@" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

expect() { # <name> <actual> <wanted>
    TOTAL=$((TOTAL + 1))
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (got $2, want $3)"
        FAIL=$((FAIL + 1))
    fi
}
skip() { # <name> <why>
    TOTAL=$((TOTAL + 1))
    SKIP=$((SKIP + 1))
    echo "SKIP: $1 ($2)"
}

NONE_PRETTIER='{ "hooks": { "prettier": { "include": ["**/*.md"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
NONE_SHELL='{ "hooks": { "shellcheck": { "include": ["**/*.sh"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'

# --- default (none) orchestrator: prettier actually checks ---
echo "=== none orchestrator enforces prettier ==="
if have_node_linters; then
    D="$WORKDIR/pretty"
    project "$D" "$NONE_PRETTIER"
    printf '#Bad md\n\n\n- x\n' >"$D/README.md"
    expect "badly-formatted md -> gate fails (exit 2)" "$(gate "$D")" 2
    printf '# Title\n\nBody text.\n' >"$D/README.md"
    expect "prettier-clean md -> gate passes (exit 0)" "$(gate "$D")" 0
else
    skip "prettier none-orchestrator checks" "run npm ci to install pinned prettier"
fi

# --- default (none) orchestrator: shellcheck actually checks ---
echo ""
echo "=== none orchestrator enforces shellcheck ==="
if command -v shellcheck >/dev/null 2>&1; then
    D="$WORKDIR/shell"
    project "$D" "$NONE_SHELL"
    # bad.sh must contain a literal unquoted $HOME (an SC2086 finding) so the
    # gate flags it; the single quotes below are intentional, not a mistake.
    # shellcheck disable=SC2016
    printf '#!/bin/bash\nrm -rf $HOME/x\n' >"$D/bad.sh"
    expect "shellcheck finding -> gate fails (exit 2)" "$(gate "$D")" 2
    rm -f "$D/bad.sh"
    printf '#!/bin/bash\necho "ok"\n' >"$D/good.sh"
    expect "clean shell -> gate passes (exit 0)" "$(gate "$D")" 0
else
    skip "shellcheck none-orchestrator checks" "shellcheck not installed"
fi

# --- files git ignores are not linted (#126) ---
# husky v9 generates .husky/_/husky.sh (no shebang, SC2148) and gitignores
# it; CI never sees it, so the local gate must not lint it either. A tracked
# file stays in scope even when an ignore pattern matches it.
echo ""
echo "=== untracked files git ignores are skipped ==="
if command -v shellcheck >/dev/null 2>&1; then
    D="$WORKDIR/ignored"
    project "$D" "$NONE_SHELL"
    git -C "$D" init -q
    mkdir -p "$D/.husky/_"
    printf '*\n' >"$D/.husky/_/.gitignore"
    printf 'echo generated\n' >"$D/.husky/_/husky.sh"
    expect "gitignored generated shell -> gate passes" "$(gate "$D")" 0
    printf 'gen/\n' >"$D/.gitignore"
    mkdir -p "$D/gen"
    printf 'echo tracked\n' >"$D/gen/tracked.sh"
    git -C "$D" add -f gen/tracked.sh
    expect "tracked file under an ignore pattern -> still checked (exit 2)" "$(gate "$D")" 2
else
    skip "gitignored-file checks" "shellcheck not installed"
fi

# --- candidate collection starts no process per file (#169) ---
# A jq and a git shim count their invocations while check mode walks a tree
# twice: once small, once with ten times the files (matching, gitignored, and
# matching no include glob). The counts must not grow with the tree. A
# stubbed linter keeps the test independent of installed tools; the meta
# line shows the candidate count is still exact.
echo ""
echo "=== candidate collection does not scale processes with files ==="
SHIM="$WORKDIR/shim"
mkdir -p "$SHIM"
for t in jq git; do
    printf '#!/bin/sh\necho %s >>"%s/calls"\nexec "%s" "$@"\n' \
        "$t" "$SHIM" "$(command -v "$t")" >"$SHIM/$t"
    chmod +x "$SHIM/$t"
done
printf '#!/bin/sh\nexit 0\n' >"$SHIM/shellcheck"
chmod +x "$SHIM/shellcheck"
D="$WORKDIR/scan"
project "$D" '{ "hooks": { "shellcheck": { "include": ["**/*.sh"], "exclude": ["vendor/**", ".specify/**"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
git -C "$D" init -q
printf 'build/\n' >"$D/.gitignore"
# Out of scope as before: a tracked file under dist/ (the find walk pruned
# it) and a symlink (find -type f skipped it).
mkdir -p "$D/dist"
: >"$D/dist/d.sh"
ln -s src/s1.sh "$D/link.sh"
git -C "$D" add dist/d.sh link.sh
# In scope as before: a file in a nested repository, which git lists only
# as a directory entry.
mkdir -p "$D/nested"
git -C "$D/nested" init -q
: >"$D/nested/n.sh"
# <count>: grow the tree to <count> files of each kind, print
# "<jq calls> <git calls> <candidates>" for one check-mode run.
scan_calls() {
    local n="$1" i meta
    mkdir -p "$D/src" "$D/build" "$D/notes" "$D/vendor"
    for ((i = 1; i <= n; i++)); do
        : >"$D/src/s$i.sh"
        : >"$D/build/b$i.sh"
        : >"$D/notes/n$i.txt"
    done
    : >"$D/vendor/v.sh"
    : >"$SHIM/calls"
    meta="$(PATH="$SHIM:$PATH" bash "$D/.specify/gates/lib/formatter-dispatch.sh" --check \
        --tool shellcheck --project-root "$D" 2>&1 >/dev/null)"
    printf '%s %s %s\n' "$(grep -c '^jq$' "$SHIM/calls")" \
        "$(grep -c '^git$' "$SHIM/calls")" \
        "$(sed -n 's/.*candidates=\([0-9]*\).*/\1/p' <<<"$meta")"
}
read -r JQ_S GIT_S CAND_S <<<"$(scan_calls 20)"
read -r JQ_L GIT_L CAND_L <<<"$(scan_calls 200)"
expect "jq calls do not grow with the tree ($JQ_S vs $JQ_L)" "$JQ_L" "$JQ_S"
expect "git calls do not grow with the tree ($GIT_S vs $GIT_L)" "$GIT_L" "$GIT_S"
expect "small tree: only matching, unignored, unexcluded files" "$CAND_S" 21
expect "large tree: only matching, unignored, unexcluded files" "$CAND_L" 201

# --- exclude globs are honored ---
echo ""
echo "=== exclude globs are honored ==="
if have_node_linters; then
    D="$WORKDIR/excl"
    project "$D" '{ "hooks": { "prettier": { "include": ["**/*.md"], "exclude": ["vendor/**"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
    mkdir -p "$D/vendor"
    printf '#bad\n\n\n- x\n' >"$D/vendor/junk.md"
    expect "bad file under excluded path -> gate passes" "$(gate "$D")" 0
else
    skip "exclude-glob check" "run npm ci to install pinned prettier"
fi

# --- markdownlint excludes hold even when a config file declares globs ---
# markdownlint-cli2 UNIONS a config's "globs" with explicit file args; the
# gate must pass --no-globs so policy file selection stays authoritative.
echo ""
echo "=== markdownlint config globs do not bypass policy excludes ==="
if have_node_linters; then
    D="$WORKDIR/mdglobs"
    project "$D" '{ "hooks": { "markdownlint": { "include": ["docs/**"], "exclude": ["machinery/**"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
    printf '{ "globs": ["**/*.md"] }\n' >"$D/.markdownlint-cli2.jsonc"
    mkdir -p "$D/docs" "$D/machinery"
    printf '# Title\n\nClean body.\n' >"$D/docs/ok.md"
    printf '#bad heading\n#another\n' >"$D/machinery/vendor.md"
    expect "excluded bad md ignored despite config globs" "$(gate "$D")" 0
    printf '#bad heading\n#another\n' >"$D/docs/bad.md"
    expect "included bad md still caught" "$(gate "$D")" 2
else
    skip "markdownlint config-glob check" "run npm ci to install pinned linters"
fi

# --- custom orchestrator reads custom_command and maps exit codes ---
echo ""
echo "=== custom orchestrator ==="
DP="$WORKDIR/custom-pass"
project "$DP" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } } }'
expect "custom true -> pass (exit 0)" "$(gate "$DP")" 0
DF="$WORKDIR/custom-fail"
project "$DF" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "false" } } }'
expect "custom false -> fail (exit 2)" "$(gate "$DF")" 2

# --- empty gate set does not crash under bash 3.2, and --json is well-formed ---
echo ""
echo "=== empty gate set (bash 3.2 regression) ==="
DE="$WORKDIR/empty"
project "$DE" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
expect "no enabled tools -> clean exit 0" "$(gate "$DE")" 0
if command -v jq >/dev/null 2>&1; then
    JSON="$(CLAUDE_PROJECT_DIR="$DE" bash "$DE/.specify/gates/verify.sh" --boundary ci --json)"
    OK="$(printf '%s' "$JSON" | jq -e '.gates | type == "array"' >/dev/null 2>&1 && echo yes || echo no)"
    expect "--json emits a well-formed gates array" "$OK" yes
else
    skip "--json shape" "jq not installed"
fi

# --- an invalid policy runs no gate (#124) ---
# The policy reader is fail-open, so before the fix a malformed or
# schema-invalid policy dropped the tool gates and the run passed.
echo ""
echo "=== invalid policy is refused before any gate ==="
# <name> <policy-json> <needle>: verify.sh exits 1, names the error, writes
# no attestation.
refused() {
    local d="$WORKDIR/inv-$1" out rc=0
    project "$d" "$2"
    out="$(CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" --boundary git 2>&1)" || rc=$?
    expect "$1: exit 1" "$rc" 1
    expect "$1: names the error" "$(grep -qF -- "$3" <<<"$out" && echo yes || echo no)" yes
    expect "$1: says no gate ran" "$(grep -qF 'no gate ran' <<<"$out" && echo yes || echo no)" yes
    expect "$1: no attestation" "$([[ -e "$d/.specify/gates/attestations.jsonl" ]] && echo yes || echo no)" no
}
VQ='"verify-quality": { "orchestrator": "none", "severity": "error" }'
refused malformed '{"version":' 'is not valid JSON'
refused empty-object '{}' 'top-level "hooks" object'
refused severity-case '{ "hooks": { "prettier": { "include": ["**/*.md"], "severity": "Error" } } }' 'invalid severity "Error"'
refused spec-severity "{ \"hooks\": { $VQ }, \"spec\": { \"severity\": \"eror\" } }" 'spec: invalid severity "eror"'
refused spec-timeout "{ \"hooks\": { $VQ }, \"spec\": { \"timeout_s\": \"abc\" } }" 'spec: timeout_s must be an integer >= 1'
refused spec-timeout-neg "{ \"hooks\": { $VQ }, \"spec\": { \"timeout_s\": -1 } }" 'spec: timeout_s must be an integer >= 1'
refused max-records-zero "{ \"hooks\": { $VQ }, \"attestation\": { \"max_records\": 0 } }" 'attestation: max_records must be an integer >= 1'
refused max-records-str "{ \"hooks\": { $VQ }, \"attestation\": { \"max_records\": \"abc\" } }" 'attestation: max_records must be an integer >= 1'
refused hook-not-object '{ "hooks": { "prettier": "on" } }' 'prettier: must be an object'

# In a contract repo the enforced file is policy.effective.json: that is
# the one validated.
D="$WORKDIR/inv-effective"
project "$D" "{ \"extends\": { \"source\": \"x\", \"version\": \"v1\" }, \"hooks\": { $VQ } }"
printf '{}' >"$D/.specify/gates/policy.effective.json"
rc=0
OUT="$(CLAUDE_PROJECT_DIR="$D" bash "$D/.specify/gates/verify.sh" --boundary ci 2>&1)" || rc=$?
expect "invalid effective policy: exit 1" "$rc" 1
expect "invalid effective policy: names policy.effective.json" \
    "$(grep -qF 'policy.effective.json must be an object' <<<"$OUT" && echo yes || echo no)" yes

# --- argument errors are usage errors, not raw bash errors (#124) ---
echo ""
echo "=== verify.sh argument handling ==="
# <name> <needle> <arg...>: exit 1 with the message and the usage line.
usage_err() {
    local name="$1" needle="$2" out rc=0
    shift 2
    out="$(CLAUDE_PROJECT_DIR="$DE" bash "$DE/.specify/gates/verify.sh" "$@" 2>&1)" || rc=$?
    expect "$name: exit 1" "$rc" 1
    expect "$name: message" "$(grep -qF -- "$needle" <<<"$out" && echo yes || echo no)" yes
    expect "$name: usage line" "$(grep -qF 'usage: verify.sh --boundary agent|git|ci' <<<"$out" && echo yes || echo no)" yes
}
usage_err "--boundary foo" 'invalid value: foo (allowed: agent, git, ci)' --boundary foo
usage_err "--boundary without a value" '--boundary needs a value' --boundary
usage_err "--boundary followed by a flag" '--boundary needs a value' --boundary --json
usage_err "--accept without a value" '--accept needs a feature name or all' --boundary ci --accept
for b in agent git ci; do
    expect "--boundary $b accepted" "$(CLAUDE_PROJECT_DIR="$DE" bash "$DE/.specify/gates/verify.sh" --boundary "$b" >/dev/null 2>&1 && echo 0 || echo $?)" 0
done
# Without git the spec gate cannot prove an accept block left the tree
# alone, so verify.sh refuses like it does without jq (#121): exit 1, the
# "could not run" code the Stop hook lets through.
echo ""
echo "=== missing git (#121) ==="
NOGIT="$WORKDIR/path-nogit"
mkdir -p "$NOGIT"
for t in bash sh jq cat grep sed awk head tail tr wc dirname basename mktemp rm cp env sort uniq cut date find; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$NOGIT/$t"
done
rc=0
out="$(CLAUDE_PROJECT_DIR="$DE" PATH="$NOGIT" bash "$DE/.specify/gates/verify.sh" --boundary ci 2>&1)" || rc=$?
expect "no git -> verify.sh exits 1" "$rc" 1
expect "no git -> the refusal names git" "$(grep -c 'git not found' <<<"$out")" 1

echo ""
echo "$PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
