#!/bin/bash
# shellcheck shell=bash
# Shared formatter dispatch library.
# Sourced by post-edit.sh and format-changed.sh.
#
# Defines:
#   format_file <abs_path>         -- run the right formatter for $abs_path
#   find_prettier_root <abs_path>  -- locate nearest package.json
#
# INFRA-019:
#   - The caller must source policy.sh before sourcing this file if it
#     wants policy-driven exclude filtering. When the loader is unavailable
#     (missing-policy fallback path -- ADR-006), format_file still runs but
#     skips exclude filtering, matching alpha.11 behavior.
#   - format_file consults each tool's exclude list (prettier, markdownlint,
#     and shell scope) before invoking the underlying tool and short-circuits
#     silently if the project-relative path matches any glob.
#   - Globs use bash `[[ == pattern ]]` semantics. The helper normalizes
#     `**/` (leading) and `/**` (trailing) so policy conventions like
#     `**/node_modules/**` match a top-level `node_modules/foo.sh`.

find_prettier_root() {
    local file_path="$1"
    local dir
    dir=$(dirname "$file_path")
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/package.json" ]]; then
            echo "$dir"
            return 0
        fi
        # Stop at git root -- never walk above the project
        if [[ -n "$git_root" && "$dir" == "$git_root" ]]; then
            break
        fi
        dir=$(dirname "$dir")
    done
    local project_root="$git_root"
    if [[ -n "$project_root" ]]; then
        for subdir in "" "frontend" "web" "client" "app"; do
            local candidate="$project_root"
            [[ -n "$subdir" ]] && candidate="$project_root/$subdir"
            if [[ -f "$candidate/package.json" ]]; then
                echo "$candidate"
                return 0
            fi
        done
    fi
    return 1
}

# Project-root resolution shared by exclude lookups.
_gates_dispatch_project_root() {
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
        printf '%s\n' "$CLAUDE_PROJECT_DIR"
        return 0
    fi
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Test a single path against a single glob using bash `[[ == ]]`.
# Normalizes `**/` (leading) and `/**` (trailing) so the common policy
# convention works without globstar (which `[[ == ]]` ignores anyway).
_gates_glob_match() {
    local path="$1" glob="$2"
    [[ -z "$glob" ]] && return 1
    # shellcheck disable=SC2053,SC2295  # intentional unquoted glob pattern
    if [[ $path == $glob ]]; then
        return 0
    fi
    # Strip a single trailing /** so `foo/**` also matches `foo/bar/baz`
    # via the `foo/*` form, not just descendants of `foo`.
    if [[ "$glob" == */\*\* ]]; then
        local trimmed="${glob%/\*\*}"
        # shellcheck disable=SC2053,SC2295
        if [[ $path == $trimmed/* || $path == "$trimmed" ]]; then
            return 0
        fi
    fi
    # `**/x` should match top-level `x` too (no leading slash).
    if [[ "$glob" == \*\*/* ]]; then
        local rest="${glob#\*\*/}"
        # shellcheck disable=SC2053,SC2295
        if [[ $path == $rest || $path == */$rest ]]; then
            return 0
        fi
    fi
    return 1
}

# Return 0 (excluded) if $path matches any exclude glob for $tool.
# Tries both the absolute and project-relative path so policy globs that
# omit a leading slash still work. Returns 1 (not excluded) when the policy
# loader is unavailable -- the caller's fallback path.
_gates_path_excluded_for_tool() {
    local tool="$1" abs_path="$2"
    if ! command -v gates_policy_list >/dev/null 2>&1; then
        return 1
    fi
    local project_root rel_path
    project_root="$(_gates_dispatch_project_root)"
    rel_path="$abs_path"
    if [[ -n "$project_root" && "$abs_path" == "$project_root/"* ]]; then
        rel_path="${abs_path#"$project_root"/}"
    fi
    local glob
    while IFS= read -r glob; do
        [[ -z "$glob" ]] && continue
        if _gates_glob_match "$rel_path" "$glob" \
            || _gates_glob_match "$abs_path" "$glob"; then
            return 0
        fi
    done < <(gates_policy_list "$tool" exclude 2>/dev/null || true)
    return 1
}

# Run a formatter command and return its exit code. Stderr is swallowed when
# GATES_FORMAT_VERBOSE is unset to keep hook output quiet under normal runs.
_gates_run_tool() {
    if [[ -n "${GATES_FORMAT_VERBOSE:-}" ]]; then
        "$@"
    else
        "$@" 2>/dev/null
    fi
}

# format_file <abs_path>
# Returns 0 on success, on exclude-skip, or when no formatter is installed
# for the extension. Returns nonzero only when a present formatter actually
# fails on the path. Callers that care about severity (format-changed,
# post-edit) check this rc; legacy callers can ignore it.
format_file() {
    local file_path="$1"
    [[ -z "$file_path" ]] && return 0
    [[ ! -f "$file_path" ]] && return 0

    local ext="${file_path##*.}"
    local rc=0

    case "$ext" in
        ts | tsx | js | jsx | json | css | html | md | yaml | yml)
            # Prettier handles all of the above. .md additionally goes
            # through the markdownlint exclude list -- the two overlap.
            if _gates_path_excluded_for_tool prettier "$file_path"; then
                return 0
            fi
            if [[ "$ext" == "md" ]] \
                && _gates_path_excluded_for_tool markdownlint "$file_path"; then
                return 0
            fi
            if PRETTIER_ROOT=$(find_prettier_root "$file_path"); then
                if command -v npx >/dev/null 2>&1; then
                    _gates_run_tool npx --prefix "$PRETTIER_ROOT" prettier \
                        --write "$file_path" || rc=$?
                fi
            elif command -v prettier >/dev/null 2>&1; then
                _gates_run_tool prettier --write "$file_path" || rc=$?
            fi
            ;;
        py)
            if command -v ruff >/dev/null 2>&1; then
                _gates_run_tool ruff format "$file_path" || rc=$?
                _gates_run_tool ruff check --fix "$file_path" || rc=$?
            elif command -v black >/dev/null 2>&1; then
                _gates_run_tool black "$file_path" || rc=$?
            elif command -v autopep8 >/dev/null 2>&1; then
                _gates_run_tool autopep8 --in-place "$file_path" || rc=$?
            fi
            ;;
        rs)
            if command -v rustfmt >/dev/null 2>&1; then
                _gates_run_tool rustfmt "$file_path" || rc=$?
            fi
            ;;
        sh)
            # Shellcheck excludes also gate the .sh formatter pass: the
            # user's intent on the exclude list is "leave that file alone."
            # shfmt is a formatter rather than a linter, but the exclude
            # list is the single source of truth for shell scope.
            if _gates_path_excluded_for_tool shellcheck "$file_path"; then
                return 0
            fi
            if command -v shfmt >/dev/null 2>&1; then
                _gates_run_tool shfmt -w "$file_path" || rc=$?
            fi
            ;;
        go)
            if command -v gofmt >/dev/null 2>&1; then
                _gates_run_tool gofmt -w "$file_path" || rc=$?
            fi
            ;;
        rb)
            if command -v rubocop >/dev/null 2>&1; then
                _gates_run_tool rubocop -a "$file_path" || rc=$?
            fi
            ;;
        java | kt)
            if command -v google-java-format >/dev/null 2>&1; then
                _gates_run_tool google-java-format --replace "$file_path" || rc=$?
            fi
            ;;
    esac

    return "$rc"
}
