#!/bin/bash
# shellcheck shell=bash
set -uo pipefail

# spec-gates projection: copy the enforcement runtime from the installed
# extension into the project, wire the agent and git boundaries, record what
# was written, and prove the result with the canary suite. One invocation,
# so a reviewer (or a permission classifier) approves one command, not one
# file write per runtime file (issue #72).
#
#   bash .specify/extensions/gates/runtime/project.sh [options]   # install / upgrade
#   bash .specify/gates/project.sh --check                        # projected copy
#
# Contract: specs/005-upgrade-safe-projection/contracts/project-sh.md.
# Never writes .specify/gates/policy.json. Never runs without a policy.
#
# Options:
#   --dry-run               print the plan, write nothing
#   --check                 like --dry-run; exit 1 if anything would change
#   --no-agent-hooks        skip .claude/hooks/gates/ and the settings merge
#   --no-git-hooks          skip git hook wiring
#   --take-upstream <path>  replace one locally edited file (repeatable)
#   --keep-local <path>     keep one locally edited file and hold it (repeatable)
#   --allow-downgrade       accept a manifest newer than this version
#   --skip-canary           tests only (needs GATES_TEST=1)
#
# Exit: 0 projected and proven (or nothing to do) | 1 projected, but a proof
# failed or a hook needs the maintainer | 2 refused before writing | 3 local
# edits need a decision (nothing written).

say() { printf 'project: %s\n' "$*"; }
refuse() { # <message...>: exit 2 before anything is written
    local l
    for l in "$@"; do printf 'project: %s\n' "$l" >&2; done
    exit 2
}
inlist() { [[ -n "$1" ]] && printf '%s\n' "$1" | grep -qxF -- "$2"; }
addline() { if [[ -z "$1" ]]; then printf '%s' "$2"; else printf '%s\n%s' "$1" "$2"; fi; }

ARGS="$*" # for the projected copy's hand-off to the installed one
DRY=0 CHECK=0 AGENT=1 GITHOOKS=1 DOWNGRADE=0 SKIPCANARY=0
TAKE="" KEEP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --check) CHECK=1 DRY=1 ;;
        --no-agent-hooks) AGENT=0 ;;
        --no-git-hooks) GITHOOKS=0 ;;
        --take-upstream) [[ $# -ge 2 ]] || refuse "--take-upstream needs a path"; TAKE="$(addline "$TAKE" "$2")"; shift ;;
        --keep-local) [[ $# -ge 2 ]] || refuse "--keep-local needs a path"; KEEP="$(addline "$KEEP" "$2")"; shift ;;
        --allow-downgrade) DOWNGRADE=1 ;;
        --skip-canary) SKIPCANARY=1 ;;
        -h | --help) sed -n '5,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) refuse "unknown option: $1 (see --help)" ;;
    esac
    shift
done
if [[ "$SKIPCANARY" -eq 1 && "${GATES_TEST:-}" != "1" ]]; then
    refuse "--skip-canary is for the test suite only (GATES_TEST=1); projection must prove itself"
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[[ -d "$ROOT/.specify" ]] || refuse "$ROOT is not a Spec Kit project (no .specify/); run specify init first"
VEND="$ROOT/.specify/extensions/gates/runtime"
REL_ADD='specify extension add gates --from <the versioned release URL you verified> (README "Upgrade")'

for t in jq cmp; do
    command -v "$t" >/dev/null 2>&1 || refuse "$t not found; install it and re-run"
done
for l in manifest.sh install-state.sh; do
    [[ -f "$SRC/lib/$l" ]] || refuse "runtime library $SRC/lib/$l is missing; reinstall the extension"
    # shellcheck source=/dev/null disable=SC1090,SC1091
    source "$SRC/lib/$l"
done
gates_sha256 "$SRC/project.sh" >/dev/null || refuse "neither sha256sum nor shasum is available; install one and re-run"

