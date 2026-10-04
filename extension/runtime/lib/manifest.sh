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
#   gates_ci_live <file>                   # the file minus comments and inert steps
#   gates_ci_files <root>                  # pipeline files running the gates; 1 if none
#   gates_ci_inert <root>                  # pipeline files calling verify.sh, none live
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
# platform is still recognized. <id>\t<extended regex>. The gates step is
# verify.sh with `--boundary ci` among its arguments, in any order (#171).
gates_ci_steps() {
    printf 'gates\tverify\\.sh[^|;&]*--boundary[[:space:]]+ci([^[:alnum:]_-]|$)\n'
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

# The platform a pipeline file belongs to: github, gitlab, jenkins or yaml.
_gates_ci_kind() { # <file>
    case "${1##*/}" in
        Jenkinsfile*) echo jenkins; return 0 ;;
        *gitlab-ci.yml) echo gitlab; return 0 ;;
    esac
    case "$1" in
        */.github/workflows/*) echo github ;;
        *) echo yaml ;;
    esac
}

# A pipeline file without its comments: YAML `#`; Groovy `//` and `/* */`
# in a Jenkinsfile. A comment marker needs a blank or the line start before
# it, so `https://` and `dist/*` stay intact.
_gates_ci_uncomment() { # <file>
    if [[ "$(_gates_ci_kind "$1")" == jenkins ]]; then
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
    else
        awk '/^[ \t]*#/ { next } { sub(/[ \t]+#.*$/, ""); print }' "$1"
    fi
}

