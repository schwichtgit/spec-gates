#!/bin/bash
set -euo pipefail

# Constitution-as-contract tests (feature 004): the deterministic pipeline
# behind the guided session -- fragments, draft, detect (US1), alignment
# (US2), check (US3), and Core Principles scoping (#82).
#
# Regression guards for the spec's success criteria:
#   SC-001 -- a guided session yields a byte-deterministic annotated draft
#             with one marker per principle and zero bracket placeholders;
#   FR-004 -- a selection without a surface decision cannot materialize;
#   FR-010 -- augment preserves every existing line and annotates in place;
#   FR-014 -- detect classifies absent/placeholder/filled.
# All fixtures are local files -- no network anywhere.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORPUS="$REPO_ROOT/extension/constitution"
CONST="$REPO_ROOT/extension/runtime/constitution.sh"
TEMPLATE_SIG='# [PROJECT_NAME] Constitution'

PASS=0
FAIL=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-const-test)"
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

expect_contains() { # <name> <haystack> <needle>
    TOTAL=$((TOTAL + 1))
    if printf '%s' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (output does not contain: $3)"
        FAIL=$((FAIL + 1))
    fi
}

expect_absent() { # <name> <haystack> <needle>
    TOTAL=$((TOTAL + 1))
    if printf '%s' "$2" | grep -qF "$3"; then
        echo "FAIL: $1 (output unexpectedly contains: $3)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $1"
        PASS=$((PASS + 1))
    fi
}

# Assert the parse output has a PRINCIPLE with the given name and surface.
expect_parse() { # <name> <parse-output> <principle> <surface>
    TOTAL=$((TOTAL + 1))
    if printf '%s' "$2" | awk -F'\t' -v p="$3" -v s="$4" \
        '$1 == "PRINCIPLE" && $3 == p && $4 == s { f = 1 } END { exit !f }'; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (no PRINCIPLE '$3' with surface '$4')"
        FAIL=$((FAIL + 1))
    fi
}

run_const() { CLAUDE_PROJECT_DIR="$WORKDIR" bash "$CONST" "$@"; }

# --- fragments: profile filtering + mandatory-first ordering -----------------

printf '{ "project_type": "docs", "postures": ["solo"] }\n' >"$WORKDIR/prof-docs.json"
printf '{ "project_type": "service", "postures": ["security-hardened","team"] }\n' >"$WORKDIR/prof-svc.json"

docs_menu="$(run_const fragments --corpus "$CORPUS" --profile "$WORKDIR/prof-docs.json")"
expect "fragments: docs profile sees no infra fragments" \
    "$(printf '%s' "$docs_menu" | grep -c 'least-privilege\|platform-agnostic' || true)" "0"
expect "fragments: mandatory tier is first line" \
    "$(printf '%s' "$docs_menu" | head -n1 | cut -f1)" "mandatory"
expect_contains "fragments: mandatory no-secrets present" "$docs_menu" "security/no-secrets"

svc_menu="$(run_const fragments --corpus "$CORPUS" --profile "$WORKDIR/prof-svc.json")"
expect_contains "fragments: service profile sees a service fragment" "$svc_menu" "hardened-runtime-image"
expect_absent "fragments: service profile still excludes infra" "$svc_menu" "least-privilege"

TOTAL=$((TOTAL + 1))
if run_const fragments --corpus "$CORPUS" >/dev/null 2>&1; then
    echo "FAIL: fragments without --profile should be a usage error"
    FAIL=$((FAIL + 1))
else
    echo "PASS: fragments without --profile is a usage error"
    PASS=$((PASS + 1))
fi

# --- draft: determinism, markers, zero placeholders --------------------------

cat >"$WORKDIR/sel.json" <<'EOF'
{
  "project_name": "Acme Service",
  "selections": [
    { "id": "security/no-secrets", "surface": "scanner", "ref": "gitleaks:default" },
    { "id": "workflow/branch-first", "surface": "git-hook", "ref": "pre-commit" },
    { "id": "quality/lockfile-committed", "surface": "policy", "ref": "attestation.parity", "expect": "error" },
    { "id": "architecture/single-chokepoint", "surface": "prose" },
    { "name": "Custom Rule", "surface": "prose", "body": "A custom principle authored in the session." }
  ]
}
EOF

run_const draft --corpus "$CORPUS" --selections "$WORKDIR/sel.json" --out "$WORKDIR/d1.md"
run_const draft --corpus "$CORPUS" --selections "$WORKDIR/sel.json" --out "$WORKDIR/d2.md"
TOTAL=$((TOTAL + 1))
if cmp -s "$WORKDIR/d1.md" "$WORKDIR/d2.md"; then
    echo "PASS: draft is byte-deterministic"
    PASS=$((PASS + 1))
else
    echo "FAIL: draft is not deterministic"
    FAIL=$((FAIL + 1))
fi

expect "draft: one marker per principle (5 principles, 5 markers)" \
    "$(grep -c '^### ' "$WORKDIR/d1.md")/$(grep -c 'gates:enforce' "$WORKDIR/d1.md")" "5/5"

TOTAL=$((TOTAL + 1))
if grep -Eq '\[[A-Z_][A-Z_][A-Z_]' "$WORKDIR/d1.md"; then
    echo "FAIL: draft contains bracket placeholders"
    FAIL=$((FAIL + 1))