# --- Where are we running from? -------------------------------------------
STATE="$(gates_install_state "$ROOT")"
if [[ "$SRC" -ef "$ROOT/.specify/gates" ]]; then
    # The projected copy. After `extension remove` it is the only copy left,
    # so it diagnoses a half-done remove+add; it never projects itself.
    case "$STATE" in
        removed)
            refuse "the gates extension was removed but not added back (half-done upgrade)." \
                "Finish it: $REL_ADD" \
                "Then run: bash .specify/extensions/gates/runtime/project.sh"
            ;;
        mismatch)
            refuse "the extension registry and .specify/extensions/gates/ disagree (interrupted install?)." \
                "Re-run: specify extension remove gates --keep-config --force && $REL_ADD"
            ;;
        absent) refuse "the gates extension is not installed. Install it: $REL_ADD" ;;
    esac
    [[ -f "$VEND/project.sh" ]] || refuse "the installed extension has no project.sh (older than 0.4.0?). Upgrade it: $REL_ADD"
    if [[ "$CHECK" -eq 1 ]]; then
        # Same flags, so a --no-agent-hooks project is checked as one.
        # shellcheck disable=SC2086  # the original options, split as typed
        exec bash "$VEND/project.sh" $ARGS
    fi
    refuse "run the installed copy, not the projected one: bash .specify/extensions/gates/runtime/project.sh"
fi
VENDORED=0
if [[ "$SRC" -ef "$VEND" ]]; then
    VENDORED=1
    [[ "$STATE" == "mismatch" ]] \
        && refuse "the extension registry and .specify/extensions/gates/ disagree (interrupted install?)." \
            "Re-run: specify extension remove gates --keep-config --force && $REL_ADD"
fi

VERSION="$(gates_extension_version "$SRC/../extension.yml")"
[[ -n "$VERSION" ]] || refuse "cannot read the extension version from $SRC/../extension.yml"
[[ -f "$ROOT/.specify/gates/policy.json" ]] \
    || refuse "no .specify/gates/policy.json yet. /speckit.gates.init infers and approves the policy before projecting."

gates_manifest_load "$ROOT"
if [[ "$GATES_MANIFEST_STATUS" == "corrupt" ]]; then
    refuse "$GATES_MANIFEST_REL is corrupt ($GATES_MANIFEST_ERROR)." \
        "It records what projection wrote, so it is never overwritten blindly. Inspect it, then delete it to treat every differing file as a local edit."
fi
if [[ "$GATES_MANIFEST_STATUS" == "ok" && "$DOWNGRADE" -eq 0 \
    && "$(gates_version_cmp "$GATES_MANIFEST_VERSION" "$VERSION")" == "1" ]]; then
    refuse "the runtime was projected by $GATES_MANIFEST_VERSION, newer than this extension ($VERSION)." \
        "Install the newer extension, or pass --allow-downgrade."
fi
gates_holds_load "$ROOT"
# shellcheck disable=SC2034  # read by gates_classify in lib/manifest.sh
GATES_KNOWN_FILE="$SRC/lib/known-releases.sha256"

# --- Plan --------------------------------------------------------------------
[[ "$STATE" == "dev" ]] && say "warning: this is a --dev install. Its skills are symlinks into .specify/extensions/gates/.specify-dev/, which do not exist in other clones; install from a release zip instead."

TABLE="$(gates_projection_table "$SRC" "$AGENT")"
targets="$(printf '%s\n' "$TABLE" | cut -f2)"
for p in $TAKE $KEEP; do
    inlist "$targets" "$p" || refuse "$p is not a projected file"
done

WRITES="" CONFLICTS="" HELD="" STALE="" KEPT="" NEWMAN="" CHANGES=""
while IFS=$'\t' read -r s r; do
    [[ -n "$s" ]] || continue
    st="$(gates_classify "$ROOT" "$SRC/$s" "$r")" || refuse "cannot hash $r"
    # --keep-local is honored for any existing file, edited or not: the
    # maintainer asked for a hold.
    if inlist "$KEEP" "$r" && [[ "$st" != "held" ]]; then
        [[ "$st" == "absent" ]] && refuse "--keep-local $r: there is no local file to keep"
        st=edited
    fi
    case "$st" in
        upstream) ;;
        absent | pristine) WRITES="$(addline "$WRITES" "$s"$'\t'"$r")" ;;
        held)
            HELD="$(addline "$HELD" "$r")"
            cmp -s "$SRC/$s" "$ROOT/$r" && STALE="$(addline "$STALE" "$r")"
            ;;
        edited)
            if inlist "$TAKE" "$r"; then
                WRITES="$(addline "$WRITES" "$s"$'\t'"$r")"
            elif inlist "$KEEP" "$r"; then
                KEPT="$(addline "$KEPT" "$r")"
            else
                CONFLICTS="$(addline "$CONFLICTS" "$r")"
            fi
            ;;
    esac
    case "$st" in
        held | edited)
            if [[ "$st" == "edited" ]] && inlist "$TAKE" "$r"; then
                NEWMAN="$(addline "$NEWMAN" "$(gates_sha256 "$SRC/$s")  $r")"
            else
                rec="$(gates_manifest_hash "$r")"
                [[ -n "$rec" ]] && NEWMAN="$(addline "$NEWMAN" "$rec  $r")"
            fi
            ;;
        *) NEWMAN="$(addline "$NEWMAN" "$(gates_sha256 "$SRC/$s")  $r")" ;;
    esac
