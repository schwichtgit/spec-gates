# Contract: Accept Block Authoring Grammar

The user-facing contract for expressing an acceptance criterion as an
executable check in a feature's `tasks.md` (Clarifications, 2026-07-07).
This grammar is what the parser (research R1) implements and what the
canary fixture and 002's own dogfooded `tasks.md` are written against.

## Form

A fenced code block whose info string is exactly `accept`, placed
immediately after the task or criterion line it verifies (blank lines
between the task line and the fence are allowed; any other content breaks
the association):

````markdown
- [x] T012 Gate blocks drift for complete features

  ```accept
  # verifies: SC-001
  tests/spec-gate/drift-blocks.sh
  ```
````

## Rules

1. **Placement**: the block associates with the nearest preceding task line
   (`- [ ]` / `- [x]` / `- [X]`, leading whitespace allowed) in the same
   file. A block with no preceding task line is a parse error.
2. **Info string**: `accept` (exact, lowercase). Fences with any other info
   string are ordinary code samples and are ignored by the gate.
   The fence is a CommonMark-style run of **3 or more** backticks, closed
   only by a backtick-only line at least as long as the opening run — a
   block whose body itself contains ` ``` ` must use a longer outer fence
   (` ````accept `), which is exactly what prettier rewrites such blocks
   to. Exact-three matching would let a formatter pass silently drop a
   criterion.
3. **`# verifies:` reference** (optional): if the first non-blank interior
   line matches `# verifies: <ID>`, `<ID>` (e.g. `SC-001`) is recorded as
   the explicit criterion reference. Additional `#` comment lines are
   allowed anywhere and are passed through to the shell.
