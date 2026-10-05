#!/usr/bin/env bash
# spec-gate.sh -- spec-conformance gate for verify.sh (feature 002).
#
# Sourced by verify.sh (and doctor.sh for discovery reporting). Provides:
#   gates_spec_features <root>            # discovered feature dir names (R7)
#   gates_spec_status <spec-md>           # raw Status field value, "" if none
#   gates_spec_complete <spec-md>         # 0 iff Status is exactly "Complete"
#   gates_spec_parse <tasks-md> <outdir>  # accept blocks + checkbox counts (R1/R3)
#   gates_spec_run_block <cmd> <t> <root> <out>  # one block: watchdog + mutation (R4/R5)
#   gates_spec_gate <root> <accept> <json>       # driver; results in SPEC_* globals
#
# Fenced ```accept blocks in specs/*/tasks.md are executable acceptance
# criteria (exit 0 = the criterion holds). Features whose spec.md Status is
# Complete are enforced: any unchecked task or failing block fails the gate
# at the policy's spec.severity. Everything else is informational. Parse
# errors fail closed for every feature — an unreadable criterion is never
# silently skipped (FR-005).
#
# All bash 3.2 + jq + POSIX awk/sed. Blocks execute with GATES_SPEC_EXEC=1
# so a block that invokes verify.sh cannot re-enter the spec gate (that run
# reports the spec gate as skipped).

# shellcheck disable=SC2034   # library file; SPEC_* globals consumed by callers

# Feature discovery (R7): direct children of specs/ containing a spec.md,
# lexicographic order, minus policy spec.exclude globs. Missing specs/ means
# zero features (FR-011) — the gate then passes trivially.
gates_spec_features() { # <root>
    local root="${1:-}" d name g skip excludes
    [[ -d "$root/specs" ]] || return 0
    excludes="$(gates_policy_section_list spec exclude)"
    for d in "$root/specs"/*/; do
        [[ -d "$d" && -f "${d}spec.md" ]] || continue
        name="$(basename "$d")"
        skip=0
        if [[ -n "$excludes" ]]; then
            while IFS= read -r g; do
                [[ -z "$g" ]] && continue
                if gates_glob_match "$name" "$g"; then
                    skip=1
                    break
                fi
            done <<<"$excludes"
        fi
        [[ "$skip" == "1" ]] && continue
        printf '%s\n' "$name"
    done
    return 0
}

# Raw Status field from a feature's spec.md (first match wins, R2).
gates_spec_status() { # <spec-md>
    [[ -f "${1:-}" ]] || return 0
    sed -n 's/^\*\*Status\*\*:[[:space:]]*//p' "$1" | head -n 1 | sed 's/[[:space:]]*$//'
}

# Completion marker (R2): Status exactly "Complete" turns enforcement on.
gates_spec_complete() { # <spec-md>
    [[ "$(gates_spec_status "${1:-}")" == "Complete" ]]
}

# Is <feature> eligible for enforcement per spec.include (default ["*"])?
gates_spec_included() { # <feature-name>
    local includes g
    includes="$(gates_policy_section_list spec include)"
    [[ -z "$includes" ]] && return 0
    while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        gates_glob_match "$1" "$g" && return 0
    done <<<"$includes"
    return 1
}

