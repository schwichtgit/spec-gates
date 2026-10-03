#!/bin/bash
set -euo pipefail

# lib/policy-infer.sh and lib/taskfile-detect.sh (#98): the policy seed that
# init proposes, inferred from the repo's own lint configs and Taskfile.
# Both ran in no test before (0% line coverage).

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/extension/runtime/lib"
INFER="$LIB/policy-infer.sh"
DETECT="$LIB/taskfile-detect.sh"
TEMPLATE="$REPO_ROOT/extension/runtime/policy-template.json"

PASS=0
FAIL=0
TOTAL=0
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

W="$(mktemp -d 2>/dev/null || mktemp -d -t gates-infer-test)"
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || rm -rf "$W"' EXIT

# Run the CLI the way init does: bash <lib>/policy-infer.sh <dir> <out>.
infer() { # <project-dir> <out> -> exit code; stderr in $W/err
    local rc=0
    bash "$INFER" "$1" "$2" 2>"$W/err" || rc=$?
    echo "$rc"
}
# A PATH without yq, so the Taskfile check takes its grep path.
NOYQ="$W/noyq"
mkdir -p "$NOYQ"
for t in bash jq awk grep sed cat mktemp mv mkdir rm dirname basename tr head tail cut sort; do
    p="$(type -P "$t" 2>/dev/null)" && ln -s "$p" "$NOYQ/$t"
done

echo "=== usage errors ==="
eq "no arguments -> 2" 2 "$(infer "" "")"
eq "missing project directory -> 2" 2 "$(infer "$W/nope" "$W/out.json")"

echo ""
echo "=== nothing to infer: bundled defaults ==="
P="$W/plain"
mkdir -p "$P"
eq "plain project -> 0" 0 "$(infer "$P" "$P/.specify/gates/policy.json")"
eq "output written (parent created)" yes "$([[ -f "$P/.specify/gates/policy.json" ]] && echo yes || echo no)"
eq "prettier.exclude from the template" "$(jq -c '.hooks.prettier.exclude' "$TEMPLATE")" \
    "$(jq -c '.hooks.prettier.exclude' "$P/.specify/gates/policy.json")"
eq "shellcheck.exclude from the template" "$(jq -c '.hooks.shellcheck.exclude' "$TEMPLATE")" \
    "$(jq -c '.hooks.shellcheck.exclude' "$P/.specify/gates/policy.json")"
eq "no Taskfile -> orchestrator none" none "$(jq -r '.hooks["verify-quality"].orchestrator' "$P/.specify/gates/policy.json")"
eq "the summary names the defaults" 3 "$(grep -c '<- bundled defaults' "$W/err")"
eq "the result validates" 0 "$(bash -c "source '$LIB/policy.sh'; gates_validate_policy '$P/.specify/gates/policy.json' >/dev/null 2>&1; echo \$?")"

echo ""
echo "=== excludes inferred from the repo's lint configs ==="
R="$W/configured"
mkdir -p "$R/.specify/gates"
printf '# generated\n\ndist/\n  \nbuild/**   \n*.min.js\n' >"$R/.prettierignore"
cat >"$R/.markdownlint-cli2.yaml" <<'YAML'
config:
  default: true
ignores:
  - 'node_modules/**'
  - 'docs/it''s/**'
  - "unquoted-is-ignored"
globs:
  - '**/*.md'
YAML
printf 'vendor/**\n\nscripts/legacy.sh  \n' >"$R/.specify/gates/shellcheck-excludes.txt"
eq "configured project -> 0" 0 "$(infer "$R" "$W/configured.json")"
eq "prettier: comments, blanks and trailing space dropped" '["dist/","build/**","*.min.js"]' \
    "$(jq -c '.hooks.prettier.exclude' "$W/configured.json")"
eq "markdownlint: quoted ignores only, doubled quote unescaped, stops at the next key" \
    "[\"node_modules/**\",\"docs/it's/**\"]" "$(jq -c '.hooks.markdownlint.exclude' "$W/configured.json")"
eq "shellcheck: one entry per line" '["vendor/**","scripts/legacy.sh"]' \
    "$(jq -c '.hooks.shellcheck.exclude' "$W/configured.json")"
eq "includes stay at the template" "$(jq -c '.hooks.prettier.include' "$TEMPLATE")" \
    "$(jq -c '.hooks.prettier.include' "$W/configured.json")"
eq "the summary names each source" 3 "$(grep -c "<- $R/" "$W/err")"

