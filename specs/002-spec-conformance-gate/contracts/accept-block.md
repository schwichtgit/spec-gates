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
3. **`# verifies:` reference** (optional): if the first non-blank interior
   line matches `# verifies: <ID>`, `<ID>` (e.g. `SC-001`) is recorded as
   the explicit criterion reference. Additional `#` comment lines are
   allowed anywhere and are passed through to the shell.
4. **Commands**: all interior lines, dedented by the fence's indentation,
   form one shell script executed with the project's `/bin/bash` from the
   repository root. Exit `0` = the criterion holds; any nonzero exit = it
   does not. Multi-line sequences are allowed; `set -e` semantics are the
   author's choice (the block body is executed as written).
5. **At least one command**: a block containing only comments and blank
   lines is a parse error (an empty criterion would be a silent no-op —
   exactly the failure class this project forbids).
6. **Termination**: an opening ` ```accept ` fence with no closing fence
   in the file is a parse error naming the opening line.
7. **Read-only contract**: a block must not modify the working tree. The
   runner snapshots `git status --porcelain` around each block; any delta
   fails the block naming the changed paths (research R5). Blocks needing
   scratch space must use `mktemp -d` outside the repository and clean up.
8. **Budget**: each block runs under the policy's `spec.timeout_s`
   watchdog (default 30s); exceeding it fails the block.
9. **No re-entry**: blocks run with `GATES_SPEC_EXEC=1` in the
   environment; a nested `verify.sh` call skips the `spec` gate class, so
   a block may invoke the gate runner (e.g. inside a sandbox fixture)
   without recursing into accept-block execution.

## Execution environment

| Aspect      | Guarantee                                                            |
| ----------- | -------------------------------------------------------------------- |
| cwd         | Repository root.                                                     |
| Shell       | `/bin/bash` (bash 3.2 floor — write blocks accordingly).             |
| Environment | Inherited from the gate run; no extra variables promised in v1.      |
| Ordering    | Serial, lexicographic by feature, then file order within `tasks.md`. |
| Output      | Captured; shown only when the block fails.                           |

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
