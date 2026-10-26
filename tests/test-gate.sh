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
# prettier reads .gitignore itself and skips a named file it lists, so the
# same tracked-file rule needs --ignore-path (#199); .prettierignore holds.
if have_node_linters; then
    D="$WORKDIR/ignored-md"
    project "$D" "$NONE_PRETTIER"
    git -C "$D" init -q
    printf '*.md\n' >"$D/.gitignore"
    printf '#Bad md\n\n\n- x\n' >"$D/README.md"
    git -C "$D" add -f README.md
    expect "tracked md listed in .gitignore -> prettier still checks it (exit 2)" "$(gate "$D")" 2
    printf 'README.md\n' >"$D/.prettierignore"
    expect "tracked md listed in .prettierignore -> prettier skips it" "$(gate "$D")" 0
else
    skip "prettier tracked-but-gitignored check" "run npm ci to install pinned prettier"
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

# --- the failing-gate summary names the failure (#262) ---
# The detail is the output's last 2000 bytes; the summary used to be the
# first line of that window, a line near the cut.
echo ""
echo "=== failing-gate summary line ==="
DS="$WORKDIR/summary"
project "$DS" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "sh ./step.sh" } } }'
i=0
while [[ $i -lt 100 ]]; do
    echo "noise line $i padding padding padding"
    i=$((i + 1))