# YAML nodes that never run, or whose failure is ignored, dropped with their
# whole block (stdin to stdout):
#   - a step or job whose `if:` is literally false (`if: false`,
#     `if: ${{ false }}`, `if: false && ...`);
#   - GitHub: `continue-on-error: true` on a step or job, and a workflow
#     whose every trigger is workflow_dispatch or schedule (never a push or
#     a pull request);
#   - GitLab: `allow_failure: true`, `when: manual|never` on the job or as
#     an unconditional first rule, and a hidden `.name:` job nothing
#     extends or aliases;
#   - the rest of a run block (`run: |`, a script list) after an
#     unconditional `exit 0` or `exit` line.
_gates_ci_yaml_drop() { # <kind>
    awk -v kind="$1" '
        function indent(s) { return match(s, /[^ \t]/) ? RSTART - 1 : -1 }
        function keycol(s) { match(s, /^[ \t]*(-[ \t]+)?/); return RLENGTH }
        function body(s) { sub(/^[ \t]*(-[ \t]+)?/, "", s); sub(/[ \t;]*$/, "", s); return s }
        # The node a key in column c belongs to: the list item whose content
        # starts in that column, or the mapping key it is indented under.
        # Sets NB to the node indent; 0 if there is none.
        function node(i, c,   j, d) {
            for (j = i; j >= 1; j--) {
                if (match(line[j], /^[ \t]*-[ \t]+/) && RLENGTH == c) { NB = indent(line[j]); return j }
                d = indent(line[j])
                if (j < i && d >= 0 && d < c) { NB = d; return j }
            }
            return 0
        }
        function drop_node(i, c,   s, k, d) {
            s = node(i, c)
            if (!s) return
            for (k = s; k <= n; k++) {
                if (k > s) { d = indent(line[k]); if (d >= 0 && d <= NB) break }
                drop[k] = 1
            }
        }
        # w appears on another line as a whole word (extends:, !reference,
        # an alias): a hidden job used that way runs as part of another.
        function used(w, i,   j, s, p, a, b) {
            for (j = 1; j <= n; j++) {
                if (j == i) continue
                s = line[j]
                while ((p = index(s, w)) > 0) {
                    a = p > 1 ? substr(s, p - 1, 1) : ""
                    b = substr(s, p + length(w), 1)
                    if (a !~ /[A-Za-z0-9_.-]/ && b !~ /[A-Za-z0-9_.-]/) return 1
                    s = substr(s, p + length(w))
                }
            }
            return 0
        }
        { n++; line[n] = $0 }
        END {
            if (kind == "github") {
                for (i = 1; i <= n; i++) if (line[i] ~ /^["\047]?on["\047]?:/) break
                if (i <= n) {
                    t = line[i]; sub(/^[^:]*:[ \t]*/, "", t)
                    m = 0
                    if (t != "") {
                        gsub(/\[/, " ", t); gsub(/\]/, " ", t); gsub(/[",\047]/, " ", t)
                        m = split(t, w, /[ \t]+/)
                    } else {
                        ci = -1
                        for (j = i + 1; j <= n; j++) {
                            d = indent(line[j])
                            if (d < 0) continue
                            if (d == 0) break
                            if (ci < 0) ci = d
                            if (d != ci) continue
                            t = body(line[j]); sub(/:.*$/, "", t); gsub(/["\047]/, "", t)
                            w[++m] = t
                        }
                    }
                    cnt = 0; runs = 0
                    for (k = 1; k <= m; k++) {
                        if (w[k] == "") continue
                        cnt++
                        if (w[k] != "workflow_dispatch" && w[k] != "schedule") runs = 1
                    }
                    if (cnt && !runs) exit
                }
            }
            for (i = 1; i <= n; i++) {
                s = line[i]; c = keycol(s)
                if (s ~ /^[ \t]*(-[ \t]+)?if:[ \t]*["\047]?(\$\{\{[ \t]*)?false[ \t]*(&&|\}\}|["\047]|$)/) { drop_node(i, c); continue }
                if (kind == "github" && s ~ /^[ \t]*(-[ \t]+)?continue-on-error:[ \t]*["\047]?(\$\{\{[ \t]*)?true[ \t]*(\}\})?[ \t]*["\047]?[ \t]*$/) { drop_node(i, c); continue }
                if (kind == "gitlab") {
                    if (s ~ /^[ \t]*(-[ \t]+)?allow_failure:[ \t]*true[ \t]*$/) { drop_node(i, c); continue }
                    if (s ~ /^[ \t]*(-[ \t]+)?when:[ \t]*["\047]?(manual|never)["\047]?[ \t]*$/) {
                        if (s !~ /^[ \t]*-/) { drop_node(i, c); continue }
                        # A rule of its own (no if:, changes:, exists:) first
                        # under rules: always matches, so the job never runs.
                        di = indent(s)
                        for (p = i - 1; p >= 1 && indent(line[p]) < 0; p--) ;
                        for (q = i + 1; q <= n && indent(line[q]) < 0; q++) ;
                        if (p >= 1 && line[p] ~ /^[ \t]*rules:[ \t]*$/ && indent(line[p]) <= di \
                            && (q > n || indent(line[q]) <= di)) drop_node(p, indent(line[p]))
                        continue
                    }
                    if (s ~ /^\.[^ \t:]*:/) {
                        nm = s; sub(/:.*$/, "", nm)
                        an = ""
                        if (match(s, /&[A-Za-z0-9_-]+/)) an = "*" substr(s, RSTART + 1, RLENGTH - 1)
                        if (!used(nm, i) && (an == "" || !used(an, i))) {
                            for (k = i; k <= n; k++) {
                                if (k > i && indent(line[k]) == 0) break
                                drop[k] = 1
                            }
                        }
                        continue
                    }
                }
                if (s !~ /^[ \t]*(-[ \t]+)?exit([ \t]+0)?[ \t;]*$/) continue
                # exit inside an if/for/case/function body, or near a heredoc,
                # is not shown to run unconditionally: leave the block alone.
                c = indent(s); item = (s ~ /^[ \t]*-/); depth = 0; here = 0
                for (j = i - 1; j >= 1; j--) {
                    d = indent(line[j])
                    if (d < 0) continue
                    if (d < c || (item && d == c && line[j] !~ /^[ \t]*-/)) break
                    b = body(line[j])
                    if (b ~ /<</) here = 1
                    if (b ~ /^(if|for|while|until|case|select)([ \t]|$)/ || b ~ /\{$/) depth++
                    if (b ~ /^(fi|done|esac|\})([ \t;]|$)/ || b ~ /;[ \t]*(fi|done|esac)$/) depth--
                }
                if (depth > 0 || here) continue
                for (k = i + 1; k <= n; k++) {
                    d = indent(line[k])
                    if (d >= 0 && (d < c || (item && d == c && line[k] !~ /^[ \t]*-/))) break
                    drop[k] = 1
                }
            }
            for (i = 1; i <= n; i++) if (!drop[i]) print line[i]
        }'
}

# A Jenkinsfile stage whose `when` is literally false
# (`when { expression { false } }`, or `return false`) never runs: blanked
# from its opening to its closing brace (stdin to stdout).
_gates_ci_jenkins_drop() {
    awk '
        { t = t $0 "\n" }
        END {
            L = length(t); sp = 0; last = 0
            for (i = 1; i <= L; i++) {
                ch = substr(t, i, 1)
                if (ch == "{") {
                    head[i] = substr(t, last + 1, i - last - 1)
                    up[i] = sp ? st[sp] : 0
                    st[++sp] = i; last = i
                } else if (ch == "}") {
                    if (sp) { cl[st[sp]] = i; sp-- }
                    last = i
                }
            }
            any = 0
            for (p in head) {
                if (!(p in cl) || head[p] !~ /(^|[^A-Za-z0-9_])when[ \t\n]*$/) continue
                b = substr(t, p + 1, cl[p] - p - 1); gsub(/[ \t\n;]+/, "", b)
                if (b != "expression{false}" && b != "expression{returnfalse}") continue
                for (q = up[p]; q; q = up[q])
                    if (head[q] ~ /(^|[^A-Za-z0-9_])stage[ \t\n]*\([^)]*\)[ \t\n]*$/) break
                if (q && (q in cl)) { for (k = q; k <= cl[q]; k++) cut[k] = 1; any = 1 }
            }
            if (!any) { printf "%s", t; exit }
            out = ""
            for (i = 1; i <= L; i++) {
                ch = substr(t, i, 1)
                if (ch == "\n") { print out; out = ""; continue }
                out = out ((i in cut) ? " " : ch)
            }
        }'
}

# Shell command segments (split at ; && || |) that cannot enforce, removed
# from each line (stdin to stdout): text an `echo` or `printf` prints, a
# command with `--dry-run`, one whose failure `|| true`, `|| :`,
# `|| exit 0` or `|| echo` swallows, and everything after an unconditional
# `exit 0` on the same line. A YAML key (`run:`) or a Jenkins `sh '` in
# front of the first command is kept as is; a Jenkins `sh` step with
# `returnStatus: true` never fails the build and is dropped.
_gates_ci_segments() { # <kind>
    awk -v kind="$1" '
        function word(s) {
            while (match(s, /^[ \t]+/) || match(s, /^["\047({!]/) \
                || match(s, /^(then|do|else|time)[ \t]+/) \
                || match(s, /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/)) s = substr(s, RLENGTH + 1)
            match(s, /^[^ \t"\047;)}]*/)
            return substr(s, 1, RLENGTH)
        }
        # The fallback after || runs instead of failing: true, :, exit 0, or
        # a message (a { ...; exit 1; } group still fails).
        function swallows(s,   w) {
            if (s ~ /^[ \t]*[({]/) return 0
            w = word(s)
            return w == "true" || w == ":" || w == "echo" || w == "printf" \
                || s ~ /^[ \t({"\047]*exit[ \t]+0([^0-9]|$)/
        }
        {
            s = $0; pre = ""
            if (kind == "jenkins") {
                if (s ~ /returnStatus[ \t]*:[ \t]*true/) { print ""; next }
                if (match(s, /(^|[^A-Za-z0-9_.])(sh|bat|powershell|pwsh)[ \t]*\(?[ \t]*(script[ \t]*:[ \t]*)?/)) {
                    pre = substr(s, 1, RSTART + RLENGTH - 1); s = substr(s, RSTART + RLENGTH)
                }
            } else if (match(s, /^[ \t]*(-[ \t]+)?([A-Za-z_][A-Za-z0-9_-]*:([ \t]+|$))?/)) {
                pre = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
            }
            n = 0; buf = ""; L = length(s)
            for (i = 1; i <= L; i++) {
                c2 = substr(s, i, 2); c1 = substr(s, i, 1)
                if (c2 == "&&" || c2 == "||") { seg[++n] = buf; sep[n] = c2; buf = ""; i++; continue }
                if (c1 == ";" || c1 == "|") { seg[++n] = buf; sep[n] = c1; buf = ""; continue }
                buf = buf c1
            }
            seg[++n] = buf; sep[n] = ""
            sw[n + 1] = 0
            for (k = n; k >= 1; k--) {
                sw[k] = 0
                if (sep[k] == "||" && swallows(seg[k + 1])) sw[k] = 1
                else if ((sep[k] == "&&" || sep[k] == "|") && sw[k + 1]) sw[k] = 1
            }
            killed = 0; out = pre
            for (k = 1; k <= n; k++) {
                w = word(seg[k])
                dead = killed || sw[k] || w == "echo" || w == "printf" \
                    || seg[k] ~ /(^|[ \t])--dry-run([^A-Za-z0-9_-]|$)/
                if (w == "exit" && seg[k] ~ /^[ \t({"\047]*exit([ \t]+0)?[ \t"\047)}]*$/ \
                    && (k == 1 || sep[k - 1] == ";")) killed = 1
                out = out (dead ? "" : seg[k]) sep[k]
            }
            print out
        }'
}

# The part of a pipeline file that runs and can fail the pipeline (#139,
# #171), as text: comments removed, then the never-run and cannot-fail parts
# above. A text check cannot see everything: a heredoc, `set +e`, a pipe
# into another command without pipefail, a script that wraps the step, an
# expression-valued `if:` or `continue-on-error:`, conditional GitLab rules,
# and a job reached only through `extends:` or an alias are read as live.
# The CI run's own log is the proof that a step ran.
gates_ci_live() { # <file>
    local kind
    kind="$(_gates_ci_kind "$1")"
    if [[ "$kind" == jenkins ]]; then
        _gates_ci_uncomment "$1" | _gates_ci_jenkins_drop
    else
        _gates_ci_uncomment "$1" | _gates_ci_yaml_drop "$kind"
    fi | _gates_ci_segments "$kind"
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

# Pipeline files that call verify.sh outside a comment yet run no live gates
# step (#171): a wrong --boundary, a disabled, manual or never-triggered
# job, an ignored failure. Such a pipeline looks wired and enforces nothing.
gates_ci_inert() { # <root>
    local root="$1" f re
    re="$(gates_ci_step_re gates)"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        grep -q 'verify\.sh' <<<"$(_gates_ci_uncomment "$root/$f")" || continue
        grep -qE "$re" <<<"$(gates_ci_live "$root/$f")" || printf '%s\n' "$f"
    done <<<"$(gates_ci_candidates "$root")"
    return 0
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
