# Contributing to spec-gates

Thanks for considering a contribution. This repository enforces on itself
everything it ships, so the fastest way to a merged PR is to let the gates
tell you what they want.

## Development setup

```bash
npm ci              # pinned prettier + markdownlint-cli2 (the versions CI uses)
bash tests/run.sh   # 8 suites — all must pass
```

You will also want `jq`, `git`, and `shellcheck` installed. Everything runs on
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
3. Run the gate locally before pushing — CI runs the identical entrypoint:

   ```bash
   bash .specify/gates/verify.sh --boundary agent
   bash tests/run.sh
   ```

4. Commits follow Conventional Commits: no emoji, subject ≤ 72 characters.
5. Fill in the pull request template; CI must be green (gate + canaries +
   suites) before review.

Larger enhancements run as numbered spec-kit features (`specs/NNN-*/`)
through specify → clarify → plan → tasks → implement. A feature's success
criteria become executable `accept` blocks in its `tasks.md`, and flipping its
spec to `Status: Complete` turns enforcement of those criteria on — see
`docs/how-it-works.md` for the pipeline.

## Reporting issues

Use the issue forms (bug report / feature request). For anything
security-sensitive, see [SECURITY.md](SECURITY.md) instead of a public issue.