done >"$DS/noise.txt"
{
    echo '#!/bin/sh'
    echo 'cat noise.txt'
    echo 'echo "LAST-LINE-262 the real error"'
    echo 'echo ""'
    echo 'exit 1'
} >"$DS/step.sh"
summary_line() { # <dir>: the report line of the custom gate
    (cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$1/.specify/gates/verify.sh" --boundary ci 2>&1) \
        | grep '^  \[fail\] custom' || true
}
expect "output over 2000 bytes: the summary is its last non-empty line" \
    "$(summary_line "$DS")" "  [fail] custom -- LAST-LINE-262 the real error"
{
    echo '#!/bin/sh'
    echo 'echo "##gates-fail## FIRST-MARK-262"'
    echo 'echo "##gates-fail## PICKED-MARK-262 lint found 3 errors"'
    echo 'cat noise.txt'
    echo 'echo "  ##gates-fail## TAIL-MARK-262 visible"'
    echo 'echo "trailing line"'
    echo 'exit 1'
} >"$DS/step.sh"
expect "a ##gates-fail## line wins over the last line (the last one wins)" \
    "$(summary_line "$DS")" "  [fail] custom -- TAIL-MARK-262 visible"
SJ="$(cd "$DS" && CLAUDE_PROJECT_DIR="$DS" bash "$DS/.specify/gates/verify.sh" --boundary ci --json 2>/dev/null || true)"
SJD="$(jq -r '.gates[] | select(.name == "custom") | .detail' <<<"$SJ")"
expect "--json detail keeps the marked text" \
    "$(grep -c 'TAIL-MARK-262 visible' <<<"$SJD")" 1
expect "--json detail carries no ##gates-fail## marker" \
    "$(grep -c 'gates-fail##' <<<"$SJD" || true)" 0
expect "text report carries no ##gates-fail## marker" \
    "$(cd "$DS" && CLAUDE_PROJECT_DIR="$DS" bash "$DS/.specify/gates/verify.sh" --boundary ci 2>&1 | grep -c 'gates-fail##' || true)" 0

# A file linter's output opens with banners and ends with a footer
# (prettier's "Run Prettier with --write", shellcheck's wiki links), so
# its summary is the first finding, marked by the dispatch.
# <tool> <policy> <ext> <bad-content>: 150 bad files, so the output
# outgrows the 2000-byte detail window.
linter_summary() {
    local d="$WORKDIR/sum-$1" i=100 v
    project "$d" "$2"
    while [[ $i -lt 250 ]]; do
        printf '%b' "$4" >"$d/bad$i.$3"
        i=$((i + 1))
    done
    v="$d/.specify/gates/verify.sh"
    expect "$1: the output fills the detail window" \
        "$(CI=true CLAUDE_PROJECT_DIR="$d" bash "$v" --boundary ci --json 2>/dev/null \
            | jq -r --arg t "$1" '.gates[] | select(.name == $t) | .detail | length > 1900')" true
    # CI=true as in every GitHub Actions job: prettier then colors its
    # "[warn]" lines even without a terminal.
    S="$(CI=true CLAUDE_PROJECT_DIR="$d" bash "$v" --boundary ci 2>&1 | grep "^  \[fail\] $1 -- " || true)"
    [[ -n "${GATES_TEST_VERBOSE:-}" ]] && echo "  $1 summary: $S"
    return 0
}
if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # the bad file's literal $HOME
    linter_summary shellcheck "$NONE_SHELL" sh '#!/bin/bash\nrm -rf $HOME/x\n'
    expect "shellcheck: the summary names the first finding, not the footer" \
        "$(grep -cE '^  \[fail\] shellcheck -- bad[0-9]+\.sh line 2: SC2086 \(info\): ' <<<"$S")" 1
else
    skip "shellcheck summary" "shellcheck not installed"
fi
if have_node_linters; then
    linter_summary prettier "$NONE_PRETTIER" md '#Bad md\n\n\n- x\n'
    expect "prettier: the summary names an unformatted file, not the footer" \
        "$(grep -cE '^  \[fail\] prettier -- \[warn\] bad[0-9]+\.md$' <<<"$S")" 1
    linter_summary markdownlint '{ "hooks": { "markdownlint": { "include": ["**/*.md"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }' md '#Bad md\n'
    expect "markdownlint: the summary names the first finding, not the banner" \
        "$(grep -cE '^  \[fail\] markdownlint -- bad[0-9]+\.md:1(:1)? error MD' <<<"$S")" 1
else
    skip "prettier and markdownlint summaries" "run npm ci to install pinned linters"
fi

# --- one gate run per working tree (#263) ---
# A second run used to see the first one's writes and fail on them. The
# holder's custom step blocks until the test creates "release", so the
# timing does not depend on machine load.
echo ""
echo "=== gate lock ==="
DL="$WORKDIR/lock"
project "$DL" "{ \"hooks\": { \"verify-quality\": { \"orchestrator\": \"custom\", \"severity\": \"error\", \"custom_command\": \"sh $DL/hold.sh\" } } }"
# shellcheck disable=SC2016  # script text, expanded when it runs
{
    echo '#!/bin/sh'
    echo "d='$DL'"
    echo ': >"$d/started"'
    # Gives up after two minutes or once the work dir is gone, so a
    # failed test cannot leave it running.
    echo 'n=0'
    echo 'while [ ! -f "$d/release" ] && [ -d "$d" ] && [ $n -lt 1200 ]; do sleep 0.1; n=$((n + 1)); done'
    echo 'exit "${HOLD_RC:-0}"'
} >"$DL/hold.sh"
LOCK="$DL/.specify/gates/.lock"
wait_for() { # <seconds> <test-args...>: poll until the test holds
    local n=0 limit=$(($1 * 10))
    shift
    while ! test "$@"; do
        [[ $n -ge $limit ]] && return 1
        sleep 0.1
        n=$((n + 1))
    done
}
vrun() { # <boundary> [arg...]: verify.sh in the lock fixture
    local b="$1"
    shift
    CLAUDE_PROJECT_DIR="$DL" bash "$DL/.specify/gates/verify.sh" --boundary "$b" "$@"
}
start_holder() { # <boundary>: sets HOLDER, returns once its step runs
    rm -f "$DL/started" "$DL/release"
    # Not through vrun: $! must be verify.sh's own pid.
    CLAUDE_PROJECT_DIR="$DL" bash "$DL/.specify/gates/verify.sh" --boundary "$1" \
        >"$WORKDIR/holder.out" 2>&1 &
    HOLDER=$!
    wait_for 60 -f "$DL/started" || echo "FAIL: the holder's step never started"
}

start_holder git
expect "the holder owns the lock (pid and boundary)" \
    "$(head -n 2 "$LOCK/owner" 2>/dev/null | paste -sd ' ' -)" "$HOLDER git"
rc=0
out="$(vrun agent 2>&1)" || rc=$?
expect "agent boundary under a held lock: exit 0" "$rc" 0
expect "agent boundary: skips naming the holder" \
    "$(grep -c "gates: skipped: the gate run of pid $HOLDER (git) is in progress" <<<"$out")" 1
expect "agent boundary: no gate ran" "$(grep -c '^gates: boundary=' <<<"$out" || true)" 0
out="$(vrun agent --json 2>/dev/null)" || true
expect "agent boundary --json: one skipped object" \
    "$(jq -r '"\(.result) \(.boundary)"' <<<"$out" 2>/dev/null)" "skipped agent"
rc=0
out="$(vrun git --dry-run 2>&1)" || rc=$?
expect "--dry-run takes no lock and does not wait" \
    "$rc:$(grep -c 'waiting for' <<<"$out" || true)" "0:0"
rc=0
out="$(GATES_LOCK_WAIT_S=1 vrun ci 2>&1)" || rc=$?
expect "ci boundary: gives up after GATES_LOCK_WAIT_S (exit 1)" "$rc" 1
expect "ci boundary: the refusal names the holder" \
    "$(grep -c "the gate run of pid $HOLDER (git) still holds" <<<"$out")" 1
GATES_LOCK_WAIT_S=120 CLAUDE_PROJECT_DIR="$DL" bash "$DL/.specify/gates/verify.sh" \
    --boundary git >"$WORKDIR/waiter.out" 2>&1 &
WAITER=$!
wait_for 60 -s "$WORKDIR/waiter.out" || true
sleep 3 # a few polls, each of which could repeat the message
expect "git boundary: says once whom it waits for" \
    "$(grep -c "^gates: waiting for the gate run of pid $HOLDER (git)$" "$WORKDIR/waiter.out")" 1
: >"$DL/release"
rc=0
wait "$HOLDER" || rc=$?
expect "the holder passes" "$rc" 0
rc=0
wait "$WAITER" || rc=$?
expect "git boundary: runs once the holder ends, and passes" "$rc" 0
expect "the waiter ran its gates" "$(grep -c '^  \[pass\] custom' "$WORKDIR/waiter.out")" 1
expect "the lock is gone after both runs" "$([[ -e "$LOCK" ]] && echo held || echo free)" free

rc=0
HOLD_RC=1 vrun git >/dev/null 2>&1 || rc=$?
expect "a failing run exits 2" "$rc" 2
expect "the lock is gone after a failing run" "$([[ -e "$LOCK" ]] && echo held || echo free)" free

start_holder git
kill -TERM "$HOLDER"
# The shell runs the trap once the foreground step ends, as after Ctrl-C.
: >"$DL/release"
rc=0
wait "$HOLDER" || rc=$?
expect "an interrupted run exits 143" "$rc" 143
expect "the lock is gone after an interrupted run" "$([[ -e "$LOCK" ]] && echo held || echo free)" free

# A run whose lock another run took over (it judged this one stale) must
# leave the new holder's lock in place when it exits.
sleep 120 &
OTHER=$!
start_holder git
printf '%s\nci\n\n' "$OTHER" >"$LOCK/owner"
: >"$DL/release"
wait "$HOLDER" || true
expect "a run leaves a lock it no longer owns in place" \
    "$(head -n 1 "$LOCK/owner" 2>/dev/null || echo none)" "$OTHER"
kill "$OTHER" 2>/dev/null || true
wait "$OTHER" 2>/dev/null || true
rm -rf "$LOCK"

sh -c 'exit 0' &
DEAD=$!
wait "$DEAD" || true
mkdir -p "$LOCK"
printf '%s\nci\n\n' "$DEAD" >"$LOCK/owner"
rc=0
out="$(GATES_LOCK_WAIT_S=5 vrun git 2>&1)" || rc=$?
expect "a stale lock is taken over: the run passes" "$rc" 0
expect "the takeover is noted" \
    "$(grep -c "taking over the stale gate lock of pid $DEAD (ci)" <<<"$out")" 1
expect "the lock is gone after the run that took it over" \
    "$([[ -e "$LOCK" ]] && echo held || echo free)" free

# A run started from inside the holder (an accept block, a hook it runs)
# must not wait on its own parent.
DN="$WORKDIR/lock-nested"
project "$DN" "{ \"hooks\": { \"verify-quality\": { \"orchestrator\": \"custom\", \"severity\": \"error\", \"custom_command\": \"sh $DN/nest.sh\" } } }"
# shellcheck disable=SC2016  # script text, expanded when it runs
{
    echo '#!/bin/sh'
    echo '[ -n "$INNER" ] && exit 0'
    echo "INNER=1 CLAUDE_PROJECT_DIR='$DN' bash '$DN/.specify/gates/verify.sh' --boundary git"
} >"$DN/nest.sh"
rc=0
out="$(GATES_LOCK_WAIT_S=2 CLAUDE_PROJECT_DIR="$DN" bash "$DN/.specify/gates/verify.sh" --boundary git 2>&1)" || rc=$?
expect "a nested run does not wait on its parent's lock" \
    "$rc:$(grep -c 'waiting for' <<<"$out" || true)" "0:0"
expect "the nested run leaves the parent's lock to the parent" \
    "$([[ -e "$DN/.specify/gates/.lock" ]] && echo held || echo free)" free

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
refused spec-snapshot-exclude "{ \"hooks\": { $VQ }, \"spec\": { \"snapshot_exclude\": \"cache/**\" } }" 'spec: snapshot_exclude must be an array of strings'
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
usage_err "a repeated --boundary" '--boundary given more than once' --boundary ci --boundary agent
usage_err "--accept without a value" '--accept needs a feature name or all' --boundary ci --accept
usage_err "--accept with an empty value" '--accept needs a feature name or all' --boundary ci --accept ""
ATT_BEFORE="$(cat "$DE/.specify/gates/attestations.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
# No --boundary warns and runs as 0.3.6 did (#216): every gate, boundary
# "unspecified", the gates' exit code; stdout stays one JSON object.
rc=0
NB_OUT="$(CLAUDE_PROJECT_DIR="$DE" bash "$DE/.specify/gates/verify.sh" --json 2>"$WORKDIR/nb.err")" || rc=$?
expect "no --boundary: runs the gates (exit 0)" "$rc" 0
expect "no --boundary: stdout is one JSON object" \
    "$(printf '%s\n' "$NB_OUT" | wc -l | tr -d ' '):$(jq -e . <<<"$NB_OUT" >/dev/null 2>&1 && echo json)" "1:json"
expect "no --boundary: result object says unspecified, with gates" \
    "$(jq -r '"\(.boundary) \(has("result")) \(.gates | length > 0)"' <<<"$NB_OUT")" "unspecified false true"
expect "no --boundary: one stderr deprecation warning naming the fix" \
    "$(grep -c 'without --boundary is deprecated.*Pass --boundary agent|git|ci' "$WORKDIR/nb.err")" 1
expect "no --boundary: no usage line" "$(grep -c 'usage: verify.sh' "$WORKDIR/nb.err")" 0
expect "no --boundary: the attestation records unspecified" \
    "$(($(wc -l <"$DE/.specify/gates/attestations.jsonl" | tr -d ' ') - ATT_BEFORE)):$(tail -n 1 "$DE/.specify/gates/attestations.jsonl" | jq -r .boundary)" "1:unspecified"
rc=0
NB_TEXT="$(CLAUDE_PROJECT_DIR="$DE" bash "$DE/.specify/gates/verify.sh" 2>&1)" || rc=$?
expect "no arguments: runs the gates (exit 0)" "$rc" 0
expect "no arguments: text report says boundary=unspecified" \
    "$(grep -c '^gates: boundary=unspecified ' <<<"$NB_TEXT")" 1
# A failing gate still fails the unspecified run.
rc=0
CLAUDE_PROJECT_DIR="$DF" bash "$DF/.specify/gates/verify.sh" >/dev/null 2>&1 || rc=$?
expect "no --boundary: a failing gate exits 2" "$rc" 2
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

# --- --json refusals print one JSON object (#172) ---
# A workflow step parsing --json output must get an object even when no
# gate ran; the stderr message and exit 1 stay.
echo ""
echo "=== --json refusals ==="
# <name> <needle-in-reason> <env-and-args...>: stdout is one refusal object.
json_refused() {
    local name="$1" needle="$2" out err rc=0
    shift 2
    out="$(env "$@" 2>"$WORKDIR/json-err")" || rc=$?
    err="$(cat "$WORKDIR/json-err")"
    expect "$name: exit 1" "$rc" 1
    expect "$name: one line on stdout" "$(grep -c '' <<<"$out")" 1
    expect "$name: result refused" "$(jq -r '.result' <<<"$out" 2>/dev/null)" refused
    expect "$name: reason names the cause" \
        "$(jq -r '.reason' <<<"$out" 2>/dev/null | grep -qF -- "$needle" && echo yes || echo no)" yes
    expect "$name: stderr keeps the message" "$(grep -qF -- "$needle" <<<"$err" && echo yes || echo no)" yes
}
V="$DE/.specify/gates/verify.sh"
json_refused "bad --boundary" 'invalid value: foo' CLAUDE_PROJECT_DIR="$DE" bash "$V" --boundary foo --json
json_refused "--json before a bad --boundary" 'invalid value: foo' CLAUDE_PROJECT_DIR="$DE" bash "$V" --json --boundary foo
json_refused "unknown argument" 'unknown argument: --nope' CLAUDE_PROJECT_DIR="$DE" bash "$V" --json --nope
json_refused "no git" 'git not found' CLAUDE_PROJECT_DIR="$DE" PATH="$NOGIT" bash "$V" --boundary ci --json
NOJQ="$WORKDIR/path-nojq"
mkdir -p "$NOJQ"
for t in bash sh git cat grep sed awk head tail tr wc dirname basename mktemp rm cp env sort uniq cut date find; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$NOJQ/$t"
done
json_refused "no jq" 'jq not found' CLAUDE_PROJECT_DIR="$DE" PATH="$NOJQ" bash "$V" --boundary ci --json
json_refused "no policy" 'no policy at' CLAUDE_PROJECT_DIR="$WORKDIR/no-such-project" bash "$V" --boundary ci --json
json_refused "invalid policy" 'invalid policy, no gate ran' \
    CLAUDE_PROJECT_DIR="$WORKDIR/inv-malformed" bash "$WORKDIR/inv-malformed/.specify/gates/verify.sh" --boundary git --json
expect "invalid policy: the refusal carries the boundary" \
    "$(CLAUDE_PROJECT_DIR="$WORKDIR/inv-malformed" bash "$WORKDIR/inv-malformed/.specify/gates/verify.sh" --boundary git --json 2>/dev/null | jq -r '.boundary')" git
expect "a quote in the reason stays valid JSON" \
    "$(CLAUDE_PROJECT_DIR="$DE" bash "$V" --json --boundary 'a"b' 2>/dev/null | jq -r '.reason' | grep -c 'a"b')" 1

# --- project gates (feature 006): hooks.verify-quality.gates ---
echo ""
echo "=== project gates ==="
# pg_run <dir> [verify args...]: text report and stderr, exit code last
pg_run() {
    local d="$1" rc=0 out
    shift
    out="$(CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" "$@" 2>&1)" || rc=$?
    printf '%s\nEXIT=%s\n' "$out" "$rc"
}
# pg_lines <dir> [verify args...]: the report's gate lines, " | "-joined
pg_lines() {
    pg_run "$@" | grep '^  \[' | sed 's/^  //' | paste -sd '|' - | sed 's/|/ | /g'
}
pg_att() { # <dir> <jq filter on the last attestation record>
    tail -n 1 "$1/.specify/gates/attestations.jsonl" | jq -c "$2"
}
expect_has() { # <name> <haystack> <needle>
    TOTAL=$((TOTAL + 1))
    if grep -qF -- "$3" <<<"$2"; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (no \"$3\" in: $2)"
        FAIL=$((FAIL + 1))
    fi
}

if have_node_linters; then
    PG="$WORKDIR/pg-walk"
    project "$PG" '{ "hooks": { "prettier": { "include": ["**/*.md"], "severity": "error" },
        "verify-quality": { "orchestrator": "none", "severity": "error",
            "gates": { "zz-first": { "command": "echo first-ran" }, "aa-second": { "command": "true" } } } } }'
    printf '# Ok\n' >"$PG/ok.md"
    expect "two project gates follow the built-in walk, in key order" \
        "$(pg_lines "$PG" --boundary ci)" \
        "[pass] prettier | [pass] zz-first | [pass] aa-second | [pass] spec | [pass] parity"
    expect "--json: one entry per project gate, same order" \
        "$(CLAUDE_PROJECT_DIR="$PG" bash "$PG/.specify/gates/verify.sh" --boundary ci --json 2>/dev/null \
            | jq -c '[.gates[] | [.name, .status]]')" \
        '[["prettier","pass"],["zz-first","pass"],["aa-second","pass"],["spec","pass"],["parity","pass"]]'
    expect "the attestation has an entry per project gate" \
        "$(pg_att "$PG" '[.gates[].name]')" '["prettier","zz-first","aa-second","spec","parity"]'