else
    echo "PASS: draft has zero bracket placeholders"
    PASS=$((PASS + 1))
fi

expect_contains "draft: policy surface carries expect=" \
    "$(cat "$WORKDIR/d1.md")" "surface=policy ref=attestation.parity expect=error"
expect_contains "draft: custom principle rendered" "$(cat "$WORKDIR/d1.md")" "### V. Custom Rule"

# --- draft: FR-004, surface obligation (corpus AND custom) -------------------

printf '{ "selections": [ { "id": "workflow/branch-first" } ] }\n' >"$WORKDIR/nosurf.json"
rc=0
run_const draft --corpus "$CORPUS" --selections "$WORKDIR/nosurf.json" --out "$WORKDIR/x.md" 2>/dev/null || rc=$?
expect "corpus selection without a surface is refused (exit 2)" "$rc" "2"

printf '{ "selections": [ { "name": "X", "body": "y" } ] }\n' >"$WORKDIR/nosurf2.json"
rc=0
run_const draft --corpus "$CORPUS" --selections "$WORKDIR/nosurf2.json" --out "$WORKDIR/x.md" 2>/dev/null || rc=$?
expect "custom principle without a surface is refused (exit 2)" "$rc" "2"

# --- draft --augment: preserve every existing line, annotate in place --------

cat >"$WORKDIR/existing.md" <<'EOF'
# Legacy Constitution

## Core Principles

### I. Ship Fast

We value shipping over ceremony.

### II. Be Kind

Respect collaborators.

## Governance

Amendments require review.
EOF

cat >"$WORKDIR/aug.json" <<'EOF'
{
  "selections": [
    { "principle": "I. Ship Fast", "surface": "ci", "ref": "gates" },
    { "principle": "II. Be Kind", "surface": "prose" },
    { "name": "No Secrets", "surface": "scanner", "ref": "gitleaks:default", "body": "Never commit a secret." }
  ]
}
EOF

run_const draft --corpus "$CORPUS" --selections "$WORKDIR/aug.json" \
    --out "$WORKDIR/aug-out.md" --augment "$WORKDIR/existing.md"

# Every original line still present, in order (subsequence check).
missing_line=""
while IFS= read -r line; do
    grep -qxF "$line" "$WORKDIR/aug-out.md" || missing_line="$line"
done <"$WORKDIR/existing.md"
expect "augment: every existing line preserved" "$missing_line" ""

aug_parse="$(CLAUDE_PROJECT_DIR="$WORKDIR" bash -c "source '$REPO_ROOT/extension/runtime/lib/constitution.sh'; gates_const_parse '$WORKDIR/aug-out.md'")"
expect_parse "augment: annotated I in place (ci)" "$aug_parse" "I. Ship Fast" "ci"
expect_parse "augment: annotated II in place (prose)" "$aug_parse" "II. Be Kind" "prose"
expect_parse "augment: appended new principle III" "$aug_parse" "III. No Secrets" "scanner"

# The appended principle lands inside Core Principles, before Governance.
core_line="$(grep -n '^### III' "$WORKDIR/aug-out.md" | cut -d: -f1)"
gov_line="$(grep -n '^## Governance' "$WORKDIR/aug-out.md" | cut -d: -f1)"
TOTAL=$((TOTAL + 1))
if [[ -n "$core_line" && -n "$gov_line" && "$core_line" -lt "$gov_line" ]]; then
    echo "PASS: appended principle sits before Governance"
    PASS=$((PASS + 1))
else
    echo "FAIL: appended principle misplaced (III at $core_line, Governance at $gov_line)"
    FAIL=$((FAIL + 1))
fi

# Re-running augment does not double-annotate an already-annotated principle.
run_const draft --corpus "$CORPUS" --selections "$WORKDIR/aug.json" \
    --out "$WORKDIR/aug-out2.md" --augment "$WORKDIR/aug-out.md"
expect "augment: idempotent (no second marker on I)" \
    "$(grep -c 'surface=ci ref=gates' "$WORKDIR/aug-out2.md")" "1"

# --- detect: absent / placeholder / filled -----------------------------------

mkdir -p "$WORKDIR/.specify/memory" "$WORKDIR/.specify/templates"
printf '%s\n' "$TEMPLATE_SIG" >"$WORKDIR/.specify/templates/constitution-template.md"
expect "detect: absent when no constitution" "$(run_const detect)" "absent"

printf '%s\n\n[PRINCIPLE_1_NAME]\n' "$TEMPLATE_SIG" >"$WORKDIR/.specify/memory/constitution.md"
expect "detect: placeholder on bracket-token signature" "$(run_const detect)" "placeholder"

cp "$WORKDIR/.specify/templates/constitution-template.md" "$WORKDIR/.specify/memory/constitution.md"
expect "detect: placeholder when byte-equal to template" "$(run_const detect)" "placeholder"

cp "$WORKDIR/d1.md" "$WORKDIR/.specify/memory/constitution.md"
expect "detect: filled on a real constitution" "$(run_const detect)" "filled"

# --- align: per-surface activity (US2) ---------------------------------------