done <<<"$TABLE"

if [[ -n "$CONFLICTS" ]]; then
    say "these projected files were changed locally since they were projected:" >&2
    printf '%s\n' "$CONFLICTS" | sed 's/^/project:   /' >&2
    say "nothing was written. Decide per file and re-run with:" >&2
    say "  --take-upstream <path>   replace it with $VERSION" >&2
    say "  --keep-local <path>      keep it; it is added to $GATES_HOLDS_REL and never overwritten" >&2
    exit 3
fi

# Planned side changes beyond file copies.
RTV_FILE="$ROOT/.specify/gates/.runtime-version"
NEED_RTV=0
[[ "$(head -n 1 "$RTV_FILE" 2>/dev/null || true)" == "$VERSION" ]] || NEED_RTV=1
GI="$ROOT/.specify/gates/.gitignore"
NEED_GI=0
grep -qxF attestations.jsonl "$GI" 2>/dev/null || NEED_GI=1

SETTINGS="$ROOT/.claude/settings.json"
FRAG="$SRC/hooks/claude/settings.fragment.json"
MERGED=""
if [[ "$AGENT" -eq 1 ]]; then
    [[ -f "$FRAG" ]] || refuse "$FRAG is missing; reinstall the extension"
    cur='{}'
    if [[ -f "$SETTINGS" ]]; then
        jq -e . "$SETTINGS" >/dev/null 2>&1 || refuse "$SETTINGS is not valid JSON; fix it and re-run"
        cur="$(cat "$SETTINGS")"
    fi
    # Append-only, idempotent: add each fragment hook whose command path is
    # not already wired for that event; never remove or reorder user entries.
    MERGED="$(jq --slurpfile f "$FRAG" '
        reduce ($f[0].hooks | to_entries[]) as $e (.;
            reduce $e.value[] as $entry (.;
                ([(.hooks[$e.key] // [])[] | (.hooks // [])[] | .command]) as $have
                | ($entry | .hooks |= map(select(.command as $c | ($have | any(. == $c)) | not))) as $new
                | if ($new.hooks | length) > 0
                  then .hooks[$e.key] = ((.hooks[$e.key] // []) + [$new])
                  else . end))' <<<"$cur")" || refuse "cannot merge the agent hook settings into $SETTINGS"
    if [[ "$(jq -S . <<<"$cur")" == "$(jq -S . <<<"$MERGED")" ]]; then
        MERGED=""
    fi
fi

# Git boundary plan: the stub goes into the hooks directory git reads,
# unless another tool owns it.
HOOKPLAN="" FOREIGN="" GITNOTE=""
STUB="$SRC/hooks/git/stub.sh"
if [[ "$GITHOOKS" -eq 1 ]]; then
    if ! command -v git >/dev/null 2>&1 || ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        GITNOTE="not a git work tree: the git boundary is not wired. Run this again after git init."
    else
        HOOKSDIR="$(cd "$ROOT" && git rev-parse --git-path hooks)"
        [[ "$HOOKSDIR" == /* ]] || HOOKSDIR="$ROOT/$HOOKSDIR"
        HOOKSPATH_SET="$(git -C "$ROOT" config core.hooksPath 2>/dev/null || true)"
        for n in pre-commit commit-msg; do
            f="$HOOKSDIR/$n"
            if [[ -n "$HOOKSPATH_SET" ]]; then
                # Another tool configured core.hooksPath; its files are not
                # ours to write (adapters land with #74).
                if [[ ! -f "$f" ]] || ! grep -qF ".specify/gates/hooks/$n" "$f"; then
                    FOREIGN="$(addline "$FOREIGN" "$n")"
                fi
            elif [[ ! -e "$f" ]] || cmp -s "$STUB" "$f"; then
                { [[ -e "$f" ]] && [[ -x "$f" ]]; } || HOOKPLAN="$(addline "$HOOKPLAN" "$n")"
            elif grep -q 'spec-gates hook stub\|Git commit-msg hook\.\|Git pre-commit hook --' "$f"; then
                HOOKPLAN="$(addline "$HOOKPLAN" "$n")" # an older stub or a copied gates hook
            elif ! grep -qF ".specify/gates/hooks/$n" "$f"; then
                FOREIGN="$(addline "$FOREIGN" "$n")"
            fi
        done
    fi
fi

NEED_MAN=0
if [[ "$GATES_MANIFEST_STATUS" != "ok" || "$GATES_MANIFEST_VERSION" != "$VERSION" ]] \
    || [[ "$(printf '%s\n' "$NEWMAN" | sort -k2)" != "$(printf '%s\n' "$GATES_MANIFEST_BODY" | sort -k2)" ]]; then
    NEED_MAN=1
fi

VEXEC=""
if [[ "$VENDORED" -eq 1 ]]; then
    # Spec Kit's zip extraction keeps the execute bit on *.sh only, so the
    # extension-less git hooks arrive 644 (FR-005a).
    for f in "$SRC"/*.sh "$SRC"/lib/*.sh "$SRC"/hooks/git/* "$SRC"/hooks/claude/*.sh; do
        [[ -f "$f" && ! -x "$f" ]] && VEXEC="$(addline "$VEXEC" "$f")"
    done
fi

[[ -n "$WRITES" ]] && CHANGES="$(addline "$CHANGES" "$(printf '%s\n' "$WRITES" | cut -f2 | sed 's/^/write /')")"
[[ -n "$KEPT" ]] && CHANGES="$(addline "$CHANGES" "$(printf '%s\n' "$KEPT" | sed 's/^/hold (keep local) /')")"
[[ "$NEED_RTV" -eq 1 ]] && CHANGES="$(addline "$CHANGES" "record runtime version $VERSION")"
[[ "$NEED_GI" -eq 1 ]] && CHANGES="$(addline "$CHANGES" "add attestations.jsonl to .specify/gates/.gitignore")"
[[ -n "$MERGED" ]] && CHANGES="$(addline "$CHANGES" "merge agent hooks into .claude/settings.json")"
[[ -n "$HOOKPLAN" ]] && CHANGES="$(addline "$CHANGES" "$(printf '%s\n' "$HOOKPLAN" | sed 's/^/install the gates stub as git hook /')")"
[[ -n "$VEXEC" ]] && CHANGES="$(addline "$CHANGES" "restore execute bits on $(printf '%s\n' "$VEXEC" | wc -l | tr -d ' ') vendored file(s)")"
[[ "$NEED_MAN" -eq 1 ]] && CHANGES="$(addline "$CHANGES" "write $GATES_MANIFEST_REL")"

report_side() {
    if [[ -n "$HELD" ]]; then
        say "held (never overwritten, see $GATES_HOLDS_REL):"
        printf '%s\n' "$HELD" | sed 's/^/project:   /'
    fi
    if [[ -n "$STALE" ]]; then
        say "stale holds (the held file now equals $VERSION; remove the line from $GATES_HOLDS_REL):"
        printf '%s\n' "$STALE" | sed 's/^/project:   /'
    fi
    local missing
    missing="$(gates_ci_missing "$ROOT")"
    if [[ -n "$missing" ]]; then
        say "the CI pipeline ($(gates_ci_files "$ROOT" | tr '\n' ' ')) lacks these template steps:"
        printf '%s\n' "$missing" | sed 's/^/project:   /'
        say "  add them from .specify/extensions/gates/ci/, or record a deliberate omission as ci:<step> in $GATES_HOLDS_REL"
    fi
    [[ -n "$GITNOTE" ]] && say "$GITNOTE"
    if [[ -n "$FOREIGN" ]]; then
        say "another tool owns these git hooks, so they were not touched:"
        local n
        for n in $FOREIGN; do
            say "  $n: add this line to it to run the gates hook:"
            say "    bash \"\$(git rev-parse --show-toplevel)/.specify/gates/hooks/$n\" \"\$@\" || exit \$?"
        done
    fi
    return 0
}

if [[ "$DRY" -eq 1 ]]; then
    say "spec-gates $VERSION, install state: $STATE"
    if [[ -z "$CHANGES" ]]; then
        say "no changes"
    else
        say "planned changes:"
        printf '%s\n' "$CHANGES" | sed 's/^/project:   /'
    fi
    report_side
    # An unwired git hook is pending work too, even when no file changes.
    if [[ "$CHECK" -eq 1 ]] && [[ -n "$CHANGES" || -n "$FOREIGN" ]]; then exit 1; fi
    exit 0
fi

# --- Write -------------------------------------------------------------------
fail_write() { say "write failed: $*" >&2; exit 1; }
while IFS=$'\t' read -r s r; do
    [[ -n "$s" ]] || continue
    mkdir -p "$(dirname "$ROOT/$r")" || fail_write "mkdir for $r"
    cp "$SRC/$s" "$ROOT/$r" || fail_write "$r"
done <<<"$WRITES"
# Execute bits on every projected script, not only the files written now:
# git and Claude Code silently skip a hook that is not executable.
while IFS=$'\t' read -r s r; do
    [[ -n "$r" && -f "$ROOT/$r" && ! -x "$ROOT/$r" ]] && gates_is_exec_target "$r" \
        && { chmod +x "$ROOT/$r" || fail_write "chmod $r"; }
done <<<"$TABLE"
if [[ -n "$VEXEC" ]]; then
    while IFS= read -r f; do chmod +x "$f" || fail_write "chmod $f"; done <<<"$VEXEC"
fi
[[ "$NEED_RTV" -eq 1 ]] && { printf '%s\n' "$VERSION" >"$RTV_FILE" || fail_write "$RTV_FILE"; }
[[ "$NEED_GI" -eq 1 ]] && { echo attestations.jsonl >>"$GI" || fail_write "$GI"; }
if [[ -n "$MERGED" ]]; then
    mkdir -p "$ROOT/.claude" || fail_write ".claude/"
    { jq . <<<"$MERGED" >"$SETTINGS.tmp.$$" && mv -f "$SETTINGS.tmp.$$" "$SETTINGS"; } || fail_write "$SETTINGS"
fi
if [[ -n "$HOOKPLAN" ]]; then
    mkdir -p "$HOOKSDIR" || fail_write "$HOOKSDIR"
    for n in $HOOKPLAN; do
        { cp "$STUB" "$HOOKSDIR/$n" && chmod +x "$HOOKSDIR/$n"; } || fail_write "$HOOKSDIR/$n"
    done
fi
if [[ -n "$KEPT" ]]; then
    printf '%s\n' "$KEPT" >>"$ROOT/$GATES_HOLDS_REL" || fail_write "$GATES_HOLDS_REL"
fi
if [[ "$NEED_MAN" -eq 1 ]]; then
    printf '%s\n' "$NEWMAN" | grep -v '^$' | gates_manifest_write "$ROOT" "$VERSION" || fail_write "$GATES_MANIFEST_REL"
fi

if [[ -z "$CHANGES" ]]; then
    say "no changes (spec-gates $VERSION already projected)"
else
    say "projected spec-gates $VERSION:"
    printf '%s\n' "$CHANGES" | sed 's/^/project:   /'
fi
report_side

# --- Prove -------------------------------------------------------------------
RC=0
if [[ "$SKIPCANARY" -eq 0 ]]; then
    say "running the canary suite (every gate must block a planted violation):"
    if ! (cd "$ROOT" && CLAUDE_PROJECT_DIR="$ROOT" bash .specify/gates/canary.sh); then
        say "FAILED: a canary was accepted or could not run; see above. Run /speckit.gates.doctor." >&2
        RC=1
    fi
fi
[[ -n "$FOREIGN" ]] && RC=1
exit "$RC"