else
    skip "project gates after the built-in walk" "run npm ci to install pinned linters"
fi

PG="$WORKDIR/pg-sev"
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error",
    "gates": { "hard": { "command": "echo noise; echo \"##gates-fail## hard gate failed\"; echo tail; exit 3" },
               "soft": { "command": "echo soft-last-line; exit 1", "severity": "warning" },
               "note": { "command": "exit 1", "severity": "info" } } } } }'
OUT="$(pg_run "$PG" --boundary ci)"
expect_has "an error gate fails the run (exit 2)" "$OUT" "EXIT=2"
expect_has "##gates-fail## sets the summary" "$OUT" "  [fail] hard -- hard gate failed"
expect_has "a warning gate warns, with its last line as summary" "$OUT" "  [warn] soft -- soft-last-line"
expect_has "an info gate warns" "$OUT" "  [warn] note"
expect_has "the counts include project gates" "$OUT" "failed=1 warnings=2"
expect "attestation: results and fixed reasons" \
    "$(pg_att "$PG" '[.gates[] | select(.name == "hard" or .name == "soft") | [.result, .reason]]')" \
    '[["fail","check failed"],["warn","check failed (warning)"]]'
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error",
    "gates": { "soft": { "command": "exit 1", "severity": "warning" } } } } }'