# Assert an align row for <principle> reports <state>.
expect_state() { # <name> <align-output> <principle> <state>
    TOTAL=$((TOTAL + 1))
    if printf '%s' "$2" | awk -F'\t' -v p="$3" -v s="$4" \
        '$1 == p && $4 == s { f = 1 } END { exit !f }'; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (principle '$3' not in state '$4')"
        printf '%s\n' "$2" | awk '{ print "    " $0 }'
        FAIL=$((FAIL + 1))
    fi
}

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/hooks/gates" "$PROJ/.github/workflows" \
    "$PROJ/specs/feat-x" "$PROJ/.specify/memory"
git init -q "$PROJ"
git -C "$PROJ" checkout -q -b main 2>/dev/null || true

# policy: a top-level section key and a hooks key, both present.
mkdir -p "$PROJ/.specify/gates"
cat >"$PROJ/.specify/gates/policy.json" <<'EOF'
{
  "git": { "block_main_commits": true },
  "hooks": { "prettier": { "severity": "error" } }
}
EOF

# agent-hook: present, executable, wired.
printf '#!/bin/sh\n' >"$PROJ/.claude/hooks/gates/validate-bash.sh"
chmod +x "$PROJ/.claude/hooks/gates/validate-bash.sh"
printf '{ "hooks": { "PreToolUse": "validate-bash.sh" } }\n' >"$PROJ/.claude/settings.json"

# git-hook: installed, executable, delegates to gates.
printf '#!/bin/sh\nexec bash .specify/gates/verify.sh\n' >"$PROJ/.git/hooks/pre-commit"
chmod +x "$PROJ/.git/hooks/pre-commit"

# ci: a gates workflow (a live verify step) naming the check.
printf 'jobs:\n  mygate:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n' >"$PROJ/.github/workflows/ci.yml"

# accept: a tasks.md with an accept block verifying SC-9.
cat >"$PROJ/specs/feat-x/tasks.md" <<'EOF'
# Tasks

- [x] T001 do the thing

```accept
# verifies: SC-9
true
```
EOF

# scanner: a checkov config mentioning the rule.
printf 'skip-check:\n  - CKV_TEST\n' >"$PROJ/.checkov.yml"

# A constitution annotated with one active principle per surface.
cat >"$PROJ/.specify/memory/constitution.md" <<'EOF'
# Proj Constitution

## Core Principles

### I. Policy Section
<!-- gates:enforce surface=policy ref=git.block_main_commits -->
x

### II. Policy Hook Expect
<!-- gates:enforce surface=policy ref=prettier.severity expect=error -->
x

### III. Agent Hook
<!-- gates:enforce surface=agent-hook ref=validate-bash.sh -->
x

### IV. Git Hook
<!-- gates:enforce surface=git-hook ref=pre-commit -->
x

### V. Ci
<!-- gates:enforce surface=ci ref=mygate -->
x

### VI. Accept
<!-- gates:enforce surface=accept ref=feat-x/SC-9 -->
x

### VII. Scanner
<!-- gates:enforce surface=scanner ref=checkov:CKV_TEST -->
x

### VIII. Prose
<!-- gates:enforce surface=prose -->
x
EOF

al="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$CONST" align --constitution "$PROJ/.specify/memory/constitution.md")"
expect_state "align: policy (top-level section) active" "$al" "I. Policy Section" "active"
expect_state "align: policy hook with matching expect active" "$al" "II. Policy Hook Expect" "active"
expect_state "align: agent-hook active" "$al" "III. Agent Hook" "active"
expect_state "align: git-hook active" "$al" "IV. Git Hook" "active"
expect_state "align: ci active" "$al" "V. Ci" "active"
expect_state "align: accept active" "$al" "VI. Accept" "active"
expect_state "align: scanner active" "$al" "VII. Scanner" "active"
expect_state "align: prose reported prose-only" "$al" "VIII. Prose" "prose-only"

# Now break each surface and confirm it flips to missing.
chmod -x "$PROJ/.claude/hooks/gates/validate-bash.sh" # agent-hook not executable
rm "$PROJ/.git/hooks/pre-commit"                      # git-hook removed
printf 'jobs:\n  other:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n' >"$PROJ/.github/workflows/ci.yml" # ci name gone
rm "$PROJ/.checkov.yml"                               # scanner config gone
al2="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$CONST" align --constitution "$PROJ/.specify/memory/constitution.md")"
expect_state "align: non-executable agent-hook missing" "$al2" "III. Agent Hook" "missing"
expect_state "align: removed git-hook missing" "$al2" "IV. Git Hook" "missing"
expect_state "align: ci check absent missing" "$al2" "V. Ci" "missing"
expect_state "align: scanner config absent missing" "$al2" "VII. Scanner" "missing"

# git-hook through the stub (issue #59), and from a linked worktree, whose
# --git-dir is .git/worktrees/<name> while hooks live in the shared dir.
mkdir -p "$PROJ/.specify/gates/hooks"
printf '#!/bin/sh\nexit 0\n' >"$PROJ/.specify/gates/hooks/pre-commit"
cp "$REPO_ROOT/extension/runtime/hooks/git/stub.sh" "$PROJ/.git/hooks/pre-commit"
chmod +x "$PROJ/.git/hooks/pre-commit"
al3="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$CONST" align --constitution "$PROJ/.specify/memory/constitution.md")"
expect_state "align: stub with this branch's hook active" "$al3" "IV. Git Hook" "active"
(
    cd "$PROJ" && git config user.email t@example.com && git config user.name tester \
        && git add -A && git commit -q --no-verify -m "chore: seed" \
        && git worktree add -q -b feat/wt "$WORKDIR/const-wt"
) >/dev/null 2>&1
alw="$(CLAUDE_PROJECT_DIR="$WORKDIR/const-wt" bash "$CONST" align --constitution "$WORKDIR/const-wt/.specify/memory/constitution.md")"
expect_state "align: git-hook active from a linked worktree" "$alw" "IV. Git Hook" "active"
rm "$PROJ/.specify/gates/hooks/pre-commit"
al4="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$CONST" align --constitution "$PROJ/.specify/memory/constitution.md")"
expect_state "align: stub whose branch hook is gone missing" "$al4" "IV. Git Hook" "missing"

