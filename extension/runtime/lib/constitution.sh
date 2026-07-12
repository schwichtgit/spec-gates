#!/usr/bin/env bash
# constitution.sh (lib) -- constitution as an enforceable contract (feature 004).
#
# The pure parsing/detection core. No side effects, no network: every
# function here reads files and writes stdout only. Sourced by the projected
# constitution.sh entry script and by doctor.sh. Surface-activity evaluation
# (align/check) is layered on top in the same file (see the SURFACE section).
#
# Provides (foundational core, T002):
#   gates_const_fm_field <frag> <key>      # one frontmatter value (double-quotes stripped)
#   gates_const_fm_tags <frag>             # tags array, one per line
#   gates_const_fm_body <frag>             # markdown body after the frontmatter
#   gates_const_manifest_tier <man> <tier> # fragment ids in a manifest tier
#   gates_const_parse <constitution>       # PRINCIPLE / MALFORMED TSV protocol
#   gates_const_detect <constitution> [tpl]# absent | placeholder | filled
#
# All bash 3.2 + jq + BSD awk/sed. No interval regexes, no gensub, no
# associative arrays -- the macOS base toolchain is the floor.

# shellcheck disable=SC2034   # library file; helpers consumed by callers

# The fixed v1 surface set (contracts/annotation-format.md).
GATES_CONST_SURFACES="policy agent-hook git-hook ci accept scanner prose"