echo ""
echo "=== Taskfile detection (grep path, no yq) ==="
T="$W/task"
mkdir -p "$T"
detect() { # <dir> -> exit code of the CLI without yq
    local rc=0
    PATH="$NOYQ" bash "$DETECT" has-lint-test "$1" 2>/dev/null || rc=$?
    echo "$rc"
}
printf 'version: "3"\ntasks:\n  lint:\n    cmds: [npm run lint]\n  test:   # unit\n    cmds: [npm test]\n' >"$T/Taskfile.yml"
eq "lint and test targets -> 0" 0 "$(detect "$T")"
P2="$W/task-infer"
mkdir -p "$P2"
cp "$T/Taskfile.yml" "$P2/"
rc=0
PATH="$NOYQ" bash "$INFER" "$P2" "$W/task.json" 2>"$W/err" || rc=$?
eq "infer with lint+test -> 0" 0 "$rc"
eq "infer seeds orchestrator task" task "$(jq -r '.hooks["verify-quality"].orchestrator' "$W/task.json")"
eq "the summary says the targets are present" 1 "$(grep -c 'taskfile lint+test: present' "$W/err")"
printf 'version: "3"\ntasks:\n  lint:\n    cmds: [x]\n' >"$T/Taskfile.yml"
eq "lint only -> 1" 1 "$(detect "$T")"
printf 'version: "3"\ntasks:\n  ci:\n    lint:\n      cmds: [x]\n    test:\n      cmds: [x]\n' >"$T/Taskfile.yml"
eq "nested lint/test do not count -> 1" 1 "$(detect "$T")"
printf 'version: "3"\ntasks:\n  test:\n    cmds: [x]\n  ci:\n    lint:\n      cmds: [x]\n' >"$T/Taskfile.yml"
eq "a nested lint beside a top-level test does not count -> 1" 1 "$(detect "$T")"
printf 'version: "3"\nlint:\n  cmds: [x]\ntest:\n  cmds: [x]\n' >"$T/Taskfile.yml"
eq "no tasks: block -> 1" 1 "$(detect "$T")"
rm -f "$T/Taskfile.yml"
printf 'tasks:\n  lint:\n    cmds: [x]\n  test:\n    cmds: [x]\n' >"$T/Taskfile.yaml"
eq "Taskfile.yaml is read too -> 0" 0 "$(detect "$T")"
rm -f "$T/Taskfile.yaml"
eq "no Taskfile -> 1" 1 "$(detect "$T")"
eq "no directory argument -> 1" 1 "$(detect "")"
rc=0
bash "$DETECT" 2>/dev/null || rc=$?
eq "no subcommand -> usage, 2" 2 "$rc"

echo ""
echo "=== Taskfile detection (yq path) ==="
# A stand-in yq that answers like the real one: the key's value, or "null".
YQ="$W/yq"
mkdir -p "$YQ"
cat >"$YQ/yq" <<'SH'
#!/bin/bash
key="${2#.tasks.}"; key="${key%% *}"
if grep -qE "^  ${key}:" "$3"; then echo "{}"; else echo null; fi
SH
chmod +x "$YQ/yq"
printf 'tasks:\n  lint:\n    cmds: [x]\n  test:\n    cmds: [x]\n' >"$T/Taskfile.yml"
rc=0
PATH="$YQ:$NOYQ" bash "$DETECT" has-lint-test "$T" || rc=$?
eq "yq: both targets -> 0" 0 "$rc"
printf 'tasks:\n  lint:\n    cmds: [x]\n' >"$T/Taskfile.yml"
rc=0
PATH="$YQ:$NOYQ" bash "$DETECT" has-lint-test "$T" || rc=$?
eq "yq: one target -> 1" 1 "$rc"

echo ""
echo "=== template and validation failures ==="
# The CLI resolves the template next to the runtime; a copy of lib/ without
# it has nothing to start from.
mkdir -p "$W/bare/lib"
cp "$LIB/policy-infer.sh" "$LIB/policy.sh" "$LIB/taskfile-detect.sh" "$W/bare/lib/"
rc=0
bash "$W/bare/lib/policy-infer.sh" "$P" "$W/bare.json" 2>/dev/null || rc=$?
eq "no bundled template -> 3" 3 "$rc"
eq "nothing written without a template" no "$([[ -e "$W/bare.json" ]] && echo yes || echo no)"
jq '.hooks.prettier.severity = "loud"' "$TEMPLATE" >"$W/bad-template.json"
rc=0
GATES_INFER_DEFAULT_POLICY="$W/bad-template.json" bash "$INFER" "$P" "$W/bad.json" 2>/dev/null || rc=$?
eq "a result that fails validation -> 4" 4 "$rc"
eq "nothing written when validation fails" no "$([[ -e "$W/bad.json" ]] && echo yes || echo no)"
jq '.hooks.prettier.include = ["only/**"]' "$TEMPLATE" >"$W/alt-template.json"
GATES_INFER_DEFAULT_POLICY="$W/alt-template.json" bash "$INFER" "$P" "$W/alt.json" 2>/dev/null
eq "GATES_INFER_DEFAULT_POLICY overrides the template" '["only/**"]' "$(jq -c '.hooks.prettier.include' "$W/alt.json")"

echo ""
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -eq 0 ]]