# expect mismatch: policy value present but not equal to expect -> missing.
cat >"$PROJ/.specify/memory/const-mismatch.md" <<'EOF'
# C

## Core Principles

### I. Mismatch
<!-- gates:enforce surface=policy ref=prettier.severity expect=warning -->
x
EOF
alm="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$CONST" align --constitution "$PROJ/.specify/memory/const-mismatch.md")"
expect_state "align: policy expect mismatch is missing" "$alm" "I. Mismatch" "missing"

# pending-boundary: a ci surface in a project with no CI configuration at all.
NOCI="$WORKDIR/noci"
mkdir -p "$NOCI/.specify/memory"
cat >"$NOCI/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. Ci Pending
<!-- gates:enforce surface=ci ref=whatever -->
x
EOF
alp="$(CLAUDE_PROJECT_DIR="$NOCI" bash "$CONST" align --constitution "$NOCI/.specify/memory/constitution.md")"
expect_state "align: ci with no CI boundary is pending-boundary" "$alp" "I. Ci Pending" "pending-boundary"

# ci is wired only by a live step (#139): text in a comment, a disabled step,
# or a job name alone does not enforce anything.
CIW="$WORKDIR/ci-wiring"
mkdir -p "$CIW/.specify/memory" "$CIW/.github/workflows"
cat >"$CIW/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. Gates
<!-- gates:enforce surface=ci ref=gates -->
x

### II. Canary
<!-- gates:enforce surface=ci ref=canary -->
x

### III. Custom
<!-- gates:enforce surface=ci ref=lint-job -->
x
EOF
ciw_align() { CLAUDE_PROJECT_DIR="$CIW" bash "$CONST" align --constitution "$CIW/.specify/memory/constitution.md"; }
printf 'jobs:\n  lint-job:\n    steps:\n      # TODO: wire spec-gates here later\n      - run: npm test\n' \
    >"$CIW/.github/workflows/ci.yml"
cw="$(ciw_align)"
expect_state "ci: a comment mentioning gates is not wiring" "$cw" "I. Gates" "missing"
expect_state "ci: a named job without a gates pipeline is not wiring" "$cw" "III. Custom" "missing"
cat >"$CIW/.github/workflows/ci.yml" <<'EOF'
jobs:
  lint-job:
    steps:
      - run: bash .specify/gates/verify.sh --boundary ci
      - name: Canaries
        run: "true"  # disabled: bash .specify/gates/canary.sh
EOF
cw="$(ciw_align)"
expect_state "ci: a live verify step wires ref=gates" "$cw" "I. Gates" "active"
expect_state "ci: a custom ref in a gates pipeline is wired" "$cw" "III. Custom" "active"
expect_state "ci: a command only in a comment is not wiring" "$cw" "II. Canary" "missing"
# shellcheck disable=SC2016  # a literal GitHub expression
printf '      - if: ${{ false }}\n        run: bash .specify/gates/canary.sh\n' >>"$CIW/.github/workflows/ci.yml"
expect_state "ci: an if: false step is not wiring" "$(ciw_align)" "II. Canary" "missing"
printf '      - run: bash .specify/gates/canary.sh\n' >>"$CIW/.github/workflows/ci.yml"
expect_state "ci: a live template step wires its id" "$(ciw_align)" "II. Canary" "active"
printf 'jobs:\n  gates:\n    steps:\n      # - run: bash .specify/gates/verify.sh --boundary ci\n' \
    >"$CIW/.github/workflows/ci.yml"
expect_state "ci: a commented-out verify step is not wiring" "$(ciw_align)" "I. Gates" "missing"
# A template id is its step's command, not the word: a gates pipeline
# whose text happens to contain "pr" does not run pr-check.sh.
sed -i.bak 's/canary/pr/' "$CIW/.specify/memory/constitution.md" && rm -f "$CIW/.specify/memory/constitution.md.bak"
printf 'jobs:\n  pr:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n' \
    >"$CIW/.github/workflows/ci.yml"
expect_state "ci: a template id needs its step, not the word" "$(ciw_align)" "II. Canary" "missing"
# A step that runs but cannot fail, or a job that never runs, wires nothing
# (#171): the ci surface reads the same live text doctor does.
printf 'jobs:\n  gates:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n        continue-on-error: true\n' \
    >"$CIW/.github/workflows/ci.yml"
expect_state "ci: a continue-on-error gates step is missing" "$(ciw_align)" "I. Gates" "missing"
printf 'on: workflow_dispatch\njobs:\n  lint-job:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n' \
    >"$CIW/.github/workflows/ci.yml"
