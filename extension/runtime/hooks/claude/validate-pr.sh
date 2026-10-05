#!/bin/bash
set -euo pipefail

# PreToolUse hook for Bash commands that create or edit a pull/merge request:
# `gh pr create|new|edit`, `glab mr create|new|update` (also with the global
# -R/--repo flag before the subcommand), and `gh api` on a pulls endpoint.
# Checks the title and body
# (inline, heredoc, or --body-file) with the shared message rules in
# lib/message.sh -- the same rules commit-msg and the CI PR check apply.
# Exit 0 = allow or not a PR command, Exit 2 = block (Claude Code convention).

# A -R/--repo value before the subcommand: `gh -R o/r pr create` (#192).
REPO_OPT='([[:space:]]+(-R|--repo)([[:space:]]+|=)?[^[:space:]]+)*'
PR_RE="(gh${REPO_OPT}[[:space:]]+pr[[:space:]]+(create|new|edit)|glab${REPO_OPT}[[:space:]]+mr[[:space:]]+(create|new|update)|gh[[:space:]]+api[[:space:]])"

# refuse <reason...>: block the PR command (exit 2) with a reason the agent
# can act on.
refuse() {
    echo "PR validation failed:" >&2
    printf '%s\n' "$@" >&2
    exit 2
}

INPUT=$(cat /dev/stdin)

# Not a PR command (a cheap raw-text test that needs no tooling): allow.
if ! grep -qE "$PR_RE" <<<"$INPUT"; then
    exit 0
fi

# From here the command creates or edits a PR, and the hook fails closed
# (issue #66): a missing tool, a missing runtime, or an internal error
# blocks the command instead of letting an unchecked PR through.
trap 'refuse "ERROR: validate-pr.sh failed unexpectedly (line $LINENO)." "  Run /speckit.gates.doctor."' ERR

if ! command -v jq >/dev/null 2>&1; then
    refuse "ERROR: jq not found -- the PR hook cannot read the command." "  Install jq (see /speckit.gates.doctor)."
fi
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) \
    || refuse "ERROR: the hook input is not valid JSON."
if ! grep -qE "$PR_RE" <<<"$COMMAND"; then
    exit 0 # the match was outside the command (e.g. in a description)
fi

if ! python3 -c 'import json, re' >/dev/null 2>&1; then
    refuse "ERROR: python3 with the json module not found -- the PR hook cannot parse the command." \
        "  Install python3 with the json module (check: python3 -c \"import json\")."
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GATES_LIB_DIR="$PROJECT_ROOT/.specify/gates/lib"
if [[ ! -f "$GATES_LIB_DIR/message.sh" ]]; then
    refuse "ERROR: $GATES_LIB_DIR/message.sh not found -- the gates runtime is not projected." \
        "  Run /speckit.gates.upgrade."
fi
# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/policy.sh" ]] && source "$GATES_LIB_DIR/policy.sh"
# shellcheck source=/dev/null disable=SC1091
source "$GATES_LIB_DIR/message.sh"