expect_has "warnings alone pass (exit 0)" "$(pg_run "$PG" --boundary ci)" "EXIT=0"

PG="$WORKDIR/pg-timeout"
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error",
    "gates": { "slow": { "command": "echo SLOW-OUTPUT; sleep 30", "timeout_s": 2, "severity": "warning" } } } } }'
T0="$(date +%s)"
OUT="$(pg_run "$PG" --boundary ci)"
T1="$(date +%s)"
expect_has "a timed-out gate fails, whatever its severity (exit 2)" "$OUT" "EXIT=2"
expect_has "the summary names the limit" "$OUT" "  [fail] slow -- timeout after 2s"
TOTAL=$((TOTAL + 1))
if [[ $((T1 - T0)) -le 6 ]]; then
    echo "PASS: a 2 s limit on sleep 30 ends the run within 6 s"
    PASS=$((PASS + 1))
else
    echo "FAIL: the timed-out run took $((T1 - T0))s"
    FAIL=$((FAIL + 1))
fi
# The policy-wide default applies to a gate without timeout_s.
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error", "gate_timeout_s": 1,
    "gates": { "slow": { "command": "sleep 30" } } } } }'
expect_has "gate_timeout_s is the default limit" "$(pg_run "$PG" --boundary ci)" "  [fail] slow -- timeout after 1s"

