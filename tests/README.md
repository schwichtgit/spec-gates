# Tests

Adapted from claude-project-foundation's shell test suite (namespaces
renamed CPF_-> GATES_, .gates/ -> .specify/gates/). Each needs one review
pass — see ../MIGRATION-NOTES.md.

- `test-policy.sh` — policy loader + schema validation behavior
- `test-hooks.sh` — each Claude/git hook blocks and allows correctly
- `test-ci-parity.sh` — THE invariant: verify.sh produces identical
  results when invoked as agent, git, and ci boundary. This test is the
  product's headline claim; it must stay green.

Run all: `for t in tests/test-*.sh; do bash "$t"; done`