# Extract title, inline body, and body file from the command line. The
# heredoc lives in a function, never inside $( ): macOS /bin/bash 3.2
# mis-parses a quoted heredoc within command substitution when its body
# holds \' and parentheses, and a syntax error exits 2 -- which Claude Code
# reads as "block", refusing every PR command.
#
# The parser splits the command into shell words the way the shell would,
# finds the PR invocation, and reads each title and body value literally
# (#170). A value the shell would change first -- a variable, a command
# substitution, a glob, an unbalanced quote -- is a value this hook cannot
# read, so it refuses, like a repeated --title/--body (gh uses the last, a
# check of the first would be a guess), a clustered short flag (-tfeat), or
# a PR command inside sh -c / eval. The one substitution read literally is
# the `"$(cat <<'EOF' ... EOF)"` heredoc body. `gh api` calls on a
# repos/<owner>/<repo>/pulls endpoint are checked through their title= and
# body= fields.
pr_parts() { # <command>
    python3 - "$1" <<'PYEOF'
import json
import re
import sys

command = sys.argv[1] if len(sys.argv) > 1 else ""

# A shell word as this parser sees it: its text with quotes removed, and
# whether that text is literal (what the shell would pass on unchanged).
# Expansions ($VAR, $(...), backticks), globs and a leading ~ make a word
# dynamic: the hook sees the text before the shell expands it.
HEREDOC = re.compile(
    r"\$\(\s*cat\s*<<-?\s*(?:'(\w+)'|\"(\w+)\"|\\(\w+)|(\w+))[^\n]*\n(.*?)\n[ \t]*(?:\1|\2|\3|\4)[ \t]*\n\s*\)",
    re.DOTALL,
)


def lex(s):
    segs, toks = [], []
    text, lit, inword = [], True, False
    i, n = 0, len(s)

    def end_word():
        nonlocal text, lit, inword
        if inword:
            toks.append(("".join(text), lit))
        text, lit, inword = [], True, False

    def end_seg():
        nonlocal toks
        end_word()
        if toks:
            segs.append(toks)
        toks = []

    while i < n:
        c = s[i]
        if c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                j, lit = n, False
            text.append(s[i + 1:j])
            inword = True
            i = j + 1
        elif c == '"':
            inword = True
            i += 1
            while i < n and s[i] != '"':
                if s[i] == "\\" and i + 1 < n:
                    if s[i + 1] in '"\\$`':
                        text.append(s[i + 1])
                        i += 2
                        continue
                    if s[i + 1] == "\n":
                        i += 2
                        continue
                    text.append("\\")
                    i += 1
                    continue
                if s[i] == "$" and s.startswith("$(", i):
                    m = HEREDOC.match(s, i)
                    if m:
                        body = m.group(5)
                        # An unquoted delimiter expands $ and backticks.
                        if m.group(4) and re.search(r"[$`\\]", body):
                            lit = False
                        text.append(body)
                        i = m.end()
                        continue
                if s[i] in "$`":
                    lit = False
                text.append(s[i])
                i += 1
            if i >= n:
                lit = False
            i += 1
        elif c == "\\":
            inword = True
            if i + 1 < n and s[i + 1] == "\n":
                i += 2
                continue
            text.append(s[i + 1:i + 2])
            i += 2
        elif c in " \t":
            end_word()
            i += 1
        elif c in "\n;&|()":
            end_seg()
            i += 1
        elif c in "<>":
            end_word()
            i += 1
        else:
            if c in "$`*?[{" or (c == "~" and not inword):
                lit = False
            text.append(c)
            inword = True
            i += 1
    end_seg()
    return segs


ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"sudo", "env", "command", "exec", "nohup", "time", "nice"}
API_PULLS = re.compile(r"(^|/)repos/[^/\s]+/[^/\s]+/pulls(/[^/\s]+)?/?$")


def out(**kw):
    print(json.dumps(kw))
    sys.exit(0)


def refuse(msg):
    out(error=msg)


PR_SUBS = {
    "gh": ("pr", ("create", "new", "edit")),
    "glab": ("mr", ("create", "new", "update")),
}


def find_pr(seg):
    """Return (kind, args) when the segment runs a PR command."""
    i = 0
    while i < len(seg) and (ASSIGN.match(seg[i][0]) or seg[i][0] in WRAPPERS):
        i += 1
    if i >= len(seg) or seg[i][0].split("/")[-1] not in ("gh", "glab"):
        return None, None
    tool = seg[i][0].split("/")[-1]
    i += 1
    # The global repository flag may come before the subcommand (#192):
    # -R <repo>, -R<repo>, --repo <repo>, --repo=<repo>.
    while i < len(seg) and seg[i][0].startswith("-"):
        a = seg[i][0]
        if a in ("-R", "--repo"):
            i += 2
        elif a.startswith("--repo=") or (a.startswith("-R") and len(a) > 2):
            i += 1
        else:
            return None, None
    w = [t[0] for t in seg[i:i + 2]]
    group, actions = PR_SUBS[tool]
    if len(w) == 2 and w[0] == group and w[1] in actions:
        return tool, seg[i + 2:]
    if tool == "gh" and w[:1] == ["api"]:
        return "api", seg[i + 1:]
    return None, None


