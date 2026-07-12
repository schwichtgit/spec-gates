#!/bin/bash
set -euo pipefail

# Constitution-as-contract tests (feature 004): the deterministic pipeline
# behind the guided session -- fragments, draft, detect (US1). Alignment and
# check/doctor cases are added with US2/US3.
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

# ci: a workflow naming the check.
printf 'jobs:\n  mygate:\n    steps: []\n' >"$PROJ/.github/workflows/ci.yml"

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
printf 'jobs:\n  other:\n    steps: []\n' >"$PROJ/.github/workflows/ci.yml" # ci name gone
rm "$PROJ/.checkov.yml"                               # scanner config gone
al2="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$CONST" align --constitution "$PROJ/.specify/memory/constitution.md")"
expect_state "align: non-executable agent-hook missing" "$al2" "III. Agent Hook" "missing"
expect_state "align: removed git-hook missing" "$al2" "IV. Git Hook" "missing"
expect_state "align: ci check absent missing" "$al2" "V. Ci" "missing"
expect_state "align: scanner config absent missing" "$al2" "VII. Scanner" "missing"

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
{ "extends": { "source": "x", "version": "v1" }, "spec": { "severity": "error" } }
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

# --- summary -----------------------------------------------------------------

echo ""
echo "test-constitution: $PASS/$TOTAL passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
