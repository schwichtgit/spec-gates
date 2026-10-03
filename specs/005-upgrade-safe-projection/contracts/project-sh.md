# Contract: `project.sh`

The single projection entrypoint. bash 3.2, non-interactive, no network.

## Invocation

```sh
bash .specify/extensions/gates/runtime/project.sh [options]   # install / upgrade
bash .specify/gates/project.sh --check                        # from the projected copy
```

The source is the directory the script runs from. Run from
`.specify/gates/` (no vendored runtime next to it), only `--check` and
the half-done diagnosis are possible; it never writes.

## Options

| Option                   | Effect                                                                       |
| ------------------------ | ---------------------------------------------------------------------------- |
| `--dry-run`              | Classify and print every planned write, manager entry, notice; write nothing |
| `--check`                | Like `--dry-run`, exit 1 if anything would change (doctor/CI use)            |
| `--no-agent-hooks`       | Skip `.claude/hooks/gates/` and the settings merge                           |
| `--no-git-hooks`         | Skip git boundary wiring and the git probe                                   |
| `--take-upstream <path>` | Resolve one `edited` conflict by replacing (repeatable)                      |
| `--keep-local <path>`    | Resolve one `edited` conflict by keeping it and adding a hold (repeatable)   |
| `--wire-manager`         | Apply the detected manager's entry (husky/lefthook/pre-commit)               |
| `--add-lint-ignores`     | Append missing projected paths to `.prettierignore` / markdownlint ignores   |
| `--allow-downgrade`      | Permit a manifest newer than the vendored version                            |
| `--skip-canary`          | Tests only; refused unless `GATES_TEST=1`                                    |

## Order of operations

1. Preflight: jq, git, sha256 tool; install state (data-model). Exit 2 on
   `removed`, `mismatch`, a corrupt manifest, or a downgrade.
2. Warn on a `dev` install (FR-018). Restore vendored exec bits (FR-005a).
3. Classify every target (data-model). Any unresolved `edited` → exit 3
   with the list and the two resolution flags. Nothing written yet.
4. Write: runtime files, exec bits, `.runtime-version`,
   `.specify/gates/.gitignore` entry, agent hooks + settings merge
   (append-only, identical command paths skipped).
5. Git boundary: detect the manager. `plain` → install the stub.
   Known manager without `--wire-manager` → print the entry and exit 1
   after step 7. `unknown` → print the call-through, exit 1 after step 7.
6. Write the manifest (atomic), then append holds for `--keep-local`.
7. Report: policy notices (absent defaulted schema properties), missing
   lint ignores, CI drift, holds.
8. Prove: `canary.sh` (all) and the git probe (contracts/hooks.md).
   Any failure → exit 1 naming the canary or hook.

Steps 4–6 are idempotent: a second run with the same version writes
nothing and prints `no changes`.

## Exit codes

| Code | Meaning                                                         |
| ---- | --------------------------------------------------------------- |
| 0    | projected (or nothing to do) and proven                         |
| 1    | projected, but a proof failed or wiring needs the maintainer    |
| 2    | refused before writing (preflight, half-done, corrupt manifest) |
| 3    | conflicts need a decision; nothing written                      |

## Output

Human-readable lines prefixed `project:`; each refusal names the file and
the next command. The command docs (`init`, `upgrade`) tell the agent to
run `--dry-run` first, show the output, then run the real invocation
once.