# Is <surface> one of the v1 set?
gates_const_is_surface() { # <surface>
    case " $GATES_CONST_SURFACES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# --- Fragment frontmatter (contracts/annotation-format.md) --------------------

# Value of a single frontmatter key from the leading `---`..`---` block. One
# layer of surrounding double quotes is stripped (the corpus quotes strings).
# Empty when the file has no frontmatter or the key is absent.
gates_const_fm_field() { # <fragment> <key>
    local file="${1:-}" key="${2:-}"
    [[ -f "$file" && -n "$key" ]] || return 0
    awk -v key="$key" '
        NR == 1 && $0 != "---" { exit }
        NR == 1 { infm = 1; next }
        infm && $0 == "---" { exit }
        infm {
            idx = index($0, ":")
            if (idx == 0) next
            k = substr($0, 1, idx - 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k != key) next
            v = substr($0, idx + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
            print v
            exit
        }
    ' "$file"
}

# The `tags: [a, b, c]` frontmatter array, one tag per line.
gates_const_fm_tags() { # <fragment>
    local raw
    raw="$(gates_const_fm_field "${1:-}" tags)"
    [[ -z "$raw" ]] && return 0
    raw="${raw#\[}"
    raw="${raw%\]}"
    printf '%s\n' "$raw" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

# The markdown body: everything after the closing frontmatter `---`, with a
# single leading blank line trimmed so drafts assemble deterministically.
gates_const_fm_body() { # <fragment>
    local file="${1:-}"
    [[ -f "$file" ]] || return 0
    awk '
        NR == 1 && $0 != "---" { print; body = 1; next }
        NR == 1 { infm = 1; next }
        infm && $0 == "---" { infm = 0; body = 1; started = 0; next }
        infm { next }
        body {
            if (!started && $0 ~ /^[[:space:]]*$/) next
            started = 1
            print
        }
    ' "$file"
}

# --- Manifest (corpus registry) ----------------------------------------------

# Fragment ids listed under a manifest tier. tier is mandatory|recommended|
# optional; the manifest keys are `<tier>_fragments:` (charter-compatible).
gates_const_manifest_tier() { # <manifest> <tier>
    local manifest="${1:-}" tier="${2:-}"
    [[ -f "$manifest" && -n "$tier" ]] || return 0
    awk -v want="${tier}_fragments" '
        /^[a-z_]+:/ {
            key = $0
            sub(/:.*/, "", key)
            cur = (key == want) ? 1 : 0
            next
        }
        cur && /^[ \t]*-[ \t]+/ {
            v = $0
            sub(/^[ \t]*-[ \t]+/, "", v)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
            print v
        }
    ' "$manifest"
}

# --- Annotation parser (contracts/annotation-format.md) ----------------------

# Parse a constitution into principles and their enforcement markers. A
# principle is an `### ` (h3) heading; markers bind to the principle they fall
# under (up to the next h2/h3). Emits TAB-separated protocol lines:
#
#   PRINCIPLE<TAB><heading-line><TAB><name><TAB><surface><TAB><ref><TAB><expect>
#       an empty <surface> means the principle is unannotated (legal, FR-013).
#   MALFORMED<TAB><line><TAB><name-or-dash><TAB><message>
#       a fail-closed marker error; callers name constitution.md:<line>.
#
# Marker grammar rules (annotation-format.md): exactly one `gates:enforce`
# per principle (a second is MALFORMED); `surface=` required from the fixed
# set; `ref=` required unless `surface=prose`; unknown keys or `=`-less tokens
# are MALFORMED; a marker before any principle is MALFORMED with name "-".
# HTML comments without `gates:enforce` (e.g. the Sync Impact Report) are
# ignored (grammar rule 1).
gates_const_parse() { # <constitution>
    local file="${1:-}"
    [[ -f "$file" ]] || return 0
    awk '
    function is_surface(s) {
        return (s == "policy" || s == "agent-hook" || s == "git-hook" \
            || s == "ci" || s == "accept" || s == "scanner" || s == "prose")
    }
    function flush() {
        if (pline > 0) {
            printf "PRINCIPLE\t%d\t%s\t%s\t%s\t%s\n", \
                pline, pname, psurface, pref, pexpect
        }
    }
    BEGIN { pline = 0; pname = ""; psurface = ""; pref = ""; pexpect = ""; have = 0 }
    /^###[ \t]/ {
        flush()
        pline = NR
        h = $0; sub(/^###[ \t]+/, "", h); gsub(/[ \t]+$/, "", h)
        pname = h; psurface = ""; pref = ""; pexpect = ""; have = 0
        next
    }
    /^##[ \t]/ {
        flush()
        pline = 0; pname = ""; psurface = ""; pref = ""; pexpect = ""; have = 0
        next
    }
    (index($0, "gates:enforce") > 0 && index($0, "<!--") > 0) {
        m = $0
        sub(/^[^<]*<!--[ \t]*/, "", m)
        sub(/[ \t]*-->.*$/, "", m)
        gsub(/^[ \t]+|[ \t]+$/, "", m)
        n = split(m, tok, /[ \t]+/)
        if (tok[1] != "gates:enforce") next
        name = (pline > 0) ? pname : "-"
        if (have) {
            printf "MALFORMED\t%d\t%s\tsecond gates:enforce marker for one principle (at most one per principle)\n", NR, name
            next
        }
        have = 1
        if (pline == 0) {
            printf "MALFORMED\t%d\t%s\tgates:enforce marker before any principle heading\n", NR, name
            next
        }
        surface = ""; ref = ""; expect = ""; bad = ""
        for (i = 2; i <= n; i++) {
            kv = tok[i]
            eq = index(kv, "=")
            if (eq == 0) { bad = "unparseable token: " kv; break }
            k = substr(kv, 1, eq - 1); val = substr(kv, eq + 1)
            if (k == "surface") surface = val
            else if (k == "ref") ref = val
            else if (k == "expect") expect = val
            else { bad = "unknown key: " k; break }
        }
        if (bad != "") { printf "MALFORMED\t%d\t%s\t%s\n", NR, name, bad; next }
        if (surface == "") { printf "MALFORMED\t%d\t%s\tmissing surface=\n", NR, name; next }
        if (!is_surface(surface)) { printf "MALFORMED\t%d\t%s\tunknown surface: %s\n", NR, name, surface; next }
        if (surface != "prose" && ref == "") { printf "MALFORMED\t%d\t%s\tmissing ref= for surface=%s\n", NR, name, surface; next }
        psurface = surface; pref = ref; pexpect = expect
        next
    }
    END { flush() }
    ' "$file"
}

# --- Placeholder detection (R8, FR-014) --------------------------------------

# Classify a constitution for init and the session's mode choice:
#   absent       -- the file does not exist
#   placeholder  -- byte-equal to the shipped template, or carries a
#                   bracket-token signature (`[UPPER_SNAKE]`, 3+ chars)
#   filled       -- concrete content
gates_const_detect() { # <constitution> [<template>]
    local file="${1:-}" template="${2:-}"
    [[ -f "$file" ]] || {
        echo absent
        return 0
    }
    if [[ -n "$template" && -f "$template" ]] && cmp -s "$file" "$template"; then
        echo placeholder
        return 0
    fi
    if grep -Eq '\[[A-Z_][A-Z_][A-Z_]' "$file"; then
        echo placeholder
        return 0
    fi
    echo filled
}

# --- Draft assembly helpers (US1) --------------------------------------------

# Roman numeral for 1..39 (constitutions never have more principles).
gates_const_roman() { # <n>
    local n="${1:-0}" out="" i
    local rvals="10 9 5 4 1" rsyms="X IX V IV I"
    # shellcheck disable=SC2206  # deliberate word-split of fixed literals
    local -a rv=($rvals) rs=($rsyms)
    for i in 0 1 2 3 4; do
        while [[ "$n" -ge "${rv[$i]}" ]]; do
            out="$out${rs[$i]}"
            n=$((n - ${rv[$i]}))
        done
    done
    printf '%s' "$out"
}

# Title-case a hyphenated id segment: "no-secrets" -> "No Secrets".
gates_const_titlecase() { # <hyphenated>
    printf '%s' "${1:-}" | tr '-' ' ' \
        | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }'
}

# Build one enforcement marker from a surface decision.
gates_const_marker() { # <surface> <ref> <expect>
    local s="${1:-}" r="${2:-}" e="${3:-}"
    if [[ "$s" == "prose" ]]; then
        printf '<!-- gates:enforce surface=prose -->'
        return 0
    fi
    local m="<!-- gates:enforce surface=$s ref=$r"
    [[ -n "$e" ]] && m="$m expect=$e"
    printf '%s -->' "$m"
}

# --- fragments (candidate menu, US1) -----------------------------------------

# Filtered/ranked candidate menu for the interview profile. Emits TSV per
# contracts/cli-contracts.md: tier<TAB>id<TAB>statement<TAB>surface<TAB>ref<TAB>rationale.
# Mandatory tier first; within a tier, ranked by profile relevance (exact
# project-type match, then matched postures), ties in manifest order. A
# fragment carrying project-type tags that do not include the profile's type,
# and not tagged all-projects, is filtered out (a docs project never sees
# infra fragments); mandatory fragments are never filtered. Missing profile or
# corpus is a usage error (exit 1); a malformed manifest/fragment is exit 2.
gates_const_fragments() { # <corpus> <profile-json>
    local corpus="${1:-}" profile="${2:-}"
    [[ -d "$corpus" ]] || {
        echo "constitution: corpus directory not found: $corpus" >&2
        return 1
    }
    [[ -f "$profile" ]] || {
        echo "constitution: an interview profile is required (--profile); the menu is never unfiltered" >&2
        return 1
    }
    local manifest="$corpus/manifest.yml"
    [[ -f "$manifest" ]] || {
        echo "constitution: corpus has no manifest.yml: $corpus" >&2
        return 2
    }
    local ptype postures
    ptype="$(jq -r '.project_type // ""' "$profile" 2>/dev/null)" || {
        echo "constitution: profile is not valid JSON: $profile" >&2
        return 2
    }
    postures="$(jq -r '(.postures // [])[]' "$profile" 2>/dev/null)"
    local tab
    tab="$(printf '\t')"
    local tier
    for tier in mandatory recommended optional; do
        local tmp
        tmp="$(mktemp 2>/dev/null || mktemp -t gates-frag)" || return 1
        local id
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            local frag="$corpus/fragments/$id.md"
            [[ -f "$frag" ]] || {
                echo "constitution: manifest lists $id but $frag is missing" >&2
                rm -f "$tmp"
                return 2
            }
            local tags score=0 has_ptype=0 all_projects=0 matched=0 t bare
            tags="$(gates_const_fm_tags "$frag")"
            while IFS= read -r t; do
                [[ -z "$t" ]] && continue
                case "$t" in
                    all-projects) all_projects=1 ;;
                    project-type/*)
                        has_ptype=1
                        bare="${t#project-type/}"
                        if [[ "$bare" == "$ptype" ]]; then
                            matched=1
                            score=$((score + 2))
                        fi
                        ;;
                    posture/*)
                        bare="${t#posture/}"
                        if printf '%s\n' "$postures" | grep -qx "$bare"; then
                            score=$((score + 1))
                        fi
                        ;;
                esac
            done <<<"$tags"
            if [[ "$tier" != "mandatory" && "$has_ptype" == "1" \
                && "$all_projects" == "0" && "$matched" == "0" ]]; then
                continue
            fi
            local statement rationale surface ref
            statement="$(gates_const_fm_field "$frag" statement)"
            rationale="$(gates_const_fm_field "$frag" rationale)"
            surface="$(gates_const_fm_field "$frag" surface)"
            ref="$(gates_const_fm_field "$frag" ref)"
            printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$score" "$tier" "$id" "$statement" "$surface" "$ref" "$rationale" >>"$tmp"
        done < <(gates_const_manifest_tier "$manifest" "$tier")
        # Stable sort by score descending; drop the score column.
        sort -t"$tab" -k1,1nr -s "$tmp" | cut -f2-
        rm -f "$tmp"
    done
    return 0
}

# --- draft (assemble the annotated constitution, US1) ------------------------

# Resolve one selection (index $2 of the selections in $1) into NAME / BODY /
# MARKER / PRINCIPLE globals, validating the surface decision (FR-004). Returns
# 2 with a named cause on any contract failure.
_gates_const_resolve_sel() { # <selections-json> <index> <corpus>
    local sel="$1" i="$2" corpus="$3"
    local id surface ref expect
    id="$(jq -r ".selections[$i].id // \"\"" "$sel")"
    SEL_NAME="$(jq -r ".selections[$i].name // \"\"" "$sel")"
    surface="$(jq -r ".selections[$i].surface // \"\"" "$sel")"
    ref="$(jq -r ".selections[$i].ref // \"\"" "$sel")"
    expect="$(jq -r ".selections[$i].expect // \"\"" "$sel")"
    SEL_PRINCIPLE="$(jq -r ".selections[$i].principle // \"\"" "$sel")"
    SEL_BODY="$(jq -r ".selections[$i].body // \"\"" "$sel")"
    if [[ -z "$surface" ]]; then
        echo "constitution: selection $i carries no surface decision -- every principle must declare one (prose is an explicit choice)" >&2
        return 2
    fi
    if ! gates_const_is_surface "$surface"; then
        echo "constitution: selection $i has unknown surface '$surface'" >&2
        return 2
    fi
    if [[ "$surface" != "prose" && -z "$ref" ]]; then
        echo "constitution: selection $i (surface=$surface) needs a ref" >&2
        return 2
    fi
    if [[ -n "$id" ]]; then
        local frag="$corpus/fragments/$id.md"
        [[ -f "$frag" ]] || {
            echo "constitution: selection $i references unknown fragment '$id'" >&2
            return 2
        }
        [[ -z "$SEL_BODY" ]] && SEL_BODY="$(gates_const_fm_body "$frag")"
        [[ -z "$SEL_NAME" ]] && SEL_NAME="$(gates_const_titlecase "${id##*/}")"
    fi
    # An in-place annotation (augment) needs no body/name of its own.
    if [[ -z "$SEL_PRINCIPLE" ]]; then
        [[ -z "$SEL_NAME" ]] && {
            echo "constitution: selection $i (custom) needs a name" >&2
            return 2
        }
        [[ -z "$SEL_BODY" ]] && {
            echo "constitution: selection $i (custom) needs a body" >&2
            return 2
        }
    fi
    SEL_MARKER="$(gates_const_marker "$surface" "$ref" "$expect")"
    return 0
}

