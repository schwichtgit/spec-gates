#!/bin/bash
set -euo pipefail

# PreToolUse hook for Write/Edit.
# Reads JSON from stdin, parses file_path, blocks modification of sensitive files.
# Exit 2 = block. Exit 0 = allow, or (with the JSON below on stdout) ask.
#
# Never a silent allow (issue #83): without jq, or when the input is not
# valid JSON, file_path is read in raw mode (see raw_field) and the built-in
# name rules still block. What the hook cannot evaluate -- policy
# protected_files.extra without jq, a policy library that fails to load, an
# internal error -- returns a PreToolUse "ask" decision for a human.

# ask <reason>: hand the decision to the human (PreToolUse "ask"). Static
# printf, no jq: this must work in exactly the states where jq is missing.
ask() {
    local r="${1//\\/\\\\}"
    r="${r//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "gates: $r"
    exit 0
}

trap 'ask "protect-files.sh failed unexpectedly (line $LINENO); run /speckit.gates.doctor"' ERR

# raw_field <name>: print the decoded value of the JSON string field <name>
# from $INPUT without jq. A JSON string is a regular language, so the sed
# match is exact for it; escapes are decoded below. Returns 1 when the
# field is absent and 2 when the value uses an escape this decoder does not
# handle (\uXXXX could spell a blocked word), which the caller turns into
# "ask".
raw_field() {
    local v
    # The leading "=" tells an empty value ("") apart from no match.
    v="$(printf '%s' "$INPUT" | tr '\n' ' ' \
        | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/=\1/p')"
    if [[ -z "$v" ]]; then
        # The key is there but its value is not a plain string: undecidable.
        printf '%s' "$INPUT" | grep -qE '"'"$1"'"[[:space:]]*:' && return 2
        return 1
    fi
    v="${v#=}"
    [[ "$v" == *'\u'* ]] && return 2
    v="${v//\\\\/$'\001'}"
    v="${v//\\\"/\"}"
    v="${v//\\\//\/}"
    v="${v//\\n/$'\n'}"
    v="${v//\\t/$'\t'}"
    v="${v//\\r/}"
    v="${v//$'\001'/\\}"
    printf '%s' "$v"
}

# The rules below test with grep/sed: without them each test is silently
# false, which would allow every edit.
for _tool in grep sed tr basename; do
    command -v "$_tool" >/dev/null 2>&1 \
        || ask "$_tool not found, so protect-files cannot check this edit; run /speckit.gates.doctor"
done

INPUT=$(cat /dev/stdin)
DEGRADED=""
if command -v jq >/dev/null 2>&1 && printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
else
    if command -v jq >/dev/null 2>&1; then
        DEGRADED="the hook input is not valid JSON"
    else
        DEGRADED="jq not found"
    fi
    rc=0
    FILE_PATH="$(raw_field file_path)" || rc=$?
    [[ "$rc" -eq 2 ]] && ask "cannot read the file path without jq ($DEGRADED); confirm this edit"
fi

if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

BASENAME=$(basename "$FILE_PATH")

BLOCKED=""

# Allowlist: .example / .sample / .template files are safe to edit even when
# the base name looks sensitive (e.g. .env.example). Mirrors the git
# pre-commit forbidden-file allowlist so the two boundaries agree.
if [[ "$BASENAME" == *.example ]] || [[ "$BASENAME" == *.sample ]] \
    || [[ "$BASENAME" == *.template ]]; then
    exit 0
fi

# Environment files
if [[ "$BASENAME" == ".env" ]] || [[ "$BASENAME" == .env.* ]]; then
    BLOCKED="Environment file"
fi

# SSH keys
case "$BASENAME" in
    id_rsa*|id_ed25519*|id_ecdsa*|authorized_keys|known_hosts)
        BLOCKED="SSH key/config file"
        ;;
esac

# Certificates and key stores
case "$BASENAME" in
    *.pem|*.key|*.crt|*.p12|*.pfx|*.jks|*.keystore)
        BLOCKED="Certificate/key file"
        ;;
esac

# Credentials (#71): an exact credential file name is strong evidence and
# blocks. A sensitive word that merely appears in the name (a test such as
# test_no_secret_leak.py, a token parser) asks the human instead: blocking
# it outright left no way to edit such files at all.
case "$BASENAME" in
    credentials|credentials.json|credentials.yml|credentials.yaml|.netrc|.pypirc)
        BLOCKED="Credentials file"
        ;;
esac
NAMEASK=""
if [[ -z "$BLOCKED" ]]; then
    _word="$(echo "$BASENAME" | grep -oiE 'credentials|secret|password|token|keystore' | head -n 1 || true)"
    [[ -n "$_word" ]] && NAMEASK="the file name contains '$_word'; confirm $FILE_PATH does not hold a credential"
