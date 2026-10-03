#!/usr/bin/env bash
# manifest.sh -- what projection wrote, and what changed since.
#
# Usage (sourced; bash 3.2, no associative arrays):
#   gates_sha256 <file>                    # 64-hex hash; return 2 if no tool
#   gates_version_cmp <a> <b>              # prints -1, 0 or 1
#   gates_projection_table <runtime> <0|1> # "<src-rel>\t<target-rel>" lines
#   gates_is_exec_target <target-rel>      # 0 if the target needs +x
#   gates_manifest_load <root>             # sets GATES_MANIFEST_* (below)
#   gates_manifest_hash <target-rel>       # hash recorded for a path
#   gates_manifest_write <root> <version>  # "<hash>  <path>" lines on stdin
#   gates_holds_load <root>                # sets GATES_HOLDS (paths only)
#   gates_is_held <target-rel>
#   gates_classify <root> <src-abs> <target-rel>
#       absent | upstream | pristine | edited | held
#
# Formats: specs/005-upgrade-safe-projection/data-model.md.
# GATES_MANIFEST_STATUS is absent, ok, or corrupt (with GATES_MANIFEST_ERROR).

# shellcheck disable=SC2034   # library file; the GATES_* globals are read by callers

GATES_MANIFEST_REL=".specify/gates/.projected.sha256"
GATES_HOLDS_REL=".specify/gates/.upgrade-holds"
GATES_LOCAL_REL=".specify/gates/hooks.local.d"

gates_sha256() { # <file>
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum "$1")" || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 "$1")" || return 1
    else
        return 2
    fi
    printf '%s\n' "${out%% *}"
}

gates_version_cmp() { # <a> <b>
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            if ((x[i] + 0) < (y[i] + 0)) { print -1; exit }
            if ((x[i] + 0) > (y[i] + 0)) { print 1; exit }
        }
        print 0
    }'
}

# The projection table: every file projection owns, as source paths relative
# to the extension's runtime/ directory and targets relative to the project.
# lib/*.sh and the agent hooks are enumerated from the source, so a new
# library ships without a table edit.
gates_projection_table() { # <runtime-dir> <agent-hooks:0|1>
    local src="$1" agent="${2:-1}" f n
    for n in verify.sh doctor.sh canary.sh contract.sh constitution.sh pr-check.sh project.sh \
        policy.schema.json; do
        [[ -f "$src/$n" ]] && printf '%s\t%s\n' "$n" ".specify/gates/$n"
    done
    for f in "$src"/lib/*.sh; do
        [[ -f "$f" ]] || continue
        n="${f##*/}"
        printf 'lib/%s\t.specify/gates/lib/%s\n' "$n" "$n"
    done
    for n in pre-commit commit-msg stub.sh; do
        [[ -f "$src/hooks/git/$n" ]] && printf 'hooks/git/%s\t.specify/gates/hooks/%s\n' "$n" "$n"
    done
    if [[ "$agent" == "1" ]]; then
        for f in "$src"/hooks/claude/*.sh; do
            [[ -f "$f" ]] || continue
            n="${f##*/}"
            printf 'hooks/claude/%s\t.claude/hooks/gates/%s\n' "$n" "$n"
        done
    fi
    return 0
}

gates_is_exec_target() { # <target-rel>
    case "$1" in
        *.sh | .specify/gates/hooks/*) return 0 ;;
    esac
    return 1
}

GATES_MANIFEST_STATUS=absent
GATES_MANIFEST_VERSION=""
GATES_MANIFEST_BODY=""
GATES_MANIFEST_ERROR=""

gates_manifest_load() { # <root>
    local file="$1/$GATES_MANIFEST_REL" header bad
    GATES_MANIFEST_STATUS=absent
    GATES_MANIFEST_VERSION=""
    GATES_MANIFEST_BODY=""
    GATES_MANIFEST_ERROR=""
    [[ -e "$file" ]] || return 0
    GATES_MANIFEST_STATUS=corrupt
    if [[ ! -r "$file" ]]; then
        GATES_MANIFEST_ERROR="not readable"
        return 0
    fi
    header="$(head -n 1 "$file")"
    case "$header" in
        "# spec-gates-manifest v1 version="[0-9]*) ;;
        *)
            GATES_MANIFEST_ERROR="missing or unknown header (line 1)"
            return 0
            ;;
    esac
    GATES_MANIFEST_VERSION="${header#\# spec-gates-manifest v1 version=}"
    if ! printf '%s' "$GATES_MANIFEST_VERSION" | grep -qE '^[0-9]+(\.[0-9]+)*$'; then
        GATES_MANIFEST_ERROR="unparseable version in the header"
        return 0
    fi
    # Entries: 64 hex, two spaces, a path inside the projected trees, no "..".
    # No {64} interval: BSD awk and mawk do not all support it.
    bad="$(tail -n +2 "$file" | awk '
        $0 ~ /^[0-9a-f]+  [^ ]+$/ && length($1) == 64 && $2 !~ /\.\./ \
            && ($2 ~ /^\.specify\/gates\// || $2 ~ /^\.claude\/hooks\/gates\//) { next }
        { print NR + 1; exit }')"
    if [[ -n "$bad" ]]; then
        GATES_MANIFEST_ERROR="malformed entry on line $bad"
        return 0
    fi
    GATES_MANIFEST_BODY="$(tail -n +2 "$file")"
    GATES_MANIFEST_STATUS=ok
}

gates_manifest_hash() { # <target-rel>
    [[ -n "$GATES_MANIFEST_BODY" ]] || return 0
    printf '%s\n' "$GATES_MANIFEST_BODY" | awk -v p="$1" '$2 == p { print $1; exit }'
}

gates_manifest_write() { # <root> <version>; entries on stdin
    local file="$1/$GATES_MANIFEST_REL" tmp
    tmp="$file.tmp.$$"
    {
        printf '# spec-gates-manifest v1 version=%s\n' "$2"
        sort -k2
    } >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$file"
}

GATES_HOLDS=""

gates_holds_load() { # <root>
    local file="$1/$GATES_HOLDS_REL"
    GATES_HOLDS=""
    [[ -f "$file" ]] || return 0
    GATES_HOLDS="$(sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$file" \
        | grep -v '^$' | grep -v '^ci:' || true)"
}

gates_is_held() { # <target-rel>
    [[ -n "$GATES_HOLDS" ]] || return 1
    printf '%s\n' "$GATES_HOLDS" | grep -qxF -- "$1"
}

gates_classify() { # <root> <src-abs> <target-rel>
    local root="$1" src="$2" rel="$3" tgt cur rec
    tgt="$root/$rel"
    case "$rel" in
        "$GATES_LOCAL_REL"/*) echo local; return 0 ;;
    esac
    if gates_is_held "$rel"; then
        echo held
        return 0
    fi
    rec="$(gates_manifest_hash "$rel")"
    if [[ ! -e "$tgt" ]]; then
        # Deleted after projection is a local change, not a fresh install.
        if [[ -n "$rec" ]]; then echo edited; else echo absent; fi
        return 0
    fi
    if cmp -s "$src" "$tgt"; then
        echo upstream
        return 0
    fi
    cur="$(gates_sha256 "$tgt")" || return 2
    if [[ -n "$rec" && "$cur" == "$rec" ]]; then
        echo pristine
        return 0
    fi
    echo edited
}