# Accept-block parser + fence-aware checkbox accounting (R1/R3). One awk
# state machine; command bodies land in <outdir>/block-N.cmd, metadata on
# stdout as TAB-separated protocol lines:
#   ERROR<TAB><line><TAB><message>
#   BLOCK<TAB><cmdfile><TAB><verifies-or-dash><TAB><task text>
#   TASKS<TAB><total><TAB><unchecked><TAB><first unchecked task text>
# Malformed shapes (unterminated fence, command-less block, block with no
# preceding task) are ERROR lines, never skips. Fences are CommonMark-style
# runs of 3+ backticks, closed only by a run at least as long — prettier
# rewrites a block whose body contains ``` to a ````-fenced block, so exact-
# three matching would silently drop that criterion. Interval regexes and
# gensub are avoided on purpose: the parser must run on BSD awk (macOS).
gates_spec_parse() { # <tasks-md> <outdir>
    local file="${1:-}" outdir="${2:-}"
    [[ -f "$file" && -d "$outdir" ]] || return 0
    awk -v dir="$outdir" '
    BEGIN {
        in_fence = 0; in_accept = 0
        task = ""; have_task = 0
        nblocks = 0; total = 0; unchecked = 0; first_unc = ""
    }
    {
        line = $0
        # Fence-line decomposition: indent, backtick-run length, info string.
        is_fence = 0
        if (line ~ /^[[:space:]]*```/) {
            is_fence = 1
            rest = line
            sub(/^[[:space:]]*/, "", rest)
            flen = 0
            while (substr(rest, flen + 1, 1) == "`") flen++
            finfo = substr(rest, flen + 1)
            sub(/^[[:space:]]*/, "", finfo)
            sub(/[[:space:]]*$/, "", finfo)
        }
        if (in_accept) {
            if (is_fence && finfo == "" && flen >= open_len) {
                if (!orphan) {
                    if (ncmds == 0) {
                        printf "ERROR\t%d\taccept block has no command lines\n", open_line
                    } else {
                        nblocks++
                        cmdfile = dir "/block-" nblocks ".cmd"
                        printf "%s", body > cmdfile
                        close(cmdfile)
                        v = (verifies == "") ? "-" : verifies
                        printf "BLOCK\t%s\t%s\t%s\n", cmdfile, v, btask
                    }
                }
                in_accept = 0
                next
            }
            n = 0
            while (n < indent && substr(line, n + 1, 1) == " ") n++
            stripped = substr(line, n + 1)
            body = body stripped "\n"
            if (stripped ~ /[^[:space:]]/ && stripped !~ /^[[:space:]]*#/) ncmds++
            if (verifies == "" && stripped ~ /^# verifies:/) {
                v = stripped
                sub(/^# verifies:[[:space:]]*/, "", v)
                sub(/[[:space:]]*$/, "", v)
                verifies = v
            }
            next
        }
        if (is_fence) {
            if (!in_fence && finfo == "accept") {
                in_accept = 1
                open_line = NR
                open_len = flen
                body = ""; ncmds = 0; verifies = ""; orphan = 0
                match(line, /^[[:space:]]*/)
                indent = RLENGTH
                if (!have_task) {
                    printf "ERROR\t%d\taccept block has no preceding task line\n", NR
                    orphan = 1
                }
                btask = task
            } else if (!in_fence) {
                in_fence = 1
                gen_len = flen
            } else if (finfo == "" && flen >= gen_len) {
                in_fence = 0
            }
            # A fence-like line inside a generic fence that does not close it
            # (info string present, or a shorter run) is interior content.
            next
        }
        if (!in_fence && line ~ /^[[:space:]]*- \[[ xX]\] /) {
            total++
            t = line
            sub(/^[[:space:]]*- \[[ xX]\] /, "", t)
            if (line !~ /^[[:space:]]*- \[[xX]\]/) {
                unchecked++
                if (first_unc == "") first_unc = t
            }
            task = t
            have_task = 1
        }
    }
    END {
        if (in_accept) printf "ERROR\t%d\tunterminated accept fence\n", open_line
        printf "TASKS\t%d\t%d\t%s\n", total, unchecked, first_unc
    }' "$file"
}

# Untracked and ignored paths the gate itself writes while a block runs (a
# nested verify.sh appends its attestation), left out of the read-only
# check together with the policy's spec.snapshot_exclude globs. A tracked
# path is never exempt. gates_spec_gate sets GATES_SPEC_SNAPSHOT_EXCLUDE.
GATES_SPEC_SNAPSHOT_BUILTIN_EXCLUDE=".specify/gates/attestations.jsonl
.specify/gates/.attestations.jsonl.*"

gates_spec_excluded() { # <path>
    local g
    while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        # "dir/" names the directory: the ignored root "dir" (listed
        # without its slash) and every path under it (#199).
        [[ "$g" == */ ]] && g="${g%/}/**"
        gates_glob_match "$1" "$g" && return 0
    done <<<"${GATES_SPEC_SNAPSHOT_EXCLUDE:-$GATES_SPEC_SNAPSHOT_BUILTIN_EXCLUDE}"
    return 1
}

# One "<kind><TAB>value<TAB>relpath" line per file under <dir> (exec bit
# and content hash, or a symlink's target), or a single "absent" line.
gates_spec_dir_state() { # <kind> <root> <dir> <scratch> <list>
    local kind="$1" root="$2" dir="$3" scratch="$4" list="$5" path rel entry i
    [[ "$dir" == /* ]] || dir="$root/$dir"
    if [[ ! -d "$dir" ]]; then
        printf '%s\tabsent\t%s\n' "$kind" "$dir"
        return 0
    fi
    find "$dir" \( -type f -o -type l \) -print0 >"$scratch" 2>/dev/null || return 1
    : >"$list"
    local rels=() xs=()
    while IFS= read -r -d '' path; do
        rel="${path#"$dir"/}"
        if [[ -L "$path" ]]; then
            printf '%s\tlink:%s\t%s\n' "$kind" "$(readlink "$path" 2>/dev/null || true)" "$rel"
            continue
        fi
        printf '%s\n' "$path" >>"$list"
        rels+=("$rel")
        if [[ -x "$path" ]]; then xs+=("x"); else xs+=("-"); fi
    done <"$scratch"
    [[ ${#rels[@]} -gt 0 ]] || return 0
    git -C "$root" hash-object --no-filters --stdin-paths \
        <"$list" >"$scratch" 2>/dev/null || return 1
    i=0
    while IFS= read -r entry; do
        printf '%s\t%s:%s\t%s\n' "$kind" "${xs[i]}" "$entry" "${rels[i]}"
        i=$((i + 1))
    done <"$scratch"
    [[ $i -eq ${#rels[@]} ]]
}

# The branches the worktree whose admin directory is <dir> works on, as
# "oth<TAB>refs/heads/...<TAB><name>" lines: the one HEAD points to, and the
# one an interrupted rebase will update (HEAD is detached meanwhile).
# <keep>, this worktree's own branch, is never listed.
gates_spec_wt_branches() { # <admin-dir> <name> <keep>
    local f line
    for f in "$1/HEAD" "$1/rebase-merge/head-name" "$1/rebase-apply/head-name"; do
        [[ -f "$f" ]] || continue
        line=""
        read -r line <"$f" || true
        line="${line#ref: }"
        [[ "$line" == refs/* && "$line" != "$3" ]] && printf 'oth\t%s\t%s\n' "$line" "$2"
    done
    return 0
}

# Snapshot of everything an accept block must leave alone (R5, #136, #164),
# written sorted to <state> as "kind<TAB>value<TAB>name" lines:
#   tree  one per `git status --porcelain=v1 -z --untracked-files=all`
#         entry; value = status, content hash and rename source. Status
#         alone misses a write to a file that is already dirty or
#         untracked (#136), so those files are hashed.
#   cfg   one per `git config --list --show-origin` entry (every scope, so
#         a --global core.hooksPath counts too); branch.* is left out, since
#         creating a branch in any sibling worktree writes it.
#   hook  one per file under the hooks directory git uses (`--git-path
#         hooks`, which follows core.hooksPath): exec bit and content hash.
#   info  the same for the info directory (attributes, exclude,
#         sparse-checkout): attributes can switch filters and diff drivers.
#   idx   one per index entry flagged skip-worktree or assume-unchanged
#         (`git ls-files -v`): the flag and a content hash, since status
#         no longer reports edits to a flagged file (#197).
#   wt    this worktree, when it is a linked one: its path and its lock.
#   oth   one per branch another worktree (main or linked) has checked out
#         or is rebasing. Not compared: the comparison leaves the refs named
#         in either snapshot out, since a commit, a branch switch or a new
#         worktree there is not this block's doing (#206). Other worktrees'
#         HEADs and per-worktree refs are not visible from here at all.
#   ref   HEAD (commit and symbolic target) and every ref except
#         refs/remotes/*, which a background fetch moves.
#   ign   one per ignored root (`git ls-files -o -i --directory`): a file,
#         or a directory that is ignored as a whole. Content changes under
#         a root are found by ctime against a marker instead of hashing,
#         which would cost a full read of node_modules per block (see
#         gates_spec_ignored_writes).
# Returns nonzero when git cannot produce the snapshot.
gates_spec_snapshot() { # <root> <state-file>
    local root="$1" state="$2" scratch="$2.tmp" list="$2.list"
    local entry xy path orig n=0 i hdir kv key val head sym
    local xys=() paths=() origs=() hashes=() fidx=()
    git -C "$root" status --porcelain=v1 -z --untracked-files=all \
        >"$scratch" 2>/dev/null || return 1
    : >"$list"
    while IFS= read -r -d '' entry; do
        xy="${entry:0:2}"
        path="${entry:3}"
        orig=""
        # A staged rename or copy carries its source path as the next entry.
        case "$xy" in
            *R* | *C*) IFS= read -r -d '' orig || true ;;
        esac
        [[ "$xy" == "??" ]] && gates_spec_excluded "$path" && continue
        xys[n]="$xy"
        paths[n]="$path"
        origs[n]="$orig"
        if [[ -L "$root/$path" ]]; then
            hashes[n]="link:$(readlink "$root/$path" 2>/dev/null || true)"
        elif [[ -f "$root/$path" ]]; then
            hashes[n]=""
            printf '%s\n' "$path" >>"$list"
            fidx+=("$n")
        elif [[ -e "$root/$path" ]]; then
            hashes[n]="other"
        else
            hashes[n]="absent"
        fi
        n=$((n + 1))
    done <"$scratch"
    if [[ ${#fidx[@]} -gt 0 ]]; then
        # One hash-object call for every dirty file, paths fed on stdin
        # (an argument list this long would hit the argv limit).
        git -C "$root" hash-object --no-filters --stdin-paths \
            <"$list" >"$scratch" 2>/dev/null || return 1
        i=0
        while IFS= read -r entry; do
            hashes[fidx[i]]="$entry"
            i=$((i + 1))
        done <"$scratch"
        [[ $i -eq ${#fidx[@]} ]] || return 1
    fi
    {
        i=0
        while [[ $i -lt $n ]]; do
            printf 'tree\t%s %s %s\t%s\n' "${xys[i]}" "${hashes[i]}" "${origs[i]}" "${paths[i]}"
            i=$((i + 1))
        done

        git -C "$root" config --list --show-origin -z >"$scratch" 2>/dev/null || return 1
        while IFS= read -r -d '' entry && IFS= read -r -d '' kv; do
            key="${kv%%$'\n'*}"
            case "$key" in branch.*) continue ;; esac
            val=""
            [[ "$kv" == *$'\n'* ]] && val="${kv#*$'\n'}"
            val="${val//[$'\t\n']/ }"
            printf 'cfg\t%s %s\t%s\n' "$entry" "$val" "$key"
        done <"$scratch"

        local gpaths idir cdir wt
        gpaths="$(git -C "$root" rev-parse --git-path hooks --git-path info \
            --git-common-dir 2>/dev/null)" || return 1
        { read -r hdir && read -r idir && read -r cdir; } <<<"$gpaths" || return 1
        gates_spec_dir_state hook "$root" "$hdir" "$scratch" "$list" || return 1
        gates_spec_dir_state info "$root" "$idir" "$scratch" "$list" || return 1

        # Index flags: skip-worktree (S) and assume-unchanged (lowercase)
        # entries hide later edits from git status, so each one is listed
        # with its content hash.
        git -C "$root" ls-files -v -z >"$scratch" 2>/dev/null || return 1
        grep -z -v -e '^H ' "$scratch" >"$list" 2>/dev/null || [[ $? -eq 1 ]] || return 1
        local ftags=() fpaths=()
        : >"$scratch"
        while IFS= read -r -d '' entry; do
            path="${entry:2}"
            if [[ -f "$root/$path" && ! -L "$root/$path" ]]; then
                ftags+=("${entry:0:1}")
                fpaths+=("$path")
                printf '%s\n' "$path" >>"$scratch"
            else
                printf 'idx\t%s absent\t%s\n' "${entry:0:1}" "$path"
            fi
        done <"$list"
        if [[ ${#fpaths[@]} -gt 0 ]]; then
            git -C "$root" hash-object --no-filters --stdin-paths \
                <"$scratch" >"$list" 2>/dev/null || return 1
            i=0
            while IFS= read -r entry; do
                printf 'idx\t%s %s\t%s\n' "${ftags[i]}" "$entry" "${fpaths[i]}"
                i=$((i + 1))
            done <"$list"
            [[ $i -eq ${#fpaths[@]} ]] || return 1
        fi

        # Worktrees, read from <common-dir> (#206). This worktree's entry is
        # compared: where it lives and whether it is locked. Every other
        # worktree contributes only the branch it has checked out (or is
        # rebasing) as an "oth" line, which the comparison uses to leave
        # that branch's ref out and never compares itself.
        local gdir self=""
        gdir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
        [[ "$cdir" == /* ]] || cdir="$root/$cdir"
        gdir="$(cd "$gdir" 2>/dev/null && pwd -P)" || return 1
        cdir="$(cd "$cdir" 2>/dev/null && pwd -P)" || return 1
        [[ "$gdir" == "$cdir" ]] || self="${gdir##*/}"
        sym="$(git -C "$root" symbolic-ref -q HEAD 2>/dev/null)" || sym="detached"
        [[ -n "$self" ]] && gates_spec_wt_branches "$cdir" main "$sym"
        for wt in "$cdir"/worktrees/*; do
            [[ -d "$wt" ]] || continue
            if [[ "${wt##*/}" != "$self" ]]; then
                gates_spec_wt_branches "$wt" "${wt##*/}" "$sym"
                continue
            fi
            path=""
            [[ -f "$wt/gitdir" ]] && read -r path <"$wt/gitdir"
            printf 'wt\t%s\t%s\n' "${path:-none}" "${wt##*/}"
            [[ -e "$wt/locked" ]] && printf 'wt\tlocked\t%s\n' "${wt##*/}"
        done

        git -C "$root" for-each-ref --format='%(objectname)%09%(refname)' \
            >"$scratch" 2>/dev/null || return 1
        awk -F'\t' '$2 !~ /^refs\/remotes\// { printf "ref\t%s\t%s\n", $1, $2 }' "$scratch"
        head="$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" || head="unborn"
        printf 'ref\t%s %s\tHEAD\n' "$head" "$sym"

        git -C "$root" ls-files -z -o -i --exclude-standard --directory \
            >"$scratch" 2>/dev/null || return 1
        while IFS= read -r -d '' path; do
            path="${path%/}"
            gates_spec_excluded "$path" && continue
            printf 'ign\t-\t%s\n' "$path"
        done <"$scratch"
    } >"$list.out" || return 1
    sort -u "$list.out" >"$state" || return 1
    rm -f "$scratch" "$list" "$list.out"
}

# Create <marker> and wait until the clock has visibly moved past it on the
# same filesystem: Linux stamps files from a coarse clock, and some
# filesystems keep whole seconds, so a write right after the marker could
# otherwise carry the marker's own timestamp and go unseen by -cnewer.
gates_spec_mark() { # <marker>
    local probe="$1.probe" n=0
    : >"$1" 2>/dev/null || return 1
    while [[ $n -lt 150 ]]; do
        rm -f "$probe"
        : >"$probe" 2>/dev/null || break
        if [[ -n "$(find "$probe" -newer "$1" 2>/dev/null)" ]]; then
            rm -f "$probe"
            return 0
        fi
        sleep 0.01
        n=$((n + 1))
    done
    rm -f "$probe"
    return 0
}

# Ignored paths written since <marker>: every file or directory under the
# ignored roots of <state> whose ctime is newer. ctime moves on any write,
# chmod, create, delete or rename inside a directory, and unprivileged code
# cannot set it back (touch -t sets mtime only).
gates_spec_ignored_writes() { # <root> <state> <marker>
    local root="$1" state="$2" marker="$3" kind val path
    while IFS=$'\t' read -r kind val path; do
        [[ "$kind" == ign ]] || continue
        [[ -e "$root/$path" || -L "$root/$path" ]] || continue
        printf './%s\0' "$path"
    done <"$state" >"$state.roots"
    if [[ -s "$state.roots" ]]; then
        # shellcheck disable=SC2016  # expanded by the inner sh
        (cd "$root" && xargs -0 sh -c 'find "$@" -cnewer "$0" -print0' "$marker" \
            <"$state.roots") >"$state.found" 2>/dev/null || true
        while IFS= read -r -d '' path; do
            path="${path#./}"
            gates_spec_excluded "$path" && continue
            printf 'ign\t%s\n' "$path"
        done <"$state.found"
    fi
    rm -f "$state.roots" "$state.found"
}

# One detail string from sorted "kind<TAB>name" change lines, at most ten
# names per kind.
gates_spec_change_detail() { # <changes-file>
    awk -F'\t' '
        { n[$1]++; if (n[$1] <= 10) l[$1] = l[$1] (l[$1] == "" ? "" : " ") $2 }
        END {
            nk = split("tree ign idx cfg hook info ref wt", order, " ")
            label["tree"] = "working tree modified"
            label["ign"] = "ignored files modified"
            label["idx"] = "index flags modified"
            label["cfg"] = "git config modified"
            label["hook"] = "git hooks modified"
            label["info"] = "git info files modified"
            label["ref"] = "refs modified"
            label["wt"] = "worktrees modified"
            out = ""
            for (i = 1; i <= nk; i++) {
                k = order[i]
                if (!(k in n)) continue
                s = label[k] ": " l[k]
                if (n[k] > 10) s = s " (+" (n[k] - 10) " more)"
                out = out (out == "" ? "" : "; ") s
            }
            printf "%s", out
        }' "$1"
}

# Is any live (non-zombie) process left in process group <pgid>? ps is the
# precise check; without it (minimal images) kill -0, which also counts a
# zombie that is about to be reaped.
gates_spec_group_alive() { # <pgid>
    local procs
    if procs="$(ps -A -o pgid= -o stat= 2>/dev/null)" && [[ -n "$procs" ]]; then
        awk -v g="$1" '$1 == g && $2 !~ /^Z/ { found = 1 } END { exit !found }' <<<"$procs"
        return
    fi
    kill -0 -- -"$1" 2>/dev/null
}

# Stop process group <pgid>: TERM, a two-second grace, then KILL.
gates_spec_group_stop() { # <pgid>
    local n=0
    kill -TERM -- -"$1" 2>/dev/null || return 0
    while [[ $n -lt 20 ]] && kill -0 -- -"$1" 2>/dev/null; do
        sleep 0.1
        n=$((n + 1))
    done
    kill -KILL -- -"$1" 2>/dev/null
    return 0
}

# PIDs of live processes whose environment holds GATES_SPEC_BLOCK=<id>, one
# per line. Every process a block starts inherits the variable, and leaving
# the process group or session (set -m, setsid, a double fork) does not
# drop it. Linux: /proc/<pid>/environ, matched as a whole entry. macOS and
# other BSDs: `ps -E`, which appends the environment to the command; the
# table is captured to a file first, so the matching awk is not in it.
# macOS shows no environment for Apple-signed binaries (/bin/sh, /bin/sleep,
# /usr/bin/git), so there this only finds other binaries; the lease
# descriptor (gates_spec_lease_holders) covers the rest. Both read the
# environment a process was started with; a zombie shows none. Returns 2
# when neither source is available.
gates_spec_marked() { # <id> <scratch>
    local needle="GATES_SPEC_BLOCK=$1" scratch="$2" path
    if [[ -r /proc/self/environ ]]; then
        (cd /proc && grep -l -a -z -x -F -e "$needle" [0-9]*/environ) \
            >"$scratch" 2>/dev/null || true
        while IFS= read -r path; do
            printf '%s\n' "${path%%/*}"
        done <"$scratch"
        return 0
    fi
    ps -A -ww -E -o pid= -o command= >"$scratch" 2>/dev/null || return 2
    [[ -s "$scratch" ]] || return 2
    awk -v n="$needle" 'index($0 " ", " " n " ") { print $1 }' "$scratch"
}

# PIDs of processes holding the write end of lease FIFO <fifo>, one per
# line. Linux: /proc/<pid>/fd links to the FIFO, kept when fdinfo shows a
# write mode (the gate's own reader holds the read end). Elsewhere: lsof
# over this user's processes (given the FIFO's path, macOS lsof matches
# nothing), compared against the physical path. That takes most of a
# second, but it only runs on the failure path, to name what to stop: the
# pass/fail decision never depends on it.
gates_spec_lease_holders() { # <fifo> <scratch>
    local fifo="$1" scratch="$2" path pid fd key flags real
    if [[ -d /proc/self/fd ]]; then
        find /proc/[0-9]*/fd -maxdepth 1 -lname "$fifo" >"$scratch" 2>/dev/null || true
        while IFS= read -r path; do
            pid="${path#/proc/}"
            pid="${pid%%/*}"
            fd="${path##*/}"
            flags=""
            while read -r key flags; do
                [[ "$key" == "flags:" ]] && break
                flags=""
            done <"/proc/$pid/fdinfo/$fd" 2>/dev/null
            [[ "$flags" =~ ^[0-7]+$ ]] && (((8#$flags & 3) != 0)) && printf '%s\n' "$pid"
        done <"$scratch"
        return 0
    fi
    command -v lsof >/dev/null 2>&1 || return 0
    real="$(cd "${fifo%/*}" 2>/dev/null && pwd -P)/${fifo##*/}" || return 0
    # -b -n -P: no blocking stat of network mounts, no name lookups.
    lsof -b -n -P -w -a -u "$(id -u)" -d 0-255 -F pan >"$scratch" 2>/dev/null || true
    awk -v f="$real" '/^p/ { p = substr($0, 2) } /^a/ { a = substr($0, 2) }
        /^n/ { if (substr($0, 2) == f && a ~ /[wu]/) print p }' "$scratch"
}

# Stop every process a block left behind (#197): anything still holding
# the lease descriptor (<eof> is missing until the last holder exits) or
# carrying block marker <id>. Lease holders on their way out get half a
# second, as in the group check. The table is read after a short settle,
# so a fork racing the block's exit is in it and a quick write by a
# process neither check sees lands before the after-snapshot. Whatever is
# left is killed and both are checked again. Returns 0 when none was
# left, 1 when some had to be stopped.
gates_spec_detached_stop() { # <id> <scratch> <fifo> <eof>
    local id="$1" scratch="$2" fifo="$3" eof="$4" pids n=0 m
    while [[ ! -f "$eof" && $n -lt 5 ]]; do
        sleep 0.1
        n=$((n + 1))
    done
    sleep 0.1
    pids="$(gates_spec_marked "$id" "$scratch")" || pids=""
    [[ -f "$eof" && -z "$pids" ]] && return 0
    n=0
    while [[ $n -lt 5 ]]; do
        [[ -f "$eof" ]] || pids="$pids $(gates_spec_lease_holders "$fifo" "$scratch")"
        # shellcheck disable=SC2086  # a list of numeric PIDs
        [[ -n "${pids// /}" ]] && kill -KILL $pids 2>/dev/null
        m=0
        while [[ ! -f "$eof" && $m -lt 6 ]]; do
            sleep 0.05
            m=$((m + 1))
        done
        pids="$(gates_spec_marked "$id" "$scratch")" || pids=""
        [[ -f "$eof" && -z "$pids" ]] && break
        n=$((n + 1))
    done
    return 1
}

# Execute one accept block (R4/R5): repo-root cwd, pure-shell watchdog (no
# timeout(1) on macOS base), snapshots before and after. Outside a git work
# tree the block does not run: a mutation check that cannot happen fails
# closed. The block is a job of a `set -m` subshell, so it leads its own
# process group. A timeout stops that whole group (#136); so does the end
# of every block, and a block that leaves a process running past a short
# grace fails (#164): a late write would land after the snapshot. A child
# that left the group (set -m, setsid, a double fork) is found by the
# lease descriptor it inherited or the GATES_SPEC_BLOCK marker in its
# environment, stopped, and fails the block too (#197). A process that
# closed the descriptor and re-executed without the marker (or, on macOS,
# runs an Apple-signed binary, whose environment ps cannot read) is not
# found.
# The previous block's after-snapshot is reused as this block's before-
# snapshot (SPEC_SNAP_PREV), since the gate writes nothing in between.
# Returns 0 pass, 1 fail, 2 timeout, 3 mutation; detail in SPEC_BLOCK_DETAIL.
gates_spec_run_block() { # <cmdfile> <timeout-s> <root> <outfile>
    local cmdfile="$1" timeout="$2" root="$3" outfile="$4"
    local marker="$outfile.timedout" leftover="$outfile.leftover"
    local before="$outfile.before" after="$outfile.after" mark gitdir
    SPEC_BLOCK_DETAIL=""
    : >"$outfile"
    if [[ "$(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]]; then
        SPEC_SNAP_PREV=""
        SPEC_BLOCK_DETAIL="cannot check for mutations: not a git work tree"
        return 1
    fi
    if [[ -n "${SPEC_SNAP_PREV:-}" && -f "$SPEC_SNAP_PREV" ]]; then
        before="$SPEC_SNAP_PREV"
    elif ! gates_spec_snapshot "$root" "$before"; then
        SPEC_BLOCK_DETAIL="cannot check for mutations: git snapshot failed"
        return 1
    fi
    SPEC_SNAP_PREV=""
    # The ctime marker lives in the git dir, on the repository's own
    # filesystem, so it shares the timestamp resolution of what it guards.
    gitdir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null || true)"
    mark="$gitdir/gates-spec-mark.$$"
    if [[ -z "$gitdir" ]] || ! gates_spec_mark "$mark"; then
        mark="$outfile.mark"
        gates_spec_mark "$mark"
    fi
    rm -f "$marker" "$leftover"
    local rc=0 procs="$outfile.procs" lease="$outfile.lease" eof="$outfile.lease.eof"
    # Unique per block and gate run; set only in the block's environment.
    GATES_SPEC_BLOCK_SEQ=$((${GATES_SPEC_BLOCK_SEQ:-0} + 1))
    local bid="$$-$GATES_SPEC_BLOCK_SEQ-$RANDOM$RANDOM" reader
    # The lease (#197): the block inherits the write end of a FIFO on fd 7,
    # and so does every process it starts, in or out of its group or
    # session, unless it closes the descriptor. The reader sees EOF, and
    # writes <eof>, only once the last holder has exited. It starts first
    # (opening the write end waits for a reader) and outside the block's
    # group, so a timeout does not take it along.
    rm -f "$lease" "$eof"
    if ! mkfifo "$lease" 2>/dev/null; then
        rm -f "$mark"
        SPEC_BLOCK_DETAIL="cannot check for leftover processes: mkfifo failed"
        return 1
    fi
    (
        cat "$lease" >/dev/null 2>&1 &
        c=$!
        trap 'kill "$c" 2>/dev/null; exit 0' TERM
        wait "$c"
        : >"$eof"
    ) </dev/null >/dev/null 2>&1 &
    reader=$!
    # The watchdog gets /dev/null stdio: it (and its sleep) must not hold
    # inherited fds, or a block that captures a nested verify.sh via $()
    # would wait on the pipe until the sleep expires. It is a job of its
    # own, so stopping it takes its sleep along.
    (
        set -m
        # A git hook runs this with GIT_DIR and GIT_INDEX_FILE set (absolute
        # in a linked worktree): a block that builds a sandbox repository
        # would then add, commit and tag in the caller's repository (#173).
        # The block gets a clean git environment; it runs in the project
        # directory, so its own git calls still find this repository.
        (cd "$root" && GATES_SPEC_EXEC=1 GATES_SPEC_BLOCK="$bid" exec env -u GIT_DIR -u GIT_INDEX_FILE \
            -u GIT_WORK_TREE -u GIT_PREFIX -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY \
            -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE -u GIT_QUARANTINE_PATH \
            bash "$cmdfile") 7>"$lease" >"$outfile" 2>&1 </dev/null &
        pid=$!
        trap 'kill -TERM -- -"$pid" 2>/dev/null' HUP INT TERM
        (
            sleep "$timeout"
            : >"$marker"
            gates_spec_group_stop "$pid"
        ) >/dev/null 2>&1 </dev/null &
        watcher=$!
        brc=0
        wait "$pid" 2>/dev/null || brc=$?
        if [[ -f "$marker" ]]; then
            wait "$watcher" 2>/dev/null
        else
            kill -TERM -- -"$watcher" 2>/dev/null
            wait "$watcher" 2>/dev/null
            # A child that is already on its way out (the block killed it
            # without waiting) gets half a second before it counts.
            n=0
            while [[ $n -lt 5 ]] && gates_spec_group_alive "$pid"; do
                sleep 0.1
                n=$((n + 1))
            done
            if gates_spec_group_alive "$pid"; then
                : >"$leftover"
                gates_spec_group_stop "$pid"
            fi
        fi
        exit "$brc"
    ) 2>/dev/null || rc=$?
    # A process outside the group is stopped on every path, pass or not.
    local detached=""
    gates_spec_detached_stop "$bid" "$procs" "$lease" "$eof" ||
        detached="left a detached process running (stopped)"
    kill -TERM "$reader" 2>/dev/null
    wait "$reader" 2>/dev/null
    rm -f "$lease" "$eof"
    if [[ -f "$marker" ]]; then
        rm -f "$marker" "$leftover" "$mark"
        SPEC_BLOCK_DETAIL="timeout after ${timeout}s${detached:+; $detached}"
        return 2
    fi
    if [[ "$rc" -ne 0 ]]; then
        SPEC_BLOCK_DETAIL="exit $rc"
        [[ -f "$leftover" ]] && SPEC_BLOCK_DETAIL="exit $rc; left a process running (stopped)"
        SPEC_BLOCK_DETAIL="$SPEC_BLOCK_DETAIL${detached:+; $detached}"
        rm -f "$leftover" "$mark"
        return 1
    fi
    if [[ -f "$leftover" ]]; then
        rm -f "$leftover" "$mark"
        SPEC_BLOCK_DETAIL="left a process running after it exited (stopped)${detached:+; $detached}"
        return 1
    fi
    if [[ -n "$detached" ]]; then
        rm -f "$mark"
        SPEC_BLOCK_DETAIL="$detached"
        return 1
    fi
    if ! gates_spec_snapshot "$root" "$after"; then
        rm -f "$mark"
        SPEC_BLOCK_DETAIL="cannot check for mutations: git snapshot failed"
        return 1
    fi
    {
        # Refs of branches another worktree has checked out, before or
        # after the block, are that worktree's doing (#206).
        sort "$before" "$after" | uniq -u | cut -f1,3 >"$outfile.diff"
        awk -F'\t' -v diff="$outfile.diff" '
            FILENAME != diff { if ($1 == "oth") skip[$2] = 1; next }
            $1 == "oth" { next }
            $1 == "ref" && ($2 in skip) { next }
            { print }' "$before" "$after" "$outfile.diff"
        gates_spec_ignored_writes "$root" "$after" "$mark"
    } | sort -u >"$outfile.changes"
    rm -f "$mark" "$outfile.diff"
    SPEC_SNAP_PREV="$after"
    if [[ -s "$outfile.changes" ]]; then
        SPEC_BLOCK_DETAIL="$(gates_spec_change_detail "$outfile.changes")"
        return 3
    fi
    return 0
}

# Driver. Sets:
#   SPEC_RESULT   pass|fail            (severity mapping is the caller's job)
#   SPEC_DETAIL   one-line summary (pass) or "; "-joined failures (fail)
#   SPEC_FEATURES SPEC_PARSED SPEC_EXECUTED SPEC_PASSED SPEC_FAILED  counts
#   SPEC_RESULTS_JSON  FeatureConformance array (data-model.md)
# In text mode (json=0) informational lines print directly: per-criterion
# results for --accept runs and one line per not-enforced feature.
gates_spec_gate() { # <root> <accept-arg> <json 0|1>
    local root="${1:-}" accept="${2:-}" json="${3:-0}"
    SPEC_RESULT="pass"
    SPEC_DETAIL=""
    SPEC_FEATURES=0
    SPEC_PARSED=0
    SPEC_EXECUTED=0
    SPEC_PASSED=0
    SPEC_FAILED=0
    SPEC_RESULTS_JSON="[]"
    local timeout
    timeout="$(gates_policy_section_get spec timeout_s)"
    [[ -z "$timeout" ]] && timeout=30
    SPEC_SNAP_PREV=""
    GATES_SPEC_SNAPSHOT_EXCLUDE="$GATES_SPEC_SNAPSHOT_BUILTIN_EXCLUDE
$(gates_policy_section_list spec snapshot_exclude)"
    local tmp
    if ! tmp="$(mktemp -d 2>/dev/null || mktemp -d -t gates-spec)"; then
        SPEC_RESULT="fail"
        SPEC_DETAIL="spec gate: could not create work dir (mktemp)"
        return 0
    fi
    local failures="" results="" complete_n=0 f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        SPEC_FEATURES=$((SPEC_FEATURES + 1))
        local fdir="$root/specs/$f"
        mkdir -p "$tmp/$f"
        local tasks_total=0 tasks_unchecked=0 first_unchecked=""
        local bfiles=() bverifies=() btasks=()
        local parse_out=""
        if [[ -f "$fdir/tasks.md" ]]; then
            parse_out="$(gates_spec_parse "$fdir/tasks.md" "$tmp/$f")"
        fi
        local line tag a1 a2 rest
        local ferrors=0
        while IFS=$'\t' read -r tag a1 a2 rest; do
            [[ -z "$tag" ]] && continue
            case "$tag" in
                ERROR)
                    failures="${failures:+$failures; }specs/$f/tasks.md:$a1: $a2"
                    ferrors=$((ferrors + 1))
                    ;;
                BLOCK)
                    bfiles+=("$a1")
                    bverifies+=("$a2")
                    btasks+=("$rest")
                    SPEC_PARSED=$((SPEC_PARSED + 1))
                    ;;
                TASKS)
                    tasks_total="$a1"
                    tasks_unchecked="$a2"
                    first_unchecked="$rest"
                    ;;
            esac
        done <<<"$parse_out"
        local nblocks=${#bfiles[@]}
        local complete=0 enforced=0
        gates_spec_complete "$fdir/spec.md" && complete=1
        if [[ "$complete" == "1" ]] && gates_spec_included "$f"; then
            enforced=1
            complete_n=$((complete_n + 1))
        fi
        local do_exec=0
        if [[ "$enforced" == "1" ]]; then
            do_exec=1
        elif [[ "$accept" == "all" || "$accept" == "$f" ]]; then
            do_exec=1
        fi
        local i=0 fpassed=0 ffailed=0 fexecuted=0
        if [[ "$do_exec" == "1" ]]; then
            while [[ $i -lt $nblocks ]]; do
                local label="${bverifies[$i]}"
                [[ "$label" == "-" ]] && label="${btasks[$i]}"
                local brc=0
                gates_spec_run_block "${bfiles[$i]}" "$timeout" "$root" "$tmp/$f/out-$i" || brc=$?
                fexecuted=$((fexecuted + 1))
                if [[ "$brc" -eq 0 ]]; then
                    fpassed=$((fpassed + 1))
                    if [[ "$enforced" == "0" && "$json" == "0" ]]; then
                        echo "spec: $f: \"$label\" -- pass"
                    fi
                else
                    ffailed=$((ffailed + 1))
                    if [[ "$enforced" == "1" ]]; then
                        failures="${failures:+$failures; }$f: \"$label\": $SPEC_BLOCK_DETAIL"
                        if [[ "$json" == "0" ]]; then
                            echo "spec: $f: \"$label\" -- FAILED ($SPEC_BLOCK_DETAIL):"
                            sed 's/^/  | /' "$tmp/$f/out-$i" | tail -n 20
                        fi
                    elif [[ "$json" == "0" ]]; then
                        echo "spec: $f: \"$label\" -- fail ($SPEC_BLOCK_DETAIL, informational):"
                        sed 's/^/  | /' "$tmp/$f/out-$i" | tail -n 20
                    fi
                fi
                i=$((i + 1))
            done
        fi
        SPEC_EXECUTED=$((SPEC_EXECUTED + fexecuted))
        SPEC_PASSED=$((SPEC_PASSED + fpassed))
        SPEC_FAILED=$((SPEC_FAILED + ffailed))
        # Outcome classification (data-model.md): top-down, first match wins.
        # Task drift blocks even with zero accept blocks; no-criteria only
        # applies once every task is checked.
        local outcome
        if [[ "$enforced" == "1" ]]; then
            if [[ "$tasks_unchecked" -gt 0 ]]; then
                failures="${failures:+$failures; }$f: unchecked task: \"$first_unchecked\" ($tasks_unchecked of $tasks_total unchecked)"
                outcome="enforced-fail"
            elif [[ "$ffailed" -gt 0 ]]; then
                outcome="enforced-fail"
            elif [[ "$nblocks" -eq 0 ]]; then
                outcome="no-criteria"
                [[ "$json" == "0" ]] && echo "spec: $f -- marked Complete with no accept blocks (nothing executable to hold it to)"
            else
                outcome="enforced-pass"
            fi
        else
            outcome="informational"
            if [[ "$json" == "0" && "$accept" != "all" && "$accept" != "$f" ]]; then
                local status
                status="$(gates_spec_status "$fdir/spec.md")"
                # Display-clip the raw Status value (issue #34): enforcement
                # keys on the exact token "Complete", but a long free-form
                # status would render lossily in narrow output.
                [[ "${#status}" -gt 40 ]] && status="${status:0:37}..."
                echo "spec: $f -- $nblocks criteria parsed, not enforced (Status: ${status:-none})"
            fi
        fi
        local cb=false
        [[ "$complete" == "1" ]] && cb=true
        local rj
        rj="$(jq -cn --arg f "$f" --arg o "$outcome" --argjson c "$cb" \
            --argjson tt "$tasks_total" --argjson tu "$tasks_unchecked" \
            --argjson bp "$nblocks" --argjson be "$fexecuted" \
            --argjson bs "$fpassed" --argjson bf "$ffailed" '
            { feature: $f, complete: $c, tasks_total: $tt,
              tasks_unchecked: $tu, blocks_parsed: $bp, blocks_executed: $be,
              blocks_passed: $bs, blocks_failed: $bf, outcome: $o }')"
        results="$results$rj,"
    done <<<"$(gates_spec_features "$root")"
    SPEC_RESULTS_JSON="[${results%,}]"
    rm -rf "$tmp"
    if [[ -n "$failures" ]]; then
        SPEC_RESULT="fail"
        SPEC_DETAIL="$failures"
    else
        SPEC_DETAIL="$SPEC_FEATURES feature(s), $complete_n enforced, $SPEC_PARSED criteria parsed, $SPEC_EXECUTED executed"
    fi
    return 0
}
