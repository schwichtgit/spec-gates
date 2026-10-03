#!/bin/bash
# shellcheck shell=bash
# Shared fixtures for the projection tests (sourced; bash 3.2).
#
#   fx_project            create a Spec Kit project with the extension
#                         installed (vendored copy of extension/ + a
#                         .registry entry) and a minimal policy; prints its
#                         directory. Nothing is projected yet.
#   fx_registry <dir> <v> rewrite the registry entry's version
#   fx_cleanup <dir>      remove a fixture

FX_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fx_project() {
    local d v
    d="$(mktemp -d 2>/dev/null || mktemp -d -t gates-fx)" || return 1
    d="$(cd "$d" && pwd -P)"
    (
        cd "$d" || exit 1
        git init -q . && git config user.email fx@example.invalid && git config user.name fx
        mkdir -p .specify/extensions/gates .specify/gates
        cp -R "$FX_REPO_ROOT/extension/extension.yml" "$FX_REPO_ROOT/extension/runtime" \
            "$FX_REPO_ROOT/extension/ci" "$FX_REPO_ROOT/extension/commands" .specify/extensions/gates/
        # Like Spec Kit's zip extraction: only *.sh keep the execute bit.
        chmod 644 .specify/extensions/gates/runtime/hooks/git/pre-commit \
            .specify/extensions/gates/runtime/hooks/git/commit-msg
        printf '{ "hooks": {} }\n' >.specify/gates/policy.json
    ) || return 1
    v="$(sed -n 's/^  version: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\} *$/\1/p' "$d/.specify/extensions/gates/extension.yml" | head -n 1)"
    fx_registry "$d" "$v"
    printf '%s\n' "$d"
}

fx_registry() { # <dir> <version>
    printf '{"schema_version":"1.0","extensions":{"gates":{"version":"%s","source":"local","enabled":true}}}\n' \
        "$2" >"$1/.specify/extensions/.registry"
}

fx_cleanup() { # <dir>
    # A coverage run keeps sandboxes: bashcov reports a traced script only
    # if the file still exists when the run ends (#98).
    [[ -n "${GATES_KEEP_TMP:-}" ]] && return 0
    [[ -n "${1:-}" && -d "$1" ]] && rm -rf "$1"
    return 0
}