expect_state "ci: a dispatch-only workflow wires no gates step" "$(ciw_align)" "I. Gates" "missing"
expect_state "ci: nor any other ref in it" "$(ciw_align)" "III. Custom" "missing"
printf 'jobs:\n  lint-job:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci || true\n' \
    >"$CIW/.github/workflows/ci.yml"
expect_state "ci: verify.sh || true is missing" "$(ciw_align)" "I. Gates" "missing"

# policy refs are full dotted paths (#139); <hook>.<key> still means
# hooks.<hook>.<key>, and a proposal names the path the evaluator reads.
PFP="$WORKDIR/policy-path"
mkdir -p "$PFP/.specify/gates" "$PFP/.specify/memory"
printf '{ "hooks": { "markdownlint": { "severity": "error" } } }\n' >"$PFP/.specify/gates/policy.json"
cat >"$PFP/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. Full Path
<!-- gates:enforce surface=policy ref=hooks.markdownlint.severity expect=error -->
x

### II. Short Form
<!-- gates:enforce surface=policy ref=markdownlint.severity expect=error -->
x

### III. Absent Short
<!-- gates:enforce surface=policy ref=shellcheck.severity expect=error -->
x

### IV. Absent Full
<!-- gates:enforce surface=policy ref=hooks.prettier.severity expect=error -->
x
EOF
pf="$(CLAUDE_PROJECT_DIR="$PFP" bash "$CONST" align --constitution "$PFP/.specify/memory/constitution.md")"
expect_state "policy: a full dotted ref resolves" "$pf" "I. Full Path" "active"
expect_state "policy: the <hook>.<key> shorthand still resolves" "$pf" "II. Short Form" "active"
expect_state "policy: an absent hook key is missing" "$pf" "III. Absent Short" "missing"
expect_contains "policy: a shorthand proposal names the full path" "$pf" "set hooks.shellcheck.severity = error"
expect_contains "policy: a full-path proposal keeps it" "$pf" "set hooks.prettier.severity = error"
expect "policy: no proposal doubles the hooks prefix" "$(grep -c 'hooks\.hooks' <<<"$pf")" "0"

# List and object values (#171): non-empty is present, expect on a list is
# membership, on an object a key; every proposal converges, and an
# annotation no policy can satisfy is named as the annotation to fix.
PLV="$WORKDIR/policy-lists"
mkdir -p "$PLV/.specify/gates" "$PLV/.specify/memory"
cat >"$PLV/.specify/gates/policy.json" <<'EOF'
{ "hooks": {}, "git": { "block_main_commits": false, "ai_branding": { "terms": ["Copilot", "Claude"], "allow_phrases": [] } },
  "spec": { "include": ["specs/**"] } }
EOF
cat >"$PLV/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. List Present
<!-- gates:enforce surface=policy ref=git.ai_branding.terms -->
x

### II. List Member
<!-- gates:enforce surface=policy ref=git.ai_branding.terms expect=Copilot -->
x

### III. List Non Member
<!-- gates:enforce surface=policy ref=git.ai_branding.terms expect=Gemini -->
x

### IV. Empty List
<!-- gates:enforce surface=policy ref=git.ai_branding.allow_phrases -->
x

### V. Object Present
<!-- gates:enforce surface=policy ref=git.ai_branding -->
x

### VI. Object Key
<!-- gates:enforce surface=policy ref=git.ai_branding expect=terms -->
x

### VII. Absent List
<!-- gates:enforce surface=policy ref=spec.exclude -->
x

### VIII. False Boolean
<!-- gates:enforce surface=policy ref=git.block_main_commits -->
x

### IX. Bad Path
<!-- gates:enforce surface=policy ref=git.no_such_key -->
x

### X. Bad Expect
<!-- gates:enforce surface=policy ref=spec.severity expect=fatal -->
x
EOF
plv() { CLAUDE_PROJECT_DIR="$PLV" bash "$CONST" align --constitution "$PLV/.specify/memory/constitution.md"; }
pl="$(plv)"
expect_state "policy: a non-empty list is present" "$pl" "I. List Present" "active"
expect_state "policy: expect on a list is membership" "$pl" "II. List Member" "active"
expect_state "policy: a list without the expected entry is missing" "$pl" "III. List Non Member" "missing"
expect_state "policy: an empty list is missing" "$pl" "IV. Empty List" "missing"
expect_state "policy: a non-empty object is present" "$pl" "V. Object Present" "active"
expect_state "policy: expect on an object is a key" "$pl" "VI. Object Key" "active"
expect_state "policy: an absent list is missing" "$pl" "VII. Absent List" "missing"
expect_contains "policy: a missing list entry is proposed as an addition" "$pl" 'add "Gemini" to the git.ai_branding.terms list'
expect_contains "policy: an empty list gets an entry" "$pl" "add at least one entry to git.ai_branding.allow_phrases"
expect_contains "policy: an absent list gets an entry" "$pl" "add at least one entry to spec.exclude"
expect_contains "policy: a false boolean is set to true" "$pl" "set git.block_main_commits = true"
expect_contains "policy: a path the schema lacks is an annotation fix" "$pl" "fix the annotation: policy.schema.json has no git.no_such_key"
expect_contains "policy: an expect outside the enum is an annotation fix" "$pl" "fix the annotation: spec.severity is one of"
expect "policy: no proposal sets a value no policy accepts" "$(grep -c 'non-false\|= fatal\|= Gemini' <<<"$pl")" "0"
# Applying the proposals makes the principles active: they converge.
cat >"$PLV/.specify/gates/policy.json" <<'EOF'
{ "hooks": {}, "git": { "block_main_commits": true, "ai_branding": { "terms": ["Copilot", "Claude", "Gemini"], "allow_phrases": ["x"] } },
  "spec": { "include": ["specs/**"], "exclude": ["y"] } }
