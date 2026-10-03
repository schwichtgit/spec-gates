#!/usr/bin/env bash
# policy.sh -- loader for .specify/gates/policy.json
#
# Usage (sourced):
#   source .claude-plugin/lib/policy.sh
#   gates_policy_get <hook> <field>    # scalar (empty string on missing)
#   gates_policy_list <hook> <field>   # one line per array element
#   gates_validate_policy [file]       # returns 0 on pass, nonzero on fail
#
# Missing hook, missing field, or missing policy file all yield empty output
# with exit 0 -- the loader is fail-open. Strict checks happen in
# gates_validate_policy, which init and upgrade call before writing anything.
#
# Usage (executable CLI):
#   policy.sh get <hook> <field>
#   policy.sh list <hook> <field>
#   policy.sh validate [file]

# shellcheck disable=SC2034   # library file; vars are consumed by callers

gates_policy_file() {
    if [[ -n "${GATES_POLICY_FILE:-}" ]]; then
        printf '%s\n' "$GATES_POLICY_FILE"
        return 0
    fi
    local project_dir
    project_dir="${CLAUDE_PROJECT_DIR:-}"
    if [[ -z "$project_dir" ]]; then
        project_dir="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
    fi
    local overlay="$project_dir/.specify/gates/policy.json"
    local effective="$project_dir/.specify/gates/policy.effective.json"
    # Contract resolution (feature 003): an overlay that extends a baseline is
    # enforced through the materialized effective policy. The grep is a cheap
    # short-circuit for the dormant case (no extends anywhere in the file);
    # jq then confirms a real top-level declaration. Integrity of the
    # effective file is the contract gate's job, not the resolver's.
    if [[ -f "$effective" && -f "$overlay" ]] \
        && grep -q '"extends"' "$overlay" 2>/dev/null \
        && jq -e 'has("extends")' "$overlay" >/dev/null 2>&1; then
        printf '%s\n' "$effective"
        return 0
    fi
    printf '%s\n' "$overlay"
}

gates_policy_get() {
    local hook="${1:-}" field="${2:-}"
    [[ -z "$hook" || -z "$field" ]] && return 0
    local file
    file="$(gates_policy_file)"
    [[ -f "$file" ]] || return 0
    jq -r --arg h "$hook" --arg f "$field" '
        .hooks[$h][$f] // "" |
        if type == "array" or type == "object" then "" else tostring end
    ' "$file" 2>/dev/null || true
}

