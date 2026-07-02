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
  plus the shipped policy template validating cleanly.
