# Migration notes: CPF -> spec-gates

Status of each component and the review pass it still needs.

## Adapted mechanically (sed rename: CPF_->GATES_, cpf_->gates_, .cpf/->.specify/gates/)

| File                                      | Origin                  | Review needed                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| runtime/lib/policy.sh                     | cpf-policy.sh           | comment paths mention .claude-plugin; loader is fail-open by design — confirm still wanted                                                                                                                                                                                                                                                                |
| runtime/lib/policy-infer.sh               | cpf-policy-infer.sh     | verify inference globs against policy-template.json shape                                                                                                                                                                                                                                                                                                 |
| runtime/lib/formatter-dispatch.sh         | \_formatter-dispatch.sh | DONE: the --check/--tool/--project-root CLI did NOT exist, so verify.sh's default `none` orchestrator was a silent no-op (every file passed). Implemented check-mode: expands include globs minus excludes, runs each tool in check mode. Tool resolution is node_modules/.bin -> PATH -> skip (never npx-downloads a version, which would break parity). |
| runtime/lib/taskfile-detect.sh            | cpf-taskfile-detect.sh  | trivial                                                                                                                                                                                                                                                                                                                                                   |
| runtime/policy.schema.json                | cpf-policy.schema.json  | DONE: added protected_files + git to the JSON schema (top-level additionalProperties:false was rejecting the very sections the template ships) and to the policy.sh validator; git.block_main_commits is now consumed by pre-commit                                                                                                                       |
| runtime/hooks/claude/*.sh                 | CPF hooks               | DONE: verify-quality.sh slimmed 617->60 lines, now delegates to verify.sh --boundary agent (legacy language walk dropped); remaining PreToolUse hooks (protect-files, validate-bash, validate-pr, post-edit, format-changed) still need a review pass; check-upgrade.sh was intentionally dropped                                                         |
| runtime/hooks/git/{pre-commit,commit-msg} | CPF scaffold            | DONE (pre-commit): 221->144 lines; keeps git-only safety (block-main, secret/forbidden-file scan), delegates the quality gate to verify.sh --boundary git. commit-msg now reads git.conventional_commits + git.forbid_ai_isms toggles (default on)                                                                                                        |
| tests/\*.sh                               | cpf/scripts             | DONE: rewired to the runtime/ tree. test-ci-parity.sh renamed to test-parity.sh and broadened (5-boundary routing + single-impl + identical-results). test-hooks.sh now covers agent/git delegation. test-policy.sh repointed. `bash tests/run.sh` runs all (59 tests green)                                                                              |

## Written new

- extension/extension.yml (+ after_implement hook into the core loop)
- extension/commands/*.md (init is the full draft; others are solid drafts)
- extension/templates/policy-template.json (adds protected_files, git sections)
- runtime/verify.sh (single entrypoint). Two bugs fixed while wiring the
  delegation: (a) custom orchestrator read field `command` instead of
  `custom_command`, so it never ran; (b) `"${RESULTS[@]}"` on an empty array
  crashed under `set -u` on bash 3.2 (macOS `/bin/bash`), where the hooks run.
  Both covered by the fixture smoke tests below.
- runtime/hooks/claude/settings.fragment.json
- ci/{github,gitlab,jenkins}
- README.md, docs/how-it-works.md

## Deliberately dropped from CPF

- specforge skill (superseded by Spec Kit core)
- scaffold projection of repo boilerplate (CODEOWNERS, issue templates, release workflows) — out of scope; keep as a personal template repo or Spec Kit bundle
- upstream-cache / check-upgrade UserPromptSubmit hook (replaced by doctor + .runtime-version)

## Capability change to be explicit about

The dropped legacy walk auto-ran language checks (eslint/tsc, ruff/pytest/mypy,
cargo/clippy, go vet/test). verify.sh's default `orchestrator: none` runs only
the format/lint gates (prettier, markdownlint, shellcheck). Language build/test
now goes through `orchestrator: task` (`task lint`/`task test`) or `custom`. If
we want zero-config language auto-detection back, it should be ported INTO
verify.sh (so all three boundaries still share one implementation), never back
into a hook.

## Next actions (ordered)

1. DONE: slimmed verify-quality.sh + pre-commit to delegate to verify.sh
   (~630 lines removed; parity is now structural). Fixture tests cover both
   boundaries (green->allow/pass, fail->block, block-main, secret scan,
   loop-guard, fail-open when unprojected).
2. DONE: rewired all three test suites to runtime/ (+ tests/run.sh). Fixture
   smoke tests folded into test-hooks.sh; test-parity.sh asserts real boundary
   parity (5-boundary routing, single implementation, identical results). 59
   tests green.
3. DONE (fully consumed, not just validated): protected_files + git added to
   the JSON schema and the policy.sh validator. All sections are now read by
   the hooks: git.block_main_commits by pre-commit; protected_files.extra by
   protect-files.sh (agent) and the pre-commit scan; git.conventional_commits
   and git.forbid_ai_isms by commit-msg. Shared gates_glob_match helper added.
   Every toggle has test coverage.
4. Dogfood: run /speckit.gates.init against a scratch spec-kit project via `specify extension add --from <url>`
5. DONE: self-enforcement. `.github/workflows/ci.yml` projects the runtime
   and runs the gate on this repo + `tests/run.sh`. Linters pinned via
   package.json + package-lock.json (prettier 3.9.4, markdownlint-cli2
   0.23.0); repo policy at `.specify/gates/policy.json`. Gate is green
   locally. NB parity now also requires pinned tool VERSIONS, not just one
   verify.sh -- unpinned `npx prettier` (3.5.3 cached vs 3.9.4) disagreed on
   markdown tables.
6. Submit to the spec-kit community catalog (discovery-only) via the extension_submission issue template; installs still go through `--from <url>`