fi

# Cloud configs
if echo "$BASENAME" | grep -qE '^(gcloud-.*\.json|service-account.*\.json|aws-credentials)$'; then
    BLOCKED="Cloud credentials file"
fi

# Lock files
case "$BASENAME" in
    package-lock.json|yarn.lock|pnpm-lock.yaml|Cargo.lock|poetry.lock)
        BLOCKED="Lock file (auto-generated)"
        ;;
esac

# Sensitive directories
if echo "$FILE_PATH" | grep -qE '/(\.ssh|\.gnupg|\.aws|\.gcloud)/'; then
    BLOCKED="File in sensitive directory"
fi

# Policy-declared extra protected paths (protected_files.extra). Matched against
# both the project-relative path and the basename so exact entries and globs
# (e.g. ".specify/memory/constitution.md", "docs/**") both work.
ASK=""
if [[ -z "$BLOCKED" ]]; then
    PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    POLICY_LIB="$PROJECT_ROOT/.specify/gates/lib/policy.sh"
    POLICY_FILE="$PROJECT_ROOT/.specify/gates/policy.json"
    if [[ -n "$DEGRADED" ]]; then
        # The policy reader needs jq. With entries declared, the edit may be
        # protected and nothing here can tell: ask rather than guess.
        if [[ -f "$POLICY_FILE" ]] \
            && tr '\n' ' ' <"$POLICY_FILE" | grep -qE '"extra"[[:space:]]*:[[:space:]]*\[[[:space:]]*"'; then
            ASK="policy protected_files.extra cannot be checked ($DEGRADED); confirm $FILE_PATH is not protected"
        fi
    elif [[ -f "$POLICY_LIB" ]]; then
        # shellcheck source=/dev/null disable=SC1091
        # A syntax error in a sourced file aborts the whole hook, so check it
        # first (bash -n parses without running).
        if ! bash -n "$POLICY_LIB" 2>/dev/null \
            || ! source "$POLICY_LIB" 2>/dev/null \
            || ! command -v gates_policy_section_list >/dev/null 2>&1; then
            ask "the gates policy library failed to load, so protected_files.extra cannot be checked; run /speckit.gates.doctor"
        fi
        # The reader returns no entries for an unparseable policy, which
        # would read as "nothing protected".
        _pf="$(gates_policy_file)"
        if [[ -f "$_pf" ]] && ! jq -e . "$_pf" >/dev/null 2>&1; then
            ask "$_pf is not valid JSON, so protected_files.extra cannot be checked; run /speckit.gates.doctor"
        fi
        REL="$FILE_PATH"
        [[ "$FILE_PATH" == "$PROJECT_ROOT/"* ]] && REL="${FILE_PATH#"$PROJECT_ROOT"/}"
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            if gates_glob_match "$REL" "$entry" \
                || gates_glob_match "$FILE_PATH" "$entry" \
                || [[ "$BASENAME" == "$entry" ]]; then
                BLOCKED="Protected by policy (protected_files.extra: $entry)"
                break
            fi
        done < <(gates_policy_section_list protected_files extra)
    fi
fi

if [[ -n "$BLOCKED" ]]; then
    echo "BLOCKED: $BLOCKED" >&2
    echo "File: $FILE_PATH" >&2
    exit 2
fi

# Project-owned rules (#71) run once no shipped rule blocked, so they can
# add a refusal but never remove one. They run before any "ask": a project
# refusal is stronger than a question.
LROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
if compgen -G "$LROOT/.specify/gates/hooks.local.d/protect-files/*.sh" >/dev/null; then
    LLIB="$LROOT/.specify/gates/lib/local-hooks.sh"
    if [[ ! -f "$LLIB" ]] || ! bash -n "$LLIB" 2>/dev/null; then
        ask "local rules exist in hooks.local.d/protect-files, but lib/local-hooks.sh cannot load; run /speckit.gates.doctor"
    fi
    # shellcheck source=/dev/null disable=SC1090
    source "$LLIB"
    if ! GATES_LOCAL_STDIN="$INPUT" gates_run_local "$LROOT" protect-files; then
        echo "BLOCKED: $GATES_LOCAL_MSG" >&2
        echo "File: $FILE_PATH" >&2
        exit 2
    fi
fi

[[ -n "$ASK" ]] && ask "$ASK"
[[ -n "$NAMEASK" ]] && ask "$NAMEASK"

if [[ -n "$DEGRADED" ]]; then
    echo "gates: protect-files checked in raw mode ($DEGRADED); run /speckit.gates.doctor" >&2
fi
exit 0