gates_policy_list() {
    local hook="${1:-}" field="${2:-}"
    [[ -z "$hook" || -z "$field" ]] && return 0
    local file
    file="$(gates_policy_file)"
    [[ -f "$file" ]] || return 0
    jq -r --arg h "$hook" --arg f "$field" '
        (.hooks[$h][$f] // []) |
        if type == "array" then .[] else empty end
    ' "$file" 2>/dev/null || true
}

# Read a scalar from a TOP-LEVEL section (not under .hooks), e.g.
# gates_policy_section_get git block_main_commits. Empty on missing.
gates_policy_section_get() {
    local section="${1:-}" field="${2:-}"
    [[ -z "$section" || -z "$field" ]] && return 0
    local file
    file="$(gates_policy_file)"
    [[ -f "$file" ]] || return 0
    # NB: do not use `// ""` here -- jq's alternative operator treats a literal
    # `false` as absent, which would turn a boolean toggle into "". Handle null
    # explicitly so `false` round-trips as the string "false".
    jq -r --arg s "$section" --arg f "$field" '
        ((.[$s] // {}) | .[$f]) as $v
        | if $v == null then ""
          elif ($v | type) == "array" or ($v | type) == "object" then ""
          else ($v | tostring) end
    ' "$file" 2>/dev/null || true
}

# Read an array field from a TOP-LEVEL section, one element per line, e.g.
# gates_policy_section_list protected_files extra.
gates_policy_section_list() {
    local section="${1:-}" field="${2:-}"
    [[ -z "$section" || -z "$field" ]] && return 0
    local file
    file="$(gates_policy_file)"
    [[ -f "$file" ]] || return 0
    jq -r --arg s "$section" --arg f "$field" '
        (.[$s][$f] // []) |
        if type == "array" then .[] else empty end
    ' "$file" 2>/dev/null || true
}

# Match <path> against a policy <glob> using bash `[[ == ]]` semantics, with
# `**/` (leading) and `/**` (trailing) normalized so the common conventions
# (`dir/**`, `**/name`) work without globstar. Returns 0 on match. Shared by
# protect-files.sh and the pre-commit forbidden-file scan.
gates_glob_match() {
    local path="$1" glob="$2"
    [[ -z "$glob" ]] && return 1
    # shellcheck disable=SC2053
    [[ "$path" == "$glob" ]] && return 0
    # shellcheck disable=SC2053
    [[ "$path" == $glob ]] && return 0
    if [[ "$glob" == */\*\* ]]; then
        local trimmed="${glob%/\*\*}"
        [[ "$path" == "$trimmed" || "$path" == "$trimmed"/* ]] && return 0
    fi
    if [[ "$glob" == \*\*/* ]]; then
        local rest="${glob#\*\*/}"
        # shellcheck disable=SC2053
        [[ "$path" == "$rest" || "$path" == */"$rest" ]] && return 0
    fi
    return 1
}

# Read an array at a nested path, one element per line, e.g.
# gates_policy_path_list git ai_branding terms. Returns 1 when the key is
# absent (or not an array) so callers can tell "absent -> use defaults" from
# "present but empty -> disabled".
gates_policy_path_list() {
    [[ $# -gt 0 ]] || return 1
    local file path_json out
    file="$(gates_policy_file)"
    [[ -f "$file" ]] || return 1
    path_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)" || return 1
    out="$(jq -r --argjson p "$path_json" '
        (try getpath($p) catch null) as $v
        | if ($v | type) == "array" then "+", ($v[] | tostring) else "-" end
    ' "$file" 2>/dev/null)" || return 1
    [[ "${out%%$'\n'*}" == "+" ]] || return 1
    [[ "$out" == *$'\n'* ]] && printf '%s\n' "${out#*$'\n'}"
    return 0
}

# Protected-change trailer switch (git.protected_change_trailer, default on).
gates_protected_trailer_enabled() {
    [[ "$(gates_policy_section_get git protected_change_trailer)" != "false" ]]
}

# Write the policy committed at <rev> to <dest> -- its materialized effective
# policy when the overlay extends a baseline. Returns 1 when <rev> carries no
# policy (dest untouched).
gates_policy_at_rev() { # <rev> <dest>
    local rev="$1" dest="$2" tmp
    tmp="$(mktemp 2>/dev/null || mktemp -t gates-policy)" || return 1
    if ! git show "$rev:.specify/gates/policy.json" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if jq -e 'has("extends")' "$tmp" >/dev/null 2>&1 \
        && git cat-file -e "$rev:.specify/gates/policy.effective.json" 2>/dev/null; then
        git show "$rev:.specify/gates/policy.effective.json" >"$tmp" 2>/dev/null
    fi
    mv "$tmp" "$dest"
}

# protected_files.extra as the UNION of the policies committed at <rev>...,
# plus the worktree policy when called with no revs (worktree + HEAD). Reading
# the committed copy means a staged policy.json that drops its own protection
# is still judged by the protection it removes (issue #47).
# shellcheck disable=SC2120  # revs are passed by protected-range.sh
gates_protected_list() { # [rev...]
    local tmp rev
    local -a revs=("$@")
    {
        if [[ "${#revs[@]}" -eq 0 ]]; then
            gates_policy_section_list protected_files extra
            revs=(HEAD)
        fi
        tmp="$(mktemp 2>/dev/null || mktemp -t gates-policy)" || tmp=""
        if [[ -n "$tmp" ]]; then
            for rev in "${revs[@]}"; do
                if gates_policy_at_rev "$rev" "$tmp"; then
                    GATES_POLICY_FILE="$tmp" gates_policy_section_list protected_files extra
                fi
            done
            rm -f "$tmp"
        fi
    } | awk 'NF && !seen[$0]++'
}

# Filter paths on stdin down to those matching a protected entry in
# <patterns> (newline-separated, as printed by gates_protected_list).
gates_match_protected() { # <patterns>
    local -a pats=()
    local e f
    while IFS= read -r e; do
        [[ -n "$e" ]] && pats+=("$e")
    done <<<"$1"
    [[ "${#pats[@]}" -eq 0 ]] && { cat >/dev/null; return 0; }
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        for e in "${pats[@]}"; do
            if gates_glob_match "$f" "$e" || [[ "$(basename "$f")" == "$e" ]]; then
                printf '%s\n' "$f"
                break
            fi
        done
    done
}

# Paths in the index (added, modified, deleted; renames split into delete +
# add) that match a protected entry, one per line. Deleting or renaming away
# a protected file is a protected change too.
# shellcheck disable=SC2119  # no revs: worktree + HEAD
gates_staged_protected_paths() {
    { git diff --cached --name-only --no-renames --diff-filter=ACMRD 2>/dev/null || true; } \
        | gates_match_protected "$(gates_protected_list)"
}

# Values of the trailer <key> (case-insensitive) in "Key: value" text on
# stdin, one per line, trimmed. Feed it `git interpret-trailers --parse`
# output, or a PR body (any line starting with the key counts there).
gates_trailer_values() { # <key>
    awk -v k="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
        { i = index($0, ":"); if (i == 0) next
          key = tolower(substr($0, 1, i - 1)); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
          if (key != k) next
          v = substr($0, i + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if (v != "") print v }'
}

# The protected-change rule, shared by commit-msg (git boundary) and
# protected-range.sh (CI). Every protected path must be declared, a
# declaration must name a path the change touches, and a protected change
# needs an approver. Prints one ERROR line per violation (plus a hint) on
# stderr; returns the violation count, capped at 255 (0 = pass).
gates_protected_check() { # <protected> <changed> <declared> <approvers>
    local protected="$1" changed="$2" declared="$3" approvers="$4" p n=0
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if ! printf '%s\n' "$declared" | grep -qxF -e "$p"; then
            echo "ERROR: protected file changed without a declaration: $p" >&2
            echo "  Add the trailer:  Protected-Change: $p" >&2
            n=$((n + 1))
        fi
    done <<<"$protected"
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if ! printf '%s\n' "$changed" | grep -qxF -e "$p"; then
            echo "ERROR: Protected-Change names a path this change does not touch: $p" >&2
            n=$((n + 1))
        fi
    done <<<"$declared"
    if [[ -n "$protected" && -z "$approvers" ]]; then
        echo "ERROR: protected change without an approver (add the trailer:  Approved-By: <name>)." >&2
        n=$((n + 1))
    fi
    [[ "$n" -gt 255 ]] && n=255
    return "$n"
}

gates_validate_policy() {
    local file="${1:-}"
    if [[ -z "$file" ]]; then
        file="$(gates_policy_file)"
    fi
    if [[ ! -f "$file" ]]; then
        echo "ERROR: policy file not found: $file" >&2
        return 2
    fi
    if ! jq empty "$file" >/dev/null 2>&1; then
        echo "ERROR: $file is not valid JSON" >&2
        return 3
    fi
    if ! jq -e '(type == "object") and has("hooks") and (.hooks | type == "object")' \
        "$file" >/dev/null 2>&1; then
        echo "ERROR: $file must be an object with a top-level \"hooks\" object" >&2
        return 4
    fi
    local errors
    errors="$(jq -r '
        def allowed_keys: [
            "include","exclude","orchestrator","severity",
            "on_missing_runner","on_missing_tests","custom_command"
        ];
        def orch_values:   ["none","task","custom"];
        def sev_values:    ["error","warning","info"];
        def runner_values: ["warn","skip"];
        def tests_values:  ["warn","skip"];
        .hooks
        | to_entries[]
        | . as $e
        | [
            ( if ($e.value | has("orchestrator"))
                and (orch_values | index($e.value.orchestrator)) == null
                then "\($e.key): invalid orchestrator \"\($e.value.orchestrator)\" (allowed: \(orch_values | join(", ")))"
              else empty end ),
            ( if ($e.value | has("severity")) | not
                then "\($e.key): missing required field \"severity\""
              elif (sev_values | index($e.value.severity)) == null
                then "\($e.key): invalid severity \"\($e.value.severity)\" (allowed: \(sev_values | join(", ")))"
              else empty end ),
            ( if ($e.value | has("on_missing_runner"))
                and (runner_values | index($e.value.on_missing_runner)) == null
                then "\($e.key): invalid on_missing_runner \"\($e.value.on_missing_runner)\" (allowed: \(runner_values | join(", ")))"
              else empty end ),
            ( if ($e.value | has("on_missing_tests"))
                and (tests_values | index($e.value.on_missing_tests)) == null
                then "\($e.key): invalid on_missing_tests \"\($e.value.on_missing_tests)\" (allowed: \(tests_values | join(", ")))"
              else empty end ),
            ( $e.value
              | keys[]
              | . as $k
              | if (allowed_keys | index($k)) == null
                  then "\($e.key): unknown field \"\($k)\""
                else empty end ),
            ( if $e.value.orchestrator == "custom" then
                if ($e.value | has("custom_command")) | not
                  then "\($e.key): orchestrator \"custom\" requires non-empty \"custom_command\""
                elif ($e.value.custom_command | type) != "string"
                  then "\($e.key): \"custom_command\" must be a string"
                elif ($e.value.custom_command | length) == 0
                  then "\($e.key): orchestrator \"custom\" requires non-empty \"custom_command\""
                else empty end
              else empty end )
          ]
        | .[]
    ' "$file" 2>/dev/null)"

    # Validate the optional top-level protected_files, git, and attestation
    # sections.
    local section_errors
    section_errors="$(jq -r '
        def git_keys: ["block_main_commits", "conventional_commits", "forbid_ai_isms", "protected_change_trailer", "block_bulk_staging", "ai_branding"];
        def git_bool_keys: ["block_main_commits", "conventional_commits", "forbid_ai_isms", "protected_change_trailer", "block_bulk_staging"];
        def brand_keys: ["terms", "allow_phrases"];
        def att_keys: ["enabled", "max_records", "parity"];
        def parity_values: ["error", "warning", "off"];
        def spec_keys: ["enabled", "severity", "include", "exclude", "timeout_s"];
        def spec_sev_values: ["error", "warning"];
        def ext_keys: ["source", "version", "file"];
        def pf_errors:
            if has("protected_files") then
                (.protected_files) as $p
                | if ($p | type) != "object" then ["protected_files: must be an object"]
                  else
                    [ $p | keys[] | select(. != "extra") | "protected_files: unknown field \"\(.)\"" ]
                    + ( if ($p | has("extra")) and (($p.extra | type) != "array")
                          then ["protected_files.extra: must be an array of strings"]
                        else [ ($p.extra // [])[] | select(type != "string") | "protected_files.extra: entries must be strings" ]
                        end )
                  end
            else [] end;
        def git_errors:
            if has("git") then
                (.git) as $g
                | if ($g | type) != "object" then ["git: must be an object"]
                  else
                    [ $g | to_entries[] | select((.key | IN(git_keys[])) | not) | "git: unknown field \"\(.key)\"" ]
                    + [ $g | to_entries[] | select(.key | IN(git_bool_keys[])) | select((.value | type) != "boolean") | "git: \(.key) must be a boolean" ]
                    + ( if ($g | has("ai_branding")) then
                          ($g.ai_branding) as $b
                          | if ($b | type) != "object" then ["git: ai_branding must be an object"]
                            else
                              [ $b | keys[] | select(IN(brand_keys[]) | not) | "git: ai_branding: unknown field \"\(.)\"" ]
                              + [ brand_keys[] as $k | select($b | has($k))
                                  | if ($b[$k] | type) != "array" then "git: ai_branding.\($k) must be an array of strings"
                                    elif any($b[$k][]; type != "string" or length == 0) then "git: ai_branding.\($k) entries must be non-empty strings"
                                    else empty end ]
                            end
                        else [] end )
                  end
            else [] end;
        def att_errors:
            if has("attestation") then
                (.attestation) as $a
                | if ($a | type) != "object" then ["attestation: must be an object"]
                  else
                    [ $a | keys[] | . as $k | select((att_keys | index($k)) == null) | "attestation: unknown field \"\($k)\"" ]
                    + ( if ($a | has("enabled")) and (($a.enabled | type) != "boolean")
                          then ["attestation: enabled must be a boolean"]
                        else [] end )
                    + ( if ($a | has("max_records"))
                          and ( (($a.max_records | type) != "number")
                                or (($a.max_records | floor) != $a.max_records)
                                or ($a.max_records < 1) )
                          then ["attestation: max_records must be an integer >= 1"]
                        else [] end )
                    + ( if ($a | has("parity")) and ((parity_values | index($a.parity)) == null)
                          then ["attestation: invalid parity \"\($a.parity)\" (allowed: \(parity_values | join(", ")))"]
                        else [] end )
                  end
            else [] end;
        def spec_errors:
            if has("spec") then
                (.spec) as $s
                | if ($s | type) != "object" then ["spec: must be an object"]
                  else
                    [ $s | keys[] | . as $k | select((spec_keys | index($k)) == null) | "spec: unknown field \"\($k)\"" ]
                    + ( if ($s | has("enabled")) and (($s.enabled | type) != "boolean")
                          then ["spec: enabled must be a boolean"]
                        else [] end )
                    + ( if ($s | has("severity")) and ((spec_sev_values | index($s.severity)) == null)
                          then ["spec: invalid severity \"\($s.severity)\" (allowed: \(spec_sev_values | join(", ")))"]
                        else [] end )
                    + ( if ($s | has("include")) then
                          if (($s.include | type) != "array")
                            then ["spec: include must be an array of strings"]
                          else [ $s.include[] | select(type != "string") | "spec: include entries must be strings" ]
                          end
                        else [] end )
                    + ( if ($s | has("exclude")) then
                          if (($s.exclude | type) != "array")
                            then ["spec: exclude must be an array of strings"]
                          else [ $s.exclude[] | select(type != "string") | "spec: exclude entries must be strings" ]
                          end
                        else [] end )
                    + ( if ($s | has("timeout_s"))
                          and ( (($s.timeout_s | type) != "number")
                                or (($s.timeout_s | floor) != $s.timeout_s)
                                or ($s.timeout_s < 1) )
                          then ["spec: timeout_s must be an integer >= 1"]
                        else [] end )
                  end
            else [] end;
        def ext_errors:
            if has("extends") then
                (.extends) as $e
                | if ($e | type) != "object" then ["extends: must be an object"]
                  else
                    [ $e | keys[] | . as $k | select((ext_keys | index($k)) == null) | "extends: unknown field \"\($k)\"" ]
                    + ( if ($e | has("source")) | not then ["extends: source is required"]
                        elif ($e.source | type) != "string" or ($e.source | length) == 0
                          then ["extends: source must be a non-empty string"]
                        else [] end )
                    + ( if ($e | has("version")) | not then ["extends: version is required"]
                        elif ($e.version | type) != "string" or ($e.version | length) == 0
                          then ["extends: version must be a non-empty string"]
                        else [] end )
                    + ( if ($e | has("file")) and (($e.file | type) != "string" or ($e.file | length) == 0)
                          then ["extends: file must be a non-empty string"]
                        else [] end )
                  end
            else [] end;
        (pf_errors + git_errors + att_errors + spec_errors + ext_errors) | .[]
    ' "$file" 2>/dev/null)"
    if [[ -n "$section_errors" ]]; then
        errors="${errors:+$errors$'\n'}$section_errors"
    fi

    if [[ -n "$errors" ]]; then
        echo "ERROR: policy validation failed in $file:" >&2
        printf '%s\n' "$errors" | sed 's/^/  - /' >&2
        return 5
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    case "${1:-}" in
        get)
            shift
            gates_policy_get "$@"
            ;;
        list)
            shift
            gates_policy_list "$@"
            ;;
        validate)
            shift
            gates_validate_policy "$@"
            ;;
        *)
            cat >&2 <<'USAGE'
Usage: policy.sh <command> [args]
Commands:
  get <hook> <field>       Read scalar field from .specify/gates/policy.json
  list <hook> <field>      Read array field, one element per line
  validate [path]          Validate policy (default: resolved policy path)
USAGE
            exit 1
            ;;
    esac
fi
