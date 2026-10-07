# Contributing to spec-gates

Thanks for considering a contribution. This repository enforces on itself
everything it ships, so the fastest way to a merged PR is to let the gates
tell you what they want.

## Development setup

```bash
npm ci              # pinned prettier + markdownlint-cli2 (the versions CI uses)
bash tests/run.sh   # 15 suites; all must pass
```

You will also want `jq`, `git`, `python3`, and `shellcheck` (the version in
`.tool-versions`) installed. Everything runs on
macOS `/bin/bash` 3.2 and on Linux — runtime shell must stay compatible with
both (no bash 4 features, no GNU-only awk/sed, no `timeout(1)`).

## The rules of the house

The project constitution (`.specify/memory/constitution.md`) is the
authoritative version; the short form:

- **Fail closed** — anything the runtime cannot read or run is a red result
  naming `file:line`, never a silent skip.
- **Provable enforcement** — a new gate class ships with attestation output,
  a canary that proves it still blocks, and test-suite coverage.
- **One policy, three boundaries** — agent, git, and CI all route through
  `verify.sh`; never re-implement a check in a boundary.
- **Projection** — the runtime is copied into consuming repos; nothing may
  assume the extension stays installed or the network is reachable.

## Making changes

1. Branch from `main` (it is protected; all changes land via PR).
2. Every behavior change lands with test coverage in `tests/`; every bug fix
   lands with a regression case that fails on the pre-fix code.
3. Run the gate locally before pushing. CI runs the identical entrypoint.
   The repository runs its own gates from source, so project the runtime
   into `.specify/gates/` first (the same copy CI makes; the copies are
   gitignored), and again after every change under `extension/runtime/`:

   ```bash
   mkdir -p .specify/gates/lib
   cp extension/runtime/*.sh .specify/gates/
   cp extension/runtime/lib/*.sh .specify/gates/lib/
   cp extension/runtime/policy.schema.json .specify/gates/
   bash .specify/gates/verify.sh --boundary ci
   bash .specify/gates/canary.sh
   bash tests/run.sh
   ```

   With the git hook stubs installed in your clone, the stubs run
   `.specify/gates/hooks/<name>`, so copy those too
   (`mkdir -p .specify/gates/hooks && cp extension/runtime/hooks/git/* .specify/gates/hooks/`)
   and list `.specify/gates/hooks/` in `.git/info/exclude`.

4. Commits follow Conventional Commits: no emoji, subject ≤ 72 characters.
5. Fill in the pull request template; CI must be green (gate, canaries,
   suites, the macOS bash 3.2 job) before review. Each PR also gets a
   **unit test results** check and a comment with per-suite counts and the
   runtime's line coverage (measured with bashcov; it reports and never
   blocks; locally, as root in a Linux container with bashcov installed:
   `bash scripts/coverage.sh`). Check your PR text with
   `bash .specify/gates/pr-check.sh --title "…" --body-file <file>`
   before opening it.

Larger enhancements run as numbered spec-kit features (`specs/NNN-*/`)
through specify → clarify → plan → tasks → implement. A feature's success
criteria become executable `accept` blocks in its `tasks.md`, and flipping its
spec to `Status: Complete` turns enforcement of those criteria on — see
`docs/how-it-works.md` for the pipeline.

### Bumping the shellcheck pin

The shellcheck checksums spec-gates ships, and this repository's CI uses,
live in `extension/runtime/shellcheck.sha256`. Nothing refreshes them
automatically. To move to another shellcheck release, change the version in
`.tool-versions`, then:

```bash
bash extension/runtime/install-shellcheck.sh --update
v="$(awk '$1 == "shellcheck" { print $2 }' .tool-versions)"
grep -F "shellcheck-v$v." .specify/gates/shellcheck.local.sha256 \
  >extension/runtime/shellcheck.sha256
rm .specify/gates/shellcheck.local.sha256
```

`--update` checks every asset against GitHub's published digest and writes
the four lines to `.specify/gates/shellcheck.local.sha256` (gitignored here);
the `grep` moves them into the shipped file. Commit `.tool-versions` and
`extension/runtime/shellcheck.sha256` together.

## Reporting issues

Use the issue forms (bug report / feature request). For anything
security-sensitive, see [SECURITY.md](SECURITY.md) instead of a public issue.