PG="$WORKDIR/pg-missing"
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error",
    "gates": { "gone": { "command": "no-such-command-243", "severity": "warning" },
               "noexec": { "command": "./not-executable.sh" } } } } }'
printf '#!/bin/sh\nexit 0\n' >"$PG/not-executable.sh"
chmod 644 "$PG/not-executable.sh"
OUT="$(pg_run "$PG" --boundary ci)"
expect_has "a missing command fails, whatever its severity (exit 2)" "$OUT" "EXIT=2"
expect_has "the summary is the shell's message" "$OUT" "no-such-command-243"
expect "attestation: command not found or not executable (127 and 126)" \
    "$(pg_att "$PG" '[.gates[] | select(.name == "gone" or .name == "noexec") | [.result, .reason]]')" \
    '[["fail","command not found or not executable"],["fail","command not found or not executable"]]'

PG="$WORKDIR/pg-env"
# shellcheck disable=SC2016  # expanded by the gate commands
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error",
    "custom_command": "echo \"##gates-fail## custom-boundary=$GATES_BOUNDARY\"; exit 1",
    "gates": { "env": { "command": "echo \"##gates-fail## boundary=$GATES_BOUNDARY cwd=$(pwd -P)\"; exit 1" } } } } }'
PGP="$(cd "$PG" && pwd -P)"
for b in agent git ci; do
    OUT="$(cd "$WORKDIR" && pg_run "$PG" --boundary "$b")"
    expect_has "GATES_BOUNDARY=$b reaches the gate command, run from the project root" \
        "$OUT" "  [fail] env -- boundary=$b cwd=$PGP"