# Assemble the annotated constitution draft (contracts/cli-contracts.md).
# Deterministic: identical inputs produce byte-identical output. Writes only to
# <out>. In --augment mode existing content is preserved verbatim: selections
# with a `principle` field annotate the named existing heading in place (only
# if it is not already annotated), and selections without one are appended as
# new principles in Core Principles order.
gates_const_draft() { # <corpus> <selections-json> <out> [<augment-file>]
    local corpus="${1:-}" sel="${2:-}" out="${3:-}" augment="${4:-}"
    [[ -f "$sel" ]] || {
        echo "constitution: selections file not found: $sel" >&2
        return 1
    }
    [[ -n "$out" ]] || {
        echo "constitution: draft needs an --out path" >&2
        return 1
    }
    local n
    n="$(jq '.selections | length' "$sel" 2>/dev/null)" || {
        echo "constitution: selections is not valid JSON: $sel" >&2
        return 2
    }
    [[ "$n" -ge 1 ]] || {
        echo "constitution: no selections to draft" >&2
        return 2
    }
    local project
    project="$(jq -r '.project_name // "Project"' "$sel")"

    # Resolve every selection up front (fail closed before writing anything).
    local -a names=() bodies=() markers=() principles=()
    local i SEL_NAME SEL_BODY SEL_MARKER SEL_PRINCIPLE
    for ((i = 0; i < n; i++)); do
        _gates_const_resolve_sel "$sel" "$i" "$corpus" || return 2
        names+=("$SEL_NAME")
        bodies+=("$SEL_BODY")
        markers+=("$SEL_MARKER")
        principles+=("$SEL_PRINCIPLE")
    done

    local gov="This constitution supersedes other practice documents where they conflict.
Amendments are made by pull request that edits this file, records the change,
and is approved by the project's maintainers. Every review verifies compliance
with the principles above; the enforcement annotations bind each principle to
the boundary that proves it."

    if [[ -z "$augment" ]]; then
        # Fresh draft in the core template's section shape.
        {
            printf '# %s Constitution\n\n' "$project"
            printf '## Core Principles\n'
            local idx=0 roman
            for ((i = 0; i < n; i++)); do
                idx=$((idx + 1))
                roman="$(gates_const_roman "$idx")"
                printf '\n### %s. %s\n\n%s\n\n%s\n' \
                    "$roman" "${names[$i]}" "${markers[$i]}" "${bodies[$i]}"
            done
            printf '\n## Governance\n\n%s\n\n' "$gov"
            printf '**Version**: 0.0.0 | **Ratified**: pending | **Last Amended**: pending\n'
        } >"$out"
        return 0
    fi

    # Augment mode: annotate/append onto an existing constitution.
    [[ -f "$augment" ]] || {
        echo "constitution: --augment file not found: $augment" >&2
        return 1
    }
    # Which existing principles already carry a marker? (Do not double-annotate.)
    local annotated_tmp
    annotated_tmp="$(mktemp 2>/dev/null || mktemp -t gates-annot)" || return 1
    gates_const_parse "$augment" \
        | awk -F'\t' '$1 == "PRINCIPLE" && $4 != "" { print $3 }' >"$annotated_tmp"
    local existing_count
    existing_count="$(grep -c '^### ' "$augment" || true)"

    local markers_file newblock_file
    markers_file="$(mktemp 2>/dev/null || mktemp -t gates-mk)" || return 1
    newblock_file="$(mktemp 2>/dev/null || mktemp -t gates-nb)" || return 1
    : >"$markers_file"
    : >"$newblock_file"

    local k=0 roman
    for ((i = 0; i < n; i++)); do
        if [[ -n "${principles[$i]}" ]]; then
            # Annotate an existing heading in place, unless already annotated.
            if grep -qxF "${principles[$i]}" "$annotated_tmp"; then
                continue
            fi
            printf '%s\t%s\n' "${principles[$i]}" "${markers[$i]}" >>"$markers_file"
        else
            k=$((k + 1))
            roman="$(gates_const_roman $((existing_count + k)))"
            {
                printf '### %s. %s\n\n%s\n\n%s\n\n' \
                    "$roman" "${names[$i]}" "${markers[$i]}" "${bodies[$i]}"
            } >>"$newblock_file"
        fi
    done

    awk -v markersfile="$markers_file" -v newblockfile="$newblock_file" '
    BEGIN {
        while ((getline l < markersfile) > 0) {
            p = index(l, "\t")
            if (p > 0) mk[substr(l, 1, p - 1)] = substr(l, p + 1)
        }
        nb = ""
        while ((getline l < newblockfile) > 0) nb = nb l "\n"
        incore = 0; flushed = 0
    }
    /^## / {
        if (incore && !flushed) { printf "%s", nb; flushed = 1 }
        incore = ($0 ~ /^## Core Principles/) ? 1 : 0
        print; next
    }
    /^### / {
        print
        h = $0; sub(/^### +/, "", h); sub(/ +$/, "", h)
        if (h in mk) print mk[h]
        next
    }
    { print }
    END { if (incore && !flushed) printf "%s", nb }
    ' "$augment" >"$out"

    rm -f "$annotated_tmp" "$markers_file" "$newblock_file"
    return 0
}