FLAGS = {
    "gh": {"--title": "title", "-t": "title", "--body": "body", "-b": "body",
           "--body-file": "body_file", "-F": "body_file"},
    "glab": {"--title": "title", "-t": "title", "--description": "body", "-d": "body"},
}
API_VALUE = {"-f", "--raw-field", "-F", "--field", "-H", "--header", "-X", "--method",
             "-q", "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview", "--input"}


def parse_pr(kind, args):
    found = {}
    flags = FLAGS[kind]
    shorts = "".join(f[1] for f in flags if len(f) == 2)
    i = 0
    while i < len(args):
        a, alit = args[i]
        i += 1
        if a == "--":
            break
        name, val = a, None
        if a.startswith("--") and "=" in a:
            name, val = a.split("=", 1)
            vlit = alit
        elif re.match(r"^-[A-Za-z]{2,}", a) or (re.match(r"^-[A-Za-z].", a) and not a.startswith("--")):
            if any(ch in shorts for ch in a[1:]):
                refuse("ERROR: clustered short flags (%s) cannot be read reliably." % a)
            continue
        if name not in flags:
            continue
        if val is None:
            if i >= len(args):
                refuse("ERROR: %s has no value." % name)
            val, vlit = args[i]
            i += 1
        key = flags[name]
        if key in found:
            refuse("ERROR: %s is given more than once; the command would use only one of them." % name)
        if key == "body_file":
            if "`" in val or "$(" in val:
                refuse("ERROR: the %s path is a command substitution." % name)
        elif not vlit:
            refuse("ERROR: the %s value is not literal text (a variable, command substitution, glob or unbalanced quote)." % name)
        found[key] = val
    return found


def parse_api(args):
    endpoint = None
    found = {}
    i = 0
    while i < len(args):
        a, alit = args[i]
        i += 1
        name, val, vlit = a, None, alit
        if a.startswith("--") and "=" in a:
            name, val = a.split("=", 1)
        elif re.match(r"^-[A-Za-z].", a) and not a.startswith("--"):
            name, val = a[:2], a[2:]
        if name in API_VALUE:
            if val is None:
                if i >= len(args):
                    break
                val, vlit = args[i]
                i += 1
            if name == "--input":
                found["input"] = val
                continue
            if name in ("-f", "--raw-field", "-F", "--field") and "=" in val:
                key, v = val.split("=", 1)
                if key not in ("title", "body"):
                    continue
                if key in found:
                    refuse("ERROR: the %s field is given more than once." % key)
                if name in ("-F", "--field") and v.startswith("@"):
                    found["body_file" if key == "body" else "title_file"] = v[1:]
                    found[key] = None
                    continue
                if not vlit:
                    refuse("ERROR: the %s field is not literal text (a variable, command substitution, glob or unbalanced quote)." % key)
                found[key] = v
            continue
        if not a.startswith("-") and endpoint is None:
            endpoint = a
    if endpoint is None or not API_PULLS.search(endpoint):
        return None
    if "input" in found:
        refuse("ERROR: gh api --input on a pulls endpoint cannot be checked before the command runs.")
    if "title_file" in found:
        refuse("ERROR: gh api -F title=@file cannot be checked; pass the title as text.")
    return found


repo_opt = r"(\s+(-R|--repo)(\s+|=)?\S+)*"
pr_re = re.compile(r"(gh" + repo_opt + r"\s+pr\s+(create|new|edit)|glab" + repo_opt
                   + r"\s+mr\s+(create|new|update)|gh\s+api\b)")
result = None
for seg in lex(command):
    kind, args = find_pr(seg)
    if kind is None:
        # A PR command inside a shell string (sh -c, eval) is not read here.
        words = [t[0] for t in seg]
        for k, t in enumerate(words):
            if pr_re.search(t) and k > 0 and (words[k - 1] == "-c" or "eval" in words[:k]):
                refuse("ERROR: a PR command inside a shell string (sh -c, eval) cannot be checked.")
        continue
    parts = parse_api(args) if kind == "api" else parse_pr(kind, args)
    if parts is None:
        continue
    if result is not None:
        refuse("ERROR: more than one PR command in one call; run them one at a time.")
    result = parts

if result is None:
    out(pr=False)