4. **Commands**: all interior lines, dedented by the fence's indentation,
   form one shell script executed with the project's `/bin/bash` from the
   repository root, under `bash -eo pipefail`. Exit `0` = the criterion
   holds; any nonzero exit = it does not. Multi-line sequences are
   allowed, and every line counts: a failing command or pipeline stage
   anywhere in the block fails it (#236). A `!`-negated command never
   trips errexit, so a line starting with `!` that is followed by another
   command line is a parse error naming `tasks.md:<line>`; write
   `test -z "$(...)"`, `if ...; then exit 1; fi`, or `! cmd || exit 1`
   instead. A `!` on the block's last command line stays allowed, since
   its status is the block's exit status.
5. **At least one command**: a block containing only comments and blank
   lines is a parse error (an empty criterion would be a silent no-op —
   exactly the failure class this project forbids).
6. **Termination**: an opening ` ```accept ` fence with no closing fence
   in the file is a parse error naming the opening line.
7. **Read-only contract**: a block must not modify the repository. The
   runner snapshots it around each block and any delta fails the block,
   naming what changed (research R5, #164):
   - the working tree: `git status --porcelain` (every untracked file
     listed) plus a content hash of each dirty or untracked file, so a
     write to an already-modified file is caught too
     (`working tree modified: <paths>`);
   - git configuration in every scope (`git config --list --show-origin`),
     except `branch.*`, which creating a branch in any worktree writes
     (`git config modified: <keys>`);
   - the hooks directory git uses (`git rev-parse --git-path hooks`, which
     follows `core.hooksPath`): every file's exec bit and content hash
     (`git hooks modified: <names>`);
   - the info directory (`git rev-parse --git-path info`: attributes,
     exclude, sparse-checkout), the same way
     (`git info files modified: <names>`);
   - index entries flagged skip-worktree or assume-unchanged
     (`git ls-files -v`): the flag and a content hash, since `git status`
     does not report edits to a flagged file
     (`index flags modified: <paths>`);
   - this worktree, when it is a linked one (`<common-dir>/worktrees/<name>`):
     its path and lock (`worktrees modified: <name>`);
   - `HEAD` (commit and symbolic target) and every ref except
     `refs/remotes/*`, which a background fetch moves, and except the
     branches another worktree has checked out or is rebasing, in either
     snapshot (`refs modified: <refs>`);
   - gitignored files: the set of ignored roots
     (`git ls-files -o -i --directory`), and any file or directory under
     them whose ctime is newer than a marker taken just before the block
     (`ignored files modified: <paths>`). ctime moves on every write and
     cannot be set back by unprivileged code; it is used instead of
     content hashes so a large `node_modules/` costs a directory walk, not
     a full read, per block.

   Exempt: untracked or ignored paths the gate itself writes
   (`.specify/gates/attestations.jsonl` and its temp file, appended by a
   nested `verify.sh`), plus the globs in `spec.snapshot_exclude`, meant
   for files another process writes while blocks run. Tracked files are
   never exempt. Outside a git work tree the block is not run and fails
   closed (`cannot check for mutations: not a git work tree`). Blocks
   needing scratch space must use `mktemp -d` outside the repository and
   clean up. Not covered: files outside the repository (other than the
   global and system git config), repacking (`git gc`, `git pack-refs`),
   which changes storage, not content, and other worktrees: their `HEAD`,
   per-worktree refs, entries and checked-out branches, so a commit, branch
   switch or new worktree in a sibling worktree does not fail a block, and
   a block that adds a worktree outside the project or commits in another
   worktree is not caught.

8. **Budget and processes**: each block runs under the policy's
   `spec.timeout_s` watchdog (default 30s); exceeding it fails the block.
   The block runs in its own process group, which is stopped (TERM, then
   KILL after a short grace) on a timeout and also after every block
   exits. A process still running half a second after the block exits
   fails the block (`left a process running after it exited (stopped)`),
   pass or not: its later writes would land after the snapshot. A child
   that left the group or session (`set -m`, `setsid`, a double fork) is
   found by the write end of a lease FIFO on descriptor 7, which every
   process the block starts inherits, or by `GATES_SPEC_BLOCK=<id>` in its
   environment (`/proc/<pid>/environ` on Linux, `ps -E` elsewhere); it is
   killed and fails the block
   (`left a detached process running (stopped)`). Not found: a process
   that closed descriptor 7 and also runs without the marker (started
   through `env -i` or `env -u`, or its environment overwritten in
   memory), and on macOS, where `ps` shows no environment for
   Apple-signed binaries, an Apple-signed binary that does not hold
   descriptor 7 (a `/bin/sh` started through Node's `child_process` or
   Python's `subprocess`). That is a documented limit, not a guarantee.
9. **No re-entry**: blocks run with `GATES_SPEC_EXEC=1` in the
   environment; a nested `verify.sh` call does not run accept blocks, so
   a block may invoke the gate runner (e.g. inside a sandbox fixture)
   without recursing into accept-block execution. Any caller can set the
   variable, so the skip is never silent: the `spec` gate entry is
   `skipped` with the reason in text, `--json` and the attestation, and
   the agent's Bash hook asks before a command that sets it.

## Execution environment

| Aspect      | Guarantee                                                                                         |
| ----------- | ------------------------------------------------------------------------------------------------- |
| cwd         | Repository root.                                                                                  |
| Shell       | `/bin/bash` (bash 3.2 floor — write blocks accordingly).                                          |
| Environment | Inherited from the gate run, plus `GATES_SPEC_EXEC=1`, `GATES_SPEC_BLOCK=<id>` and fd 7 (rule 8). |
| Ordering    | Serial, lexicographic by feature, then file order within `tasks.md`.                              |
| Output      | Captured; shown only when the block fails.                                                        |

## Anti-patterns

- **Formatting/fixing anything** — blocks verify, they never repair
  (mutation fails the block).
- **Depending on another block's side effects** — ordering is defined but
  isolation is the contract; each block must pass when run alone.
- **Network access** — the gate is offline by design; a block that curls
  anything will fail in CI and violates the runtime's constraints.
- **Restating the task as `true`** — an accept block that cannot fail
  proves nothing; write the command so it fails when the criterion breaks
  (the canary fixture exists to keep the _gate_ honest; honest _criteria_
  are the author's job).