EOF
pl="$(plv)"
expect_state "policy: the list addition converges" "$pl" "III. List Non Member" "active"
expect_state "policy: the empty-list entry converges" "$pl" "IV. Empty List" "active"
expect_state "policy: the absent-list entry converges" "$pl" "VII. Absent List" "active"
expect_state "policy: the boolean proposal converges" "$pl" "VIII. False Boolean" "active"

# An expect below the schema minimum is an annotation fix (#199): proposing
# it would make verify.sh refuse the policy.
PMIN="$WORKDIR/policy-min"
mkdir -p "$PMIN/.specify/gates" "$PMIN/.specify/memory"
printf '{ "hooks": {} }\n' >"$PMIN/.specify/gates/policy.json"
cat >"$PMIN/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. Negative Timeout
<!-- gates:enforce surface=policy ref=spec.timeout_s expect=-5 -->
x

### II. Zero Records
<!-- gates:enforce surface=policy ref=attestation.max_records expect=0 -->
x

### III. Valid Timeout
<!-- gates:enforce surface=policy ref=spec.timeout_s expect=60 -->
x
EOF
pm="$(CLAUDE_PROJECT_DIR="$PMIN" bash "$CONST" align --constitution "$PMIN/.specify/memory/constitution.md")"
expect_contains "policy: a negative expect below the minimum is an annotation fix" "$pm" \
    "fix the annotation: spec.timeout_s is an integer >= 1, expect=-5 can never match"
expect_contains "policy: a zero expect below the minimum is an annotation fix" "$pm" \
    "fix the annotation: attestation.max_records is an integer >= 1, expect=0 can never match"
expect_contains "policy: an expect at or above the minimum is still proposed" "$pm" "set spec.timeout_s = 60"
expect "policy: no proposal sets a value below the minimum" "$(grep -c '= -5\|= 0,' <<<"$pm")" "0"

# align and check refuse a policy verify.sh would refuse (#199): nothing in
# it is enforced, so no principle may read as active against it.
printf '{ "hooks": {}, "spec": { "timeout_s": 60 }, "attestation": { "max_records": 0 } }\n' >"$PMIN/invalid.json"
rc=0
pmi="$(CLAUDE_PROJECT_DIR="$PMIN" bash "$CONST" align --constitution "$PMIN/.specify/memory/constitution.md" \
    --policy "$PMIN/invalid.json" 2>&1)" || rc=$?
expect "align --policy <invalid>: exit 1" "$rc" "1"
expect_contains "align --policy <invalid>: names the validator error" "$pmi" "max_records must be an integer >= 1"
expect_absent "align --policy <invalid>: reports no principle active" "$pmi" "active"
# The invalid policy satisfies this principle, so only the refusal fails it.
printf '# C\n\n## Core Principles\n\n### I. Valid Timeout\n<!-- gates:enforce surface=policy ref=spec.timeout_s expect=60 -->\n' \
    >"$PMIN/one.md"
rc=0
pmi="$(CLAUDE_PROJECT_DIR="$PMIN" bash "$CONST" check --constitution "$PMIN/one.md" \
    --policy "$PMIN/invalid.json" 2>&1)" || rc=$?
expect "check --policy <invalid>: exit 1" "$rc" "1"
expect_contains "check --policy <invalid>: refuses the policy" "$pmi" "invalid policy"
expect_absent "check --policy <invalid>: reports nothing enforced" "$pmi" "enforced:"
rc=0
pmi="$(CLAUDE_PROJECT_DIR="$PMIN" bash "$CONST" align --constitution "$PMIN/.specify/memory/constitution.md" \
    --policy "$PMIN/no-such.json" 2>&1)" || rc=$?
expect "align --policy <missing file>: exit 1" "$rc" "1"
cp "$PMIN/invalid.json" "$PMIN/.specify/gates/policy.json"
rc=0
pmi="$(CLAUDE_PROJECT_DIR="$PMIN" bash "$CONST" align --constitution "$PMIN/.specify/memory/constitution.md" 2>&1)" || rc=$?
expect "align against an invalid project policy: exit 1" "$rc" "1"
expect_absent "align against an invalid project policy: reports no principle active" "$pmi" "active"

# Overlay targeting: a missing policy surface proposes an overlay edit.
expect_contains "align: missing policy proposes an OVERLAY edit" "$alm" "policy.json (overlay)"

# 003 interplay: with a live contract, policy surfaces evaluate against the
# EFFECTIVE policy (the loader resolves it because the overlay declares extends).
C3="$WORKDIR/contract"
mkdir -p "$C3/.specify/gates" "$C3/.specify/memory"
cat >"$C3/.specify/gates/policy.json" <<'EOF'
{ "extends": { "source": "x", "version": "v1" }, "spec": { "severity": "error" } }
EOF
cat >"$C3/.specify/gates/policy.effective.json" <<'EOF'
{ "extends": { "source": "x", "version": "v1" }, "hooks": {}, "spec": { "severity": "error" } }
EOF
cat >"$C3/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. Effective
<!-- gates:enforce surface=policy ref=spec.severity expect=error -->
x
EOF
al3="$(CLAUDE_PROJECT_DIR="$C3" bash "$CONST" align --constitution "$C3/.specify/memory/constitution.md")"
expect_state "align: policy resolves against the 003 effective policy" "$al3" "I. Effective" "active"