done
OUT="$(cd "$WORKDIR" && pg_run "$PG")"
expect_has "without --boundary GATES_BOUNDARY is none" "$OUT" "  [fail] env -- boundary=none"
expect_has "the custom step sees GATES_BOUNDARY too" "$OUT" "  [fail] custom -- custom-boundary=none"
expect "the custom orchestrator and project gates both run" \
    "$(pg_lines "$PG" --boundary ci | sed 's/ -- [^|]* |/ |/g; s/ -- [^|]*$//')" "[fail] custom | [fail] env | [pass] spec | [pass] parity"

# A gate's own ##gates-meta## line claims nothing: tool fields stay null.
PG="$WORKDIR/pg-meta"
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error",
    "gates": { "spoof": { "command": "echo \"##gates-meta## binname=prettier candidates=9 checked=0 skipped=prettier bin=/x\"; exit 1" } } } } }'
OUT="$(pg_run "$PG" --boundary ci)"
expect_has "a spoofed meta line cannot turn a failure into a skip" "$OUT" "  [fail] spoof"
expect "project gates attest null tool fields" \
    "$(pg_att "$PG" '.gates[] | select(.name == "spoof") | [.bin, .version, .pinned, .candidates, .checked, .result]')" \
    '[null,null,null,null,null,"fail"]'

