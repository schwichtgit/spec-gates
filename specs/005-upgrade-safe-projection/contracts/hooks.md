# Contract: Hook Behavior Changes

## Agent hooks never silently allow (#83)

`protect-files.sh`, `validate-bash.sh`. Raw mode = jq missing or the
payload is not valid JSON (research R10).

| Condition                                                        | Result                  |
| ---------------------------------------------------------------- | ----------------------- |
| raw mode, a built-in block rule matches the raw payload          | exit 2 (block)          |
| raw mode, no match (validate-bash)                               | exit 0 + doctor warning |
| raw mode, protect-files, policy declares `protected_files.extra` | ask                     |
| raw mode, protect-files, no extra entries                        | exit 0 + doctor warning |
| raw mode, `file_path` not extractable                            | ask                     |
| unexpected error (ERR trap)                                      | ask, names the line     |
| `lib/policy.sh` present but fails to source                      | ask (protect-files)     |
| field (`file_path` / `command`) absent/empty                     | exit 0                  |

## protect-files decisions (#71)

- **Block** (exit 2, stderr reason): `.env`/`.env.*` (not `*.example`,
  `*.sample`, `*.template`), SSH key names, `*.pem *.key *.crt *.p12
*.pfx *.jks *.keystore`, exact credential names, sensitive directories,
  lock files, `protected_files.extra`.
- **Ask** (exit 0, stdout JSON; shape verified in research R14):

  ```json
  {
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "ask",
      "permissionDecisionReason": "gates: file name contains 'secret'; confirm this is not a credential file"
    }
  }
  ```

- **Allow**: everything else, then local rules.

## Bulk staging (#71)

With `git.block_bulk_staging: true`, validate-bash refuses `git add` with
`-A`, `--all`, `.`, `:/`, `*`, or a directory argument (trailing `/` or
an existing directory relative to the payload `cwd`). The refusal names
the knob. This applies at the agent boundary only; the git boundary
cannot see how the index was filled.

## Local rules (#71)

For hook `<h>`, after the shipped checks allow:
`for f in .specify/gates/hooks.local.d/<h>/*.sh` (lexical order) run
`bash "$f"`. Agent hooks pass the original stdin, git hooks their
original arguments. Exit ≠ 0 → refuse with the script's stderr, prefixed
`gates(local <h>/<file>)`. An unreadable file → refuse. A missing
directory → nothing to run.

## Git probe (#74)

Projected `hooks/pre-commit` and `hooks/commit-msg`: when
`GATES_PROBE=1`, print `gates-probe:<name>:<runtime-version>` to stderr
and exit 1. This runs before reading policy or arguments.

Prover (doctor, `project.sh`): for each name, resolve
`"$(git rev-parse --git-path hooks)/<name>"`, run it directly with
`GATES_PROBE=1` and a temp message file, and pass only when the output
contains `gates-probe:<name>:`. The failure names the resolved path and
the detected manager.

## Manager entries (#74)

| Manager    | Entry (appended)                                                                                                         |
| ---------- | ------------------------------------------------------------------------------------------------------------------------ |
| husky      | `.husky/<name>`: `bash .specify/gates/hooks/<name> "$@"`                                                                 |
| lefthook   | top-level `<name>:` block, `commands: spec-gates: run: bash .specify/gates/hooks/<name>` (plus `{1}` for commit-msg)     |
| pre-commit | `repos:` item `repo: local` with ids `spec-gates-pre-commit` / `spec-gates-commit-msg`, `language: system`, `stages` set |
| unknown    | printed call-through only                                                                                                |

YAML entries are appended only when the hook key (lefthook) or the
`spec-gates-*` id (pre-commit) is absent and the file has no tab
indentation. Otherwise the snippet is printed, exit 1.

## Constitution parser (#82)

A `###` heading is a principle only under `## Core Principles`. A
`gates:enforce` marker under any other `##` section →
`MALFORMED\t<line>\t<heading>\tgates:enforce marker outside Core Principles`.

## doctor additions

| Check                                      | Severity                                                       |
| ------------------------------------------ | -------------------------------------------------------------- |
| registered gates skill symlinked/missing   | fail                                                           |
| `.specify-dev/` present                    | warn                                                           |
| vendored script without exec bit           | rec (nothing runs the vendored copy; `project.sh` restores it) |
| stale hold                                 | fail                                                           |
| CI step missing, not acknowledged          | fail                                                           |
| git probe marker absent                    | fail                                                           |
| install state `removed` / `mismatch`       | fail                                                           |
| `--installed-only`: skips runtime sections | —                                                              |