# SC-003 decline guarantee: align is pure computation -- the tree is untouched.
tree_before="$(cd "$PROJ" && find . -type f -not -path './.git/*' | sort | xargs shasum 2>/dev/null | shasum)"
CLAUDE_PROJECT_DIR="$PROJ" bash "$CONST" align --constitution "$PROJ/.specify/memory/constitution.md" >/dev/null
tree_after="$(cd "$PROJ" && find . -type f -not -path './.git/*' | sort | xargs shasum 2>/dev/null | shasum)"
expect "align leaves the repo byte-identical (SC-003, pure compute)" "$tree_before" "$tree_after"

# --- check: verdict + fixed-severity exit (US3) ------------------------------

CHK="$WORKDIR/chk"
mkdir -p "$CHK/.specify/gates" "$CHK/.specify/memory" "$CHK/.github/workflows"
printf 'jobs:\n  gates:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n' >"$CHK/.github/workflows/ci.yml"
printf '{ "hooks": { "prettier": { "severity": "error" } } }\n' >"$CHK/.specify/gates/policy.json"

# All enforced/prose/unannotated -> exit 0.
cat >"$CHK/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. Enforced
<!-- gates:enforce surface=ci ref=gates -->
x

### II. Prose
<!-- gates:enforce surface=prose -->
x

### III. Unannotated
no marker here
EOF
rc=0
chk_out="$(CLAUDE_PROJECT_DIR="$CHK" bash "$CONST" check)" || rc=$?
expect "check: all-enforced exits 0" "$rc" "0"
expect_contains "check: enforced principle labelled" "$chk_out" "enforced: I. Enforced"
expect_contains "check: prose-only labelled" "$chk_out" "prose-only: II. Prose"
expect_contains "check: unannotated counted informationally" "$chk_out" "unannotated (informational)"

# A gap -> exit 1 naming the principle + surface.
cat >>"$CHK/.specify/memory/constitution.md" <<'EOF'

### IV. Gap
<!-- gates:enforce surface=policy ref=attestation.parity expect=error -->
x
EOF
rc=0
chk_gap="$(CLAUDE_PROJECT_DIR="$CHK" bash "$CONST" check)" || rc=$?
expect "check: any gap exits 1" "$rc" "1"
expect_contains "check: gap names principle and surface" "$chk_gap" "gap: IV. Gap"

# prose-only never turns a gap into a pass, and never itself fails: an
# all-prose constitution exits 0.
cat >"$CHK/.specify/memory/all-prose.md" <<'EOF'
# C

## Core Principles

### I. A
<!-- gates:enforce surface=prose -->
x
EOF
rc=0
CLAUDE_PROJECT_DIR="$CHK" bash "$CONST" check --constitution "$CHK/.specify/memory/all-prose.md" >/dev/null || rc=$?
expect "check: all-prose exits 0 (prose never fails)" "$rc" "0"

# A malformed marker -> exit 1 naming constitution.md:<line>.
cat >"$CHK/.specify/memory/bad.md" <<'EOF'
# C

## Core Principles

### I. Bad
<!-- gates:enforce surface=teleport ref=x -->
x
EOF
rc=0
chk_bad="$(CLAUDE_PROJECT_DIR="$CHK" bash "$CONST" check --constitution "$CHK/.specify/memory/bad.md")" || rc=$?
expect "check: malformed marker exits 1" "$rc" "1"
expect_contains "check: malformed names the file and line" "$chk_bad" "bad.md:6: malformed marker"

# --- scope: only ### under ## Core Principles are principles (#82) ----------

PLIB="$REPO_ROOT/extension/runtime/lib/constitution.sh"
cparse() { bash -c "source '$PLIB'; gates_const_parse '$1'"; }
cat >"$WORKDIR/scope1.md" <<'MD'
## Core Principles

### I. Tests First
<!-- gates:enforce surface=prose -->

## Additional Constraints

### Performance Budget
Some prose.
MD
sc1="$(cparse "$WORKDIR/scope1.md")"
expect "scope: ### under another section is not a principle" "$(grep -c '^PRINCIPLE' <<<"$sc1")" "1"
expect_parse "scope: the Core Principles heading still is" "$sc1" "I. Tests First" "prose"
cat >"$WORKDIR/scope2.md" <<'MD'
## Core Principles

### I. One

## Governance

### Amendments
<!-- gates:enforce surface=prose -->
MD
sc2="$(cparse "$WORKDIR/scope2.md")"
expect_contains "scope: a marker outside Core Principles is MALFORMED" "$sc2" "gates:enforce marker outside Core Principles"
rc=0
sc2chk="$(CLAUDE_PROJECT_DIR="$WORKDIR" bash "$CONST" check --constitution "$WORKDIR/scope2.md")" || rc=$?
expect "scope: check fails on the misplaced marker" "$rc" "1"
expect_contains "scope: check names its line" "$sc2chk" "scope2.md:8: malformed marker"
# A heading or marker inside a fenced code block is example content, not a
# principle (#199), for backtick and tilde fences, with a shorter fence
# nested inside a longer one.
cat >"$WORKDIR/scope-fence.md" <<'MD'
## Core Principles