PG="$WORKDIR/pg-dry"
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error", "gate_timeout_s": 900,
    "gates": { "a": { "command": "touch ran-a" }, "b": { "command": "touch ran-b", "timeout_s": 5 } } } } }'
expect "--dry-run plans each project gate with its command and limit, runs none" \
    "$(CLAUDE_PROJECT_DIR="$PG" bash "$PG/.specify/gates/verify.sh" --boundary ci --dry-run --json 2>/dev/null \
        | jq -c '[.gates[] | select(.name == "a" or .name == "b") | [.status, .detail]]'):$(find "$PG" -maxdepth 1 -name 'ran-*' | wc -l | tr -d ' ')" \
    '[["planned","touch ran-a (time limit 900s)"],["planned","touch ran-b (time limit 5s)"]]:0'

# A policy without gates: the same gates, results and report as before.
PG="$WORKDIR/pg-none"
project "$PG" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } } }'
expect "no gates key: the report is unchanged" \
    "$(pg_run "$PG" --boundary ci)" "$(printf 'gates: boundary=ci failed=0 warnings=0\n  [pass] custom\n  [pass] spec\n  [pass] parity\nEXIT=0')"
expect "no gates key: the attestation lists the same gates" \
    "$(pg_att "$PG" '[.gates[].name]')" '["custom","spec","parity"]'