out(pr=True, title=result.get("title") or "", body=result.get("body") or "",
    body_file=result.get("body_file") or "")
PYEOF
}
PARTS=$(pr_parts "$COMMAND")

PARSE_ERROR=$(printf '%s' "$PARTS" | jq -r '.error // empty')
if [[ -n "$PARSE_ERROR" ]]; then
    refuse "$PARSE_ERROR" "  A title or body this hook cannot read is one it cannot check. Pass each once," \
        "  as quoted text (--title \"...\" --body '...') or with --body-file <path>."
fi
if [[ "$(printf '%s' "$PARTS" | jq -r '.pr')" != "true" ]]; then
    exit 0 # the match was text, not a PR command (e.g. a commit message)
fi
TITLE=$(printf '%s' "$PARTS" | jq -r '.title')
BODY=$(printf '%s' "$PARTS" | jq -r '.body')
BODY_FILE=$(printf '%s' "$PARTS" | jq -r '.body_file')

# The hook sees the command text before the shell expands it. Resolve a
# leading ~, $VAR or ${VAR} from this hook's environment (indirect expansion,
# never eval), then relative paths against $PWD. The quoted ~ and ${ below
# are literal on purpose: they match the UNexpanded command text.
# shellcheck disable=SC2088,SC2016
resolve_body_file() { # <path>
    local p="$1" name rest
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#"~/"}" ;;
        '${'*'}'*)
            name="${p#'${'}"; rest="${name#*'}'}"; name="${name%%'}'*}"
            [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -n "${!name:-}" ]] && p="${!name}$rest"
            ;;
        '$'[A-Za-z_]*)
            name="${p#'$'}"; name="${name%%[!A-Za-z0-9_]*}"; rest="${p#'$'"$name"}"
            [[ -n "${!name:-}" ]] && p="${!name}$rest"
            ;;
    esac
    [[ "$p" != /* ]] && p="$PWD/$p"
    printf '%s\n' "$p"
}

# Fail closed (issue #65): a body this hook cannot read is a body it cannot
# check -- refuse instead of validating the title alone.
if [[ -n "$BODY_FILE" ]]; then
    if [[ "$BODY_FILE" == "-" ]]; then
        refuse "ERROR: --body-file - (stdin) cannot be checked before the command runs." \
            "  Write the body to a file in a separate step and pass its path, or use --body."
    fi
    RESOLVED="$(resolve_body_file "$BODY_FILE")"
    if [[ ! -f "$RESOLVED" || ! -r "$RESOLVED" ]]; then
        refuse "ERROR: cannot read --body-file $BODY_FILE (resolved: $RESOLVED)." \
            "  Write the file in a separate step first and pass a readable path, or use --body."
    fi
    # Both forms given: check both, whichever the tool ends up using.
    BODY="${BODY:+$BODY$'\n\n'}$(cat "$RESOLVED")"
fi

# Project-owned rules (#71) run once every shipped check allowed, so they
# can add a refusal but never remove one.
run_local_rules() {
    compgen -G "$PROJECT_ROOT/.specify/gates/hooks.local.d/validate-pr/*.sh" >/dev/null || return 0
    local llib="$PROJECT_ROOT/.specify/gates/lib/local-hooks.sh"
    if [[ ! -f "$llib" ]] || ! bash -n "$llib" 2>/dev/null; then
        refuse "ERROR: local rules exist in hooks.local.d/validate-pr, but lib/local-hooks.sh cannot load." \
            "  Run /speckit.gates.doctor."
    fi
    # shellcheck source=/dev/null disable=SC1090
    source "$llib"
    GATES_LOCAL_STDIN="$INPUT" gates_run_local "$PROJECT_ROOT" validate-pr || refuse "$GATES_LOCAL_MSG"
}

if [[ -z "$TITLE" && -z "$BODY" ]]; then
    run_local_rules
    exit 0
fi

if ! VIOLATIONS=$(gates_message_check pr "$TITLE"$'\n\n'"$BODY" 2>&1); then
    echo "PR validation failed:" >&2
    printf '%s\n' "$VIOLATIONS" | grep -v '^WARN' >&2
    exit 2
fi

run_local_rules
exit 0