### I. Real
<!-- gates:enforce surface=prose -->

````markdown
### II. Example
<!-- gates:enforce surface=nope -->
```
<!-- gates:enforce surface=nope -->
```
````

~~~text
### III. Tilde Example
<!-- gates:enforce surface=nope -->
~~~

### IV. After The Fences
<!-- gates:enforce surface=prose -->
MD
scf="$(cparse "$WORKDIR/scope-fence.md")"
expect "fence: only the two real principles are parsed" "$(grep -c '^PRINCIPLE' <<<"$scf")" "2"
expect_absent "fence: a marker inside a fence is not MALFORMED" "$scf" "MALFORMED"
expect_parse "fence: the principle after the fences keeps its marker" "$scf" "IV. After The Fences" "prose"
printf '# C\n\n### Orphan\n' >"$WORKDIR/scope3.md"
expect "scope: no Core Principles -> no principles, NOCORE" "$(cparse "$WORKDIR/scope3.md")" "NOCORE"
sc3chk="$(CLAUDE_PROJECT_DIR="$WORKDIR" bash "$CONST" check --constitution "$WORKDIR/scope3.md" || true)"
expect_contains "scope: check says the section is missing" "$sc3chk" "has no '## Core Principles' section"
expect "scope: this repo's constitution keeps its 5 principles" \
    "$(cparse "$REPO_ROOT/.specify/memory/constitution.md" | grep -c '^PRINCIPLE')" "5"
cat >"$WORKDIR/scope4.md" <<'MD'
# Legacy

## Core Principles

### I. Ship Fast

Ship.

## Governance

### Amendments

Reviewed.
MD
printf '%s' '{ "selections": [ { "name": "No Secrets", "surface": "scanner", "ref": "gitleaks:default", "body": "Never commit a secret." } ] }' \
    >"$WORKDIR/scope4.json"
run_const draft --corpus "$CORPUS" --selections "$WORKDIR/scope4.json" \
    --out "$WORKDIR/scope4-out.md" --augment "$WORKDIR/scope4.md"
expect_parse "scope: augment numbers after Core Principles only (II, not III)" \
    "$(cparse "$WORKDIR/scope4-out.md")" "II. No Secrets" "scanner"

# --- CLI: argument errors and explicit file flags (#98) ----------------------

# Each malformed call exits 1 and names the problem; nothing is written.
while IFS='|' read -r label want args; do
    rc=0
    # shellcheck disable=SC2086  # deliberate word split of the argument list
    err="$(run_const $args 2>&1 >/dev/null)" || rc=$?
    expect "cli: $label exits 1" "$rc" "1"
    expect_contains "cli: $label says why" "$err" "$want"
done <<'ROWS'
no subcommand|usage: constitution.sh fragments|
unknown subcommand|usage: constitution.sh fragments|bogus
fragments unknown flag|fragments: unknown argument: --bogus|fragments --bogus
fragments without --corpus|fragments needs --corpus DIR|fragments
draft unknown flag|draft: unknown argument: --bogus|draft --bogus
draft without --corpus|draft needs --corpus DIR|draft
draft without --selections|draft needs --selections FILE|draft --corpus /nonexistent
draft without --out|draft needs --out FILE|draft --corpus /nonexistent --selections /nonexistent
detect unknown flag|detect: unknown argument: --bogus|detect --bogus
align unknown flag|align: unknown argument: --bogus|align --bogus
check unknown flag|check: unknown argument: --bogus|check --bogus
ROWS

# detect --constitution reads the named file, not the default path.
expect "cli: detect --constitution reads that file" \
    "$(run_const detect --constitution "$WORKDIR/no-such-constitution.md")" "absent"

# check --policy evaluates policy surfaces against that file: the same
# principle is enforced under the project policy and a gap under the override.
CP="$WORKDIR/chk-policy"
mkdir -p "$CP/.specify/gates" "$CP/.specify/memory"
printf '{ "hooks": { "prettier": { "severity": "error" } } }\n' >"$CP/.specify/gates/policy.json"
printf '{ "hooks": { "prettier": { "severity": "warning" } } }\n' >"$CP/override.json"
cat >"$CP/.specify/memory/constitution.md" <<'MD'
# C

## Core Principles

### I. Formatting Blocks
<!-- gates:enforce surface=policy ref=prettier.severity expect=error -->
x
MD
rc=0
CLAUDE_PROJECT_DIR="$CP" bash "$CONST" check >/dev/null 2>&1 || rc=$?
expect "cli: check under the project policy exits 0" "$rc" "0"
rc=0
CLAUDE_PROJECT_DIR="$CP" bash "$CONST" check --policy "$CP/override.json" >/dev/null 2>&1 || rc=$?
expect "cli: check --policy uses the override (gap, exit 1)" "$rc" "1"
rc=0
CLAUDE_PROJECT_DIR="$CP" bash "$CONST" align --policy "$CP/override.json" >/dev/null 2>&1 || rc=$?
expect "cli: align accepts --policy" "$rc" "0"

# --- summary -----------------------------------------------------------------

echo ""
echo "test-constitution: $PASS/$TOTAL passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