# --- lib/watch.sh: gates_run_watched (feature 006) ---
echo ""
echo "=== gates_run_watched ==="
# watched <timeout> <outfile> <cmd...>: "<rc>|<GATES_WATCH_DETAIL>|<seconds>"
watched() {
    (
        # shellcheck source=../extension/runtime/lib/watch.sh disable=SC1091
        source "$REPO_ROOT/extension/runtime/lib/watch.sh"
        local t0 rc=0
        t0="$(date +%s)"
        gates_run_watched "$@" || rc=$?
        printf '%s|%s|%s\n' "$rc" "$GATES_WATCH_DETAIL" "$(($(date +%s) - t0))"
    )
}
WO="$WORKDIR/watched.out"
expect "a passing command returns 0" "$(watched 10 "$WO" true | cut -d'|' -f1,2)" "0|"
expect "a failing command returns its status" "$(watched 10 "$WO" sh -c 'exit 3' | cut -d'|' -f1,2)" "3|"
watched 10 "$WO" sh -c 'echo to-stdout; echo to-stderr >&2' >/dev/null
expect "stdout and stderr go to the file" "$(tr '\n' ' ' <"$WO")" "to-stdout to-stderr "
expect "stdin is /dev/null" "$(echo piped | watched 10 "$WO" cat >/dev/null; wc -c <"$WO" | tr -d ' ')" 0
expect "a command exiting 124 by itself is not a timeout" "$(watched 10 "$WO" sh -c 'exit 124' | cut -d'|' -f1,2)" "124|"
W="$(watched 2 "$WO" sleep 30)"
expect "sleep 30 under a 2 s limit returns 124" "${W%%|*}" 124
expect_detail="$(cut -d'|' -f2 <<<"$W")"
TOTAL=$((TOTAL + 1))
if [[ "$expect_detail" == "timeout after 2s" || "$expect_detail" == "timeout after 2s at load "* ]]; then
    echo "PASS: the timeout detail names the limit (and the load)"
    PASS=$((PASS + 1))
else
    echo "FAIL: timeout detail: $expect_detail"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if [[ "${W##*|}" -le 6 ]]; then
    echo "PASS: the timeout fires within 6 s"
    PASS=$((PASS + 1))
else
    echo "FAIL: the timeout took ${W##*|}s"
    FAIL=$((FAIL + 1))
fi
# The command and a child it started: both are in the stopped group.
PIDF="$WORKDIR/watched.pids"
watched 2 "$WO" sh -c "echo \$\$ >'$PIDF'; sleep 31 & echo \$! >>'$PIDF'; wait" >/dev/null
alive=0
while IFS= read -r p; do
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && alive=$((alive + 1))
done <"$PIDF"
expect "no process of the stopped group keeps running" "$(wc -l <"$PIDF" | tr -d ' '):$alive" "2:0"
# A quick command under a long limit: the timer is stopped with it, so a
# caller capturing the run's output does not wait for the limit.
W="$(watched 20 "$WO" true)"
TOTAL=$((TOTAL + 1))
if [[ "${W##*|}" -le 3 ]]; then
    echo "PASS: a quick command does not wait for its limit"
    PASS=$((PASS + 1))
else
    echo "FAIL: a quick command under a 20 s limit took ${W##*|}s"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "$PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
