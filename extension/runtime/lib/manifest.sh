#!/usr/bin/env bash
# manifest.sh -- what projection wrote, and what changed since.
#
# Usage (sourced; bash 3.2, no associative arrays):
#   gates_sha256 <file>                    # 64-hex hash (lib/attest.sh); fails if no tool
#   gates_version_cmp <a> <b>              # prints -1, 0 or 1
#   gates_projection_table <runtime> <0|1> # "<src-rel>\t<target-rel>" lines
#   gates_is_exec_target <target-rel>      # 0 if the target needs +x
#   gates_manifest_load <root>             # sets GATES_MANIFEST_* (below)
#   gates_manifest_hash <target-rel>       # hash recorded for a path
#   gates_manifest_write <root> <version>  # "<hash>  <path>" lines on stdin
#   gates_holds_load <root>                # sets GATES_HOLDS (paths only)
#   gates_is_held <target-rel>
#   gates_known_match <target-rel> <hash>  # 0 if a released version had it
#   gates_holds_ci <root>                  # acknowledged CI step ids (ci:<id>)
#   gates_ci_step_re <id>                  # a template step's regex; empty if unknown
#   gates_ci_candidates <root>             # every pipeline file, gates or not
#   gates_ci_live <file>                   # the file minus comments and disabled steps
#   gates_ci_files <root>                  # pipeline files running the gates; 1 if none
#   gates_ci_body <root>                   # live text of those files
#   gates_ci_present <root>                # template step ids those files run
#   gates_ci_missing <root>                # template step ids those files lack
#   gates_classify <root> <src-abs> <target-rel>
#       absent | upstream | pristine | edited | held
#
# Formats: specs/005-upgrade-safe-projection/data-model.md.
# GATES_MANIFEST_STATUS is absent, ok, or corrupt (with GATES_MANIFEST_ERROR).
# GATES_KNOWN_FILE (set by the caller) is lib/known-releases.sha256 of the
# extension doing the projection; empty or missing means no fallback.

# shellcheck disable=SC2034   # library file; the GATES_* globals are read by callers

GATES_MANIFEST_REL=".specify/gates/.projected.sha256"
GATES_HOLDS_REL=".specify/gates/.upgrade-holds"
GATES_LOCAL_REL=".specify/gates/hooks.local.d"

# gates_sha256 comes from lib/attest.sh (one implementation: sha256sum, then
# shasum -a 256, else fail).
if ! declare -f gates_sha256 >/dev/null 2>&1; then
    # shellcheck source=/dev/null disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/attest.sh"
fi

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
        install-shellcheck.sh shellcheck.sha256 policy.schema.json; do
        [[ -f "$src/$n" ]] && printf '%s\t%s\n' "$n" ".specify/gates/$n"
    done
    for f in "$src"/lib/*.sh; do
        [[ -f "$f" ]] || continue
        n="${f##*/}"
        printf 'lib/%s\t.specify/gates/lib/%s\n' "$n" "$n"
    done
    for n in pre-commit pre-merge-commit commit-msg stub.sh; do
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
    if ! grep -qE '^[0-9]+(\.[0-9]+)*$' <<<"$GATES_MANIFEST_VERSION"; then
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
    grep -qxF -- "$1" <<<"$GATES_HOLDS"
}

GATES_KNOWN_FILE="${GATES_KNOWN_FILE:-}"

# A projected file whose content some released version shipped was never
# edited locally. This is how a project without a manifest (projected by
# 0.3.x) upgrades without every changed file reading as a local edit.
gates_known_match() { # <target-rel> <hash>
    [[ -n "$GATES_KNOWN_FILE" && -f "$GATES_KNOWN_FILE" ]] || return 1
    awk -F '\t' -v p="$1" -v h="$2" '$2 == h && $3 == p { found = 1; exit } END { exit !found }' \
        "$GATES_KNOWN_FILE"
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
    # No record for this path (no manifest yet, or the path was not
    # projected last time): a released version's content is pristine too.
    if [[ -z "$rec" ]] && gates_known_match "$rel" "$cur"; then
        echo pristine
        return 0
    fi
    echo edited
}

gates_holds_ci() { # <root>
    local file="$1/$GATES_HOLDS_REL"
    [[ -f "$file" ]] || return 0
    sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$file" \
        | sed -n 's/^ci://p'
}

# CI-template drift (#70, research R6): the shipped templates' steps,
# identified by the command each runs, so a pipeline adapted by hand on any
# platform is still recognized. <id>\t<extended regex>.
gates_ci_steps() {
    printf 'gates\tverify\\.sh[[:space:]]+--boundary[[:space:]]+ci\n'
    printf 'canary\tcanary\\.sh\n'
    printf 'pr\tpr-check\\.sh\n'
}

# The regex of one template step id; empty for an id the template lacks.
gates_ci_step_re() { # <id>
    gates_ci_steps | awk -F '\t' -v id="$1" '$1 == id { print $2 }'
}

