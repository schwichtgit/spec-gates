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
  block-main, secret scan).
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
  `Complete`.
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
