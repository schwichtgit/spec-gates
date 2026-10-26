# Contract: verify.sh report, attestation and walk

Changes to `verify.sh` output for project gates. Everything else in the
feature 001 CLI contract
([cli-contracts.md](../../001-provable-enforcement-gate/contracts/cli-contracts.md))
is unchanged.

## Text report

Project gates follow the built-in gates, in declared order:

```text
gates: boundary=agent failed=0 warnings=0
  [pass] prettier
  [pass] markdownlint
  [pass] shellcheck
  [pass] lint
  [pass] typecheck
  [pass] test
  [skipped] build -- skipped by declaration at agent
  [skipped] manifest -- skipped by declaration at agent
  [pass] spec
  [pass] parity
```

A failing gate shows its summary line by the 0.4.2 rules (`##gates-fail##`,
else the last non-empty line). A timeout reads
`[fail] test -- timeout after 1200s at load 3.10`.

## `--json`

Each project gate is an entry in `gates[]` with `name`, `status`
(`pass`, `fail`, `warn`, `skipped`, `planned`) and `detail`. A declared skip
has `"status": "skipped"`, `"detail": "skipped by declaration at agent"`.

## Attestation (`attestations.jsonl`)

Gate entries as in the feature 001 schema, plus for a declared skip:

```json
{
  "name": "build",
  "result": "skipped",
  "reason": "skipped by declaration at agent",
  "declared_skip": "agent",
  "duration_s": 0,
  "bin": null,
  "version": null,
  "pinned": null,
  "candidates": null,
  "checked": null
}
```

The feature 001 schema (`attestation-record.schema.json`) gains the optional
`declared_skip` property (`enum: ["agent", "git"]`).

## Parity gate

In addition to tool versions, `parity` fails when a declared project gate
did not run and was not skipped by a declaration naming the current
boundary. At `ci` that means: every declared gate ran.

```text
  [fail] parity -- declared gates not run at ci: build
```

## Gate lock deferral (agent boundary)

When another gate run holds the working tree, the agent-boundary run exits 0
and names the gates it does not run (FR-019):

```text
gates: skipped: the gate run of pid 4242 (git) is in progress; deferred: prettier, markdownlint, lint, typecheck, test, spec, parity
```

With `--json`:

```json
{
  "result": "skipped",
  "boundary": "agent",
  "reason": "skipped: the gate run of pid 4242 (git) is in progress",
  "deferred": [
    "prettier",
    "markdownlint",
    "lint",
    "typecheck",
    "test",
    "spec",
    "parity"
  ]
}
```

A gate with `skip_at: ["agent"]` would not have run, so it is not in
`deferred`; it is named in the same line as `skipped by declaration at agent:
<names>` and under `--json` as `"declared_skip": ["<names>"]`, so every gate
the run does not run is named (constitution, Principle III).

## Exit codes

Unchanged (feature 001 CLI contract): 0 every gate green (warnings
allowed), 1 internal error (a bad argument, a missing or invalid policy,
including a refused project gate key: no gate ran), 2 at least one gate
failed.

## `verify.sh --walk`

```text
verify.sh --walk [--boundary agent|git|ci] [--json]
```

Runs only the built-in walk (prettier, markdownlint, shellcheck, each when
the policy enables it), whatever the orchestrator. Prints the same report
shape for those gates only; writes no attestation; skips spec, contract,
parity and project gates. Called from inside a gate run it joins that run's
lock; standalone it takes the lock. Exit codes as above. Stable across minor
releases: custom commands call this, not `lib/formatter-dispatch.sh`.

## Doctor

```text
  [ok]  gate lint (error, 900s): runs at every boundary
  [ok]  gate build (error, 900s): skipped by declaration at agent
  [rec] custom_command calls lib/formatter-dispatch.sh: use `bash .specify/gates/verify.sh --walk` (stable)
```