# Every pipeline file a supported platform reads, gates or not.
gates_ci_candidates() { # <root>
    local root="$1" f
    for f in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml \
        "$root"/.gitlab-ci.yml "$root"/*.gitlab-ci.yml "$root"/Jenkinsfile*; do
        [[ -f "$f" ]] && printf '%s\n' "${f#"$root"/}"
    done
    return 0
}

# The part of a pipeline file that runs (#139): comments removed (YAML `#`;
# Groovy `//` and `/* */` in a Jenkinsfile), and in YAML every step or job
# whose `if:` is literally false (`if: false`, `if: ${{ false }}`,
# `if: false && ...`) dropped with its whole block. A step disabled by moving
# its command into a comment (`run: "true"  # bash ...`) is then left without
# the command. A comment marker needs a blank or the line start before it,
# so `https://` and `dist/*` stay intact.
gates_ci_live() { # <file>
    case "${1##*/}" in
        Jenkinsfile*)
            awk '
                {
                    s = $0; out = ""
                    while (1) {
                        if (inc) {
                            p = index(s, "*/")
                            if (!p) { s = ""; break }
                            s = substr(s, p + 2); inc = 0; continue
                        }
                        q = match(s, /(^|[ \t])\/\//) ? RSTART : 0
                        p = match(s, /(^|[ \t])\/\*/) ? RSTART : 0
                        if (q && (!p || q < p)) { out = out substr(s, 1, q - 1); break }
                        if (p) { out = out substr(s, 1, p - 1) " "; s = substr(s, p + RLENGTH); inc = 1; continue }
                        out = out s; break
                    }
                    print out
                }' "$1"
            ;;
        *)
            awk '
                function indent(s) { return match(s, /[^ \t]/) ? RSTART - 1 : -1 }
                /^[ \t]*#/ { next }
                { sub(/[ \t]+#.*$/, ""); n++; line[n] = $0 }
                END {
                    for (i = 1; i <= n; i++) {
                        if (line[i] !~ /^[ \t]*(-[ \t]+)?if:[ \t]*["\047]?(\$\{\{[ \t]*)?false[ \t]*(&&|\}\}|["\047]|$)/) continue
                        c = match(line[i], /if:/) - 1
                        start = 0; base = -1
                        # The node the if: belongs to: the list item whose
                        # content starts in its column, or the mapping key
                        # it is indented under.
                        for (j = i; j >= 1; j--) {
                            if (match(line[j], /^[ \t]*-[ \t]+/) && RLENGTH == c) {
                                start = j; base = indent(line[j]); break
                            }
                            d = indent(line[j])
                            if (j < i && d >= 0 && d < c) { start = j; base = d; break }
                        }
                        if (!start) continue
                        for (k = start; k <= n; k++) {
                            if (k > start) { d = indent(line[k]); if (d >= 0 && d <= base) break }
                            drop[k] = 1
                        }
                    }
                    for (i = 1; i <= n; i++) if (!drop[i]) print line[i]
                }' "$1"
            ;;
    esac
}

# Pipeline files that run the gates (a live `gates` step). A step may live
# in any of them, so drift is judged over their union.
gates_ci_files() { # <root>
    local root="$1" f found=1 re
    re="$(gates_ci_step_re gates)"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if grep -qE "$re" <<<"$(gates_ci_live "$root/$f")"; then
            printf '%s\n' "$f"
            found=0
        fi
    done <<<"$(gates_ci_candidates "$root")"
    return "$found"
}

# The live text of every gates pipeline, one after the other; empty if none.
gates_ci_body() { # <root>
    local root="$1" files f
    files="$(gates_ci_files "$root")" || return 0
    while IFS= read -r f; do
        gates_ci_live "$root/$f"
    done <<<"$files"
}

# Template step ids the gates pipelines run.
gates_ci_present() { # <root>
    local body id re
    body="$(gates_ci_body "$1")"
    [[ -n "$body" ]] || return 0
    while IFS=$'\t' read -r id re; do
        [[ -n "$id" ]] || continue
        if grep -qE "$re" <<<"$body"; then printf '%s\n' "$id"; fi
    done < <(gates_ci_steps)
    return 0
}

gates_ci_missing() { # <root>
    local root="$1" id re acks present
    gates_ci_files "$root" >/dev/null || return 0
    acks="$(gates_holds_ci "$root")"
    present="$(gates_ci_present "$root")"
    while IFS=$'\t' read -r id re; do
        [[ -n "$id" ]] || continue
        [[ -n "$present" ]] && grep -qxF "$id" <<<"$present" && continue
        if [[ -z "$acks" ]] || ! grep -qxF "$id" <<<"$acks"; then
            printf '%s\n' "$id"
        fi
    done < <(gates_ci_steps)
}
