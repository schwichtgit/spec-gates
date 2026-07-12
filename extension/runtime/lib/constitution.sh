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
