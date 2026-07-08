# spec-gates

![spec-gates — a caliper holding a growing project to its spec](docs/assets/spec-gates.png)

[![CI](https://github.com/schwichtgit/spec-gates/actions/workflows/ci.yml/badge.svg)](https://github.com/schwichtgit/spec-gates/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Deterministic quality enforcement for [Spec Kit](https://github.com/github/spec-kit) projects.**

> **Status:** early and evolving. Verified against Spec Kit **v0.12.4**; the
> upstream extension API is still marked experimental, so pin
> `requires.speckit_version` and expect some churn.

Spec Kit is a guidance layer: templates, prompts, and checklists _ask_ the
agent to comply. spec-gates is the enforcement layer underneath it: hooks
and pipelines that _force_ compliance — the bash call is rejected, the
protected file is refused, the session cannot end with failing checks.

Extracted from
[claude-project-foundation](https://github.com/schwichtgit/claude-project-foundation)
(now EOL), whose spec-authoring half was superseded by Spec Kit and whose
enforcement half lives on here.

## One policy, three boundaries

```text
                    .specify/gates/policy.json
                               |
        +----------------------+----------------------+
        |                      |                      |
  AGENT BOUNDARY         GIT BOUNDARY            CI BOUNDARY
  Claude Code hooks      pre-commit /            GitHub Actions /
  PreToolUse: block      commit-msg:             GitLab CI /
    protected files,     block main commits,     Jenkins:
    dangerous bash       conventional commits,
  PostToolUse:           no AI-isms
    auto-format
  Stop: refuse to end            \                    /
    with failing checks           \                  /
        \                          \                /
         +------------->  .specify/gates/verify.sh  <-----------+
                          (identical at every boundary)
```

**The parity property:** if the agent boundary passed, the git boundary
passes; if the git boundary passed, CI passes. Every boundary runs the
same `verify.sh` with the same policy — `tests/test-parity.sh` asserts it:
identical results at every boundary, and no boundary re-implements the gate.
A fourth, server-side boundary (branch protection requiring the CI check) is
available via `/speckit.gates.ci github --protect`.

## Provable enforcement

Enforcement that can silently stop enforcing is worse than none — you
still believe you are covered. Three mechanisms make the gate
self-evidencing:

- **Attestations** — every `verify.sh` run appends one record to
  `.specify/gates/attestations.jsonl` (capped, gitignored) and embeds it
  in `--json`: the policy's SHA-256, and per gate the resolved binary,
  detected version, lockfile pin, candidate vs checked file counts,
  result, and duration. Evidence, never file contents.
- **Canaries** — `canary.sh` plants known violations in disposable
  sandboxes (a prettier-dirty file, an SC2086 script, an `rm -rf /` tool
  call, a `.env` edit, a staged AWS-key-shaped string) and requires the
  real gate or hook to reject each one. An accepted probe fails the suite
  naming the broken gate. CI runs it on every build — a red canary step
  means a broken gate, not a dirty tree. On demand:
  `bash .specify/gates/canary.sh` (or `doctor.sh --canary`).
- **Verified parity** — a synthetic `parity` gate compares each tool's
  resolved version against its lockfile pin on every run, at every
  boundary. Drift fails the boundary with
  `parity -- prettier: resolved 3.5.3, pinned 3.9.4 (run npm ci)`;
  tune it with `attestation.parity` (`error | warning | off`). `doctor`
  additionally fails on the no-op signature: a gate that passed while
  checking zero of its candidate files.

The optional policy section, with its defaults:

```json
"attestation": { "enabled": true, "max_records": 200, "parity": "error" }
```

## Spec conformance

A spec's acceptance criteria are usually prose — checked by hand, if at
all. The `spec` gate makes them executable: fence a shell snippet as
` ```accept ` under any task in `specs/<feature>/tasks.md` and it becomes
a criterion the gate can run (exit 0 = the criterion holds):

````markdown
- [x] T042 Ship the exporter

  ```accept
  # verifies: SC-003
  bash tests/test-exporter.sh
  ```
````

The full grammar lives in
[`specs/002-spec-conformance-gate/contracts/accept-block.md`](specs/002-spec-conformance-gate/contracts/accept-block.md).
Malformed blocks (unterminated fence, no commands, no preceding task) fail
the gate naming `tasks.md:<line>` — an unreadable criterion is never
silently skipped.

Enforcement follows the feature's own completion claim, read from
`spec.md`:

- **In progress** (any `**Status**:` other than `Complete`) — blocks are
  parsed and reported on every run, executed only on demand:
  `verify.sh --accept <feature|all>` runs them informationally, never
  changing the exit code.
- **`**Status**: Complete`** — the claim is enforced. Any unchecked
  `- [ ]` task or failing accept block fails the run, naming the feature,
  the task or criterion, and the cause (exit code, `timeout after <N>s`,
  or a working-tree mutation — blocks are read-only by contract and never
  auto-reverted).

Results land in the attestation record (a `spec` gate entry plus per-run
counts and per-feature outcomes), a `spec` canary proves the gate still
blocks, and `doctor` reports discovery — including a nudge when every
task is checked but the Status flip is missing. The optional policy
section, with its defaults:

```json
"spec": { "enabled": true, "severity": "error", "include": ["*"], "exclude": [], "timeout_s": 30 }
```

## Policy as a versioned contract

An organization runs one baseline policy across a fleet of repos by
declaring, in each repo's `policy.json`:

```json
"extends": { "source": "https://github.com/acme/policy-baseline", "version": "v2.3.0" }
```

`/speckit.gates.sync` fetches that version once, pins it (version +
SHA-256 digest), commits a snapshot, and materializes the **effective
policy** — baseline with the local file applied as an overlay — which is
what every boundary then enforces. Gate runs never touch the network: a
synthetic `contract` gate proves offline, on every run, that the snapshot
matches the pin and the effective policy matches recomputation. Editing
any artifact by hand blocks the next run naming what drifted.

Drift is reviewable in both directions:

- **Overlays may deviate — transparently.** A repo can weaken a baseline
  rule (disable, lower a severity, narrow its scope), but every weakening
  is a named, attested deviation: `contract: deviation (weakened):
hooks.shellcheck.severity: baseline "error" -> overlay "warning"`.
  Deviations never change the exit code; they change what the org can see.
- **Updates arrive as changes, not surprises.** `sync --update` moves the
  pin to a newer baseline version on its own `gates/baseline-<v>` branch
  with the classified enforcement delta in the commit body; enforcement
  follows only when it merges.
- **Deviations can go home.** `/speckit.gates.propose` packages the
  deviation inventory as a change request against the baseline source —
  origin, pinned version, classification, and your rationale included.

The three artifacts (`baseline.json`, `baseline.lock.json`,
`policy.effective.json`) are committed contract state (formats:
[`specs/003-policy-contract/contracts/artifact-layout.md`](specs/003-policy-contract/contracts/artifact-layout.md));
`policy.json` stays the only file you edit. Repos without an `extends`
declaration are completely unaffected.

## Requirements

- **jq** and **git** — the hooks and `verify.sh` require them.
- **Node** with the linters your policy uses (default: **prettier**,
  **markdownlint-cli2**). Pin them in `package.json` so local and CI agree.
- **shellcheck** if you lint shell.
- **Claude Code** for the agent boundary. The git and CI boundaries are
  agent-agnostic.

## Install

```bash
specify extension add gates --from https://github.com/schwichtgit/spec-gates/releases/download/v0.2.0/gates-0.2.0.zip
```

The URL must point at a release **asset** (a flat package with
`extension.yml` at its root) — the repository/source archive does not
install, because the manifest lives in `extension/` inside this repo.
Spec Kit's community catalog is discovery-only (`install_allowed: false`),
so `--from <url>` is the install path even after `gates` is listed there;
catalog listing buys discoverability, not a bare `specify extension add gates`.

Then, in Claude Code:

```text
/speckit.gates.init        # infer policy, project runtime, wire hooks, self-test
/speckit.gates.ci github   # project the CI boundary (github | gitlab | jenkins)
```

From that point the normal Spec Kit loop is unchanged —
`/speckit.specify → clarify → plan → tasks → implement` — but during
`implement` every edit is auto-formatted, protected files and dangerous
bash are refused with actionable messages, and the session cannot stop
with red checks. After `implement`, the extension's `after_implement`
hook offers a gate run before you move to commit/PR.

## Commands

| Command                  | Purpose                                                                                                                 |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `/speckit.gates.init`    | Infer policy, project runtime, wire agent + git hooks, self-test                                                        |
| `/speckit.gates.verify`  | Run the full suite on demand (also runs after `implement`)                                                              |
| `/speckit.gates.doctor`  | Health check: hooks wired, policy valid, versions in sync                                                               |
| `/speckit.gates.ci`      | Project CI enforcement (`github` \| `gitlab` \| `jenkins`); `--protect` requires the check + a PR on the default branch |
| `/speckit.gates.upgrade` | Re-project runtime after update; never touches policy.json                                                              |
| `/speckit.gates.sync`    | Pin + materialize the `extends` baseline; `--update` moves the pin as a reviewable branch                               |
| `/speckit.gates.propose` | Package this repo's policy deviations as an upstream change request against the baseline                                |

## Workflow-engine integration

Insert a hard gate into any Spec Kit workflow:

```yaml
- id: quality-gate
  type: shell
  run: .specify/gates/verify.sh --boundary ci --json
- id: human-review
  type: gate
  prompt: "Gates green. Approve merge preparation?"
```

A red gate pauses the run; fix and `specify workflow resume <run_id>`.

## Agent support

Git and CI boundaries work with **any** coding agent — they are plain git
hooks and CI jobs. Agent-boundary enforcement currently supports
**Claude Code** (hook system). Adapters for other harnesses are welcome
as they grow hook APIs.

## Design rules

- `policy.json` is user-owned: `init` seeds it, `upgrade` never overwrites it.
- Runtime is **projected** (copied) into the repo — enforcement survives
  extension removal and works for every collaborator who clones.
- Fail closed: a gate that cannot demonstrably block is reported broken.
- Evidence over trust: every run leaves an attestation record, canaries
  re-prove that every gate still blocks, and parity is verified per run
  rather than assumed.

## Development

```bash
npm ci              # pinned prettier + markdownlint-cli2
bash tests/run.sh   # 8 suites: parity, gate, hooks, policy, doctor, canary, attest, spec-gate
```

The repo gates itself: `.github/workflows/ci.yml` projects the runtime and
runs `verify.sh --boundary ci` (attestations and the parity gate included)
plus the canary suite on every PR, alongside the tests. See the pull
request template for the contribution checklist.

## License

[MIT](LICENSE) © Frank Schwichtenberg
