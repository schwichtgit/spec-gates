# Tests

Shell test suites for the enforcement runtime. Run all of them with
`bash tests/run.sh` (or run any one directly). All are bash 3.2-safe, since
the hooks execute under macOS `/bin/bash`.

- `test-parity.sh` — THE invariant, asserted three ways: every boundary
  (3 CI projections + agent hook + git hook) routes through `verify.sh`; no
  boundary re-implements the gate; and `verify.sh` yields identical results
  at the agent, git, and ci boundaries. This is the product's headline
  claim; it must stay green.
- `test-gate.sh` — `verify.sh` orchestrator behaviour: the default `none`
  orchestrator really runs prettier/markdownlint/shellcheck in check mode
  (regression guard for the no-op-default bug), exclude globs are honored,
  the `custom` orchestrator maps exit codes, and an empty gate set does not
  crash under bash 3.2. Node-linter checks skip cleanly until `npm ci` runs.
- `test-hooks.sh` — hook behaviour. Part A: the self-contained hooks
  (protect-files, validate-bash, validate-pr, post-edit, format-changed)
  block and allow correctly. Parts B/C: the agent Stop hook and git
  pre-commit correctly delegate to `verify.sh` (green -> allow/pass,
  fail -> block, loop-guard, fail-open when the runtime is not projected,
  block-main, secret scan). Later parts: the agent hooks never silently
  allow (block on certainty, ask on uncertainty, raw mode without jq);
  `protected_files.extra`; commit-msg toggles, Protected-Change trailers
  and `git.ai_branding`; hook/runtime version skew, hook stubs and linked
  worktrees; the auto-format hooks really format, map a tool failure
  through their severity, and format nothing without a policy; local rules in
  `hooks.local.d`, `git.block_bulk_staging`, and asking on a name alone;
  project rules and protected files out of the agent's reach (Write
  blocked, Bash asks, rule changes need a trailer); the `GATES_PROBE`
  marker.
- `test-policy.sh` — `policy.sh` loader getters and the schema validator
  (required fields, enum validation, custom_command rules, malformed JSON),
  plus the shipped policy template validating cleanly. Includes the
  `attestation` and `spec` section rules (types, enums, unknown-field
  rejection).
- `test-doctor.sh` — environment health checks: a policy-enabled linter
  that is not installed is an enforcement gap (exit 1), a disabled linter
  is reported as skipped, and the spec-conformance section reports
  discovery counts, fails on parse errors naming `tasks.md:<line>`, and
  nudges a feature whose tasks are all checked but whose Status is not
  `Complete`. Further sections: git boundary wiring (including linked
  worktrees), the policy contract, the no-op heuristic, execute bits, the
  runtime version check, constitution enforcement, upgrade safety, install
  hygiene, and the git probe with `--installed-only`.
- `test-canary.sh` — the gate's own proof that it still blocks: a healthy
  fixture gets every canary `blocked`; a no-op formatter dispatch and a
  stubbed accept-block runner are each caught in one run, naming the
  broken gate; a canary run never creates, modifies, or reads project
  files (FR-006); `--only` subsets and `doctor --canary` delegation;
  absent-tool skips vs the policy-enabled gap rule.
- `test-attest.sh` — evidence: every run appends a schema-conformant
  record to the capped JSONL log and embeds it in `--json`; identical runs
  differ only in ts/duration; a forged pass-with-zero-checked record fails
  doctor (the no-op signature); evidence loss is a warning, never a
  result; the synthetic `parity` gate blocks on lockfile drift (warn/off
  severities honored, unpinned tools exempt); the `spec` object carries
  per-feature outcome counts and vanishes when policy-disabled.
- `test-spec-gate.sh` — the spec-conformance gate: the accept-block parser
  (fence-aware checkbox counting, CommonMark fence lengths — a
  prettier-normalized ````accept block still parses — and fail-closed
  errors for unterminated/empty/orphan blocks naming `file:line`);
  `--accept` runs incomplete features informationally without changing the
  exit code; a `Complete` feature blocks on a failing block (SC-001) or an
  unchecked task (SC-002), naming both; timeout and mutation detection
  (never auto-reverted); `severity`/`include`/`exclude`/`enabled` policy
  knobs; the `GATES_SPEC_EXEC` recursion guard.
- `test-contract.sh` — the policy contract (feature 003): one `sync`
  adopts a baseline and materializes the effective policy; verify runs
  offline afterwards; hand-editing any contract artifact blocks, naming
  it; deviations are classified and informational; repos without
  `extends` are untouched; sync failures fail closed with prior state
  intact; `sync --update` lands only as a reviewable change; `propose`
  turns deviations into an upstream change request. Every refusal (bad
  arguments, an invalid overlay, baseline or merge, no pin, no tags, an
  existing update branch) is named and writes nothing.
- `test-constitution.sh` — the constitution pipeline (feature 004):
  fragment filtering and ordering; a byte-deterministic draft with one
  marker per principle and no placeholders; no materializing without a
  surface decision; `--augment` keeps every existing line; detect
  (absent/placeholder/filled); per-surface alignment and overlay targeting;
  `check` verdicts and exit codes; only `###` headings under
  `## Core Principles` count as principles; argument errors and the
  `--constitution`/`--policy` flags.
- `test-package.sh` — what a consumer's repo sees after install: the
  package contents mirror the release workflow, shipped markdown is clean
  under default lint tooling, shipped shell passes the pinned shellcheck,
  and every shipped script parses under the stock macOS bash 3.2.
- `test-pr-check.sh` — `pr-check.sh` at the CI boundary: PR/MR text
  runs through the shared message rules; Protected-Change declarations are
  enforced per commit from trailers or the description; GitHub, GitLab and
  Jenkins contexts resolve from their own variables (including a truncated
  GitLab description); no PR context skips; an unresolvable range exits 2.
- `test-manifest.sh` — the projection libraries: sha256 tool fallback
  (none available fails closed), version order, the projection table
  (never lists `policy.json` or `hooks.local.d/`), manifest validation
  and round trip, holds, per-file classification
  (absent/upstream/pristine/edited/held), and the install states
  (installed/dev/dormant/removed/mismatch/absent).
- `test-project.sh` — `project.sh` end to end in fixture projects: a
  fresh projection writes every table entry with execute bits, a valid
  manifest and the git stubs; a second run changes nothing; the settings
  merge keeps user entries; vendored modes change only for the two git
  hooks; a local edit stops the run (exit 3) until `--keep-local` or
  `--take-upstream`; refusals before writing (no policy, registry
  mismatch, corrupt or newer manifest); the half-done remove+add; foreign
  and `core.hooksPath` hooks left alone; and the canary proof failing on
  a broken hook.
- `test-policy-infer.sh` — the policy seed init proposes: excludes
  inferred from `.prettierignore`, `.markdownlint-cli2.yaml` and
  `.specify/gates/shellcheck-excludes.txt` (bundled defaults otherwise),
  the `task` orchestrator when a Taskfile has top-level `lint` and `test`
  targets (grep and yq paths), and exit 2/3/4 for usage errors, a missing
  template, and a result that fails validation.
