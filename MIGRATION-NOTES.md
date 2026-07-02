# Migration notes: CPF -> spec-gates

Status of each component and the review pass it still needs.

## Adapted mechanically (sed rename: CPF_->GATES_, cpf_->gates_, .cpf/->.specify/gates/)

| File                                      | Origin                 | Review needed                                                                                                                                                                                                                                                                                     |
| ----------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| runtime/lib/policy.sh                     | cpf-policy.sh          | comment paths mention .claude-plugin; loader is fail-open by design — confirm still wanted                                                                                                                                                                                                        |
| runtime/lib/policy-infer.sh               | cpf-policy-infer.sh    | verify inference globs against policy-template.json shape                                                                                                                                                                                                                                         |
| runtime/lib/formatter-dispatch.sh         | _formatter-dispatch.sh | confirm --check/--tool/--project-root flags match verify.sh call sites                                                                                                                                                                                                                            |
| runtime/lib/taskfile-detect.sh            | cpf-taskfile-detect.sh | trivial                                                                                                                                                                                                                                                                                           |
| runtime/policy.schema.json                | cpf-policy.schema.json | extend for protected_files + git sections added in template                                                                                                                                                                                                                                       |
| runtime/hooks/claude/*.sh                 | CPF hooks              | DONE: verify-quality.sh slimmed 617->60 lines, now delegates to verify.sh --boundary agent (legacy language walk dropped); remaining PreToolUse hooks (protect-files, validate-bash, validate-pr, post-edit, format-changed) still need a review pass; check-upgrade.sh was intentionally dropped |
| runtime/hooks/git/{pre-commit,commit-msg} | CPF scaffold           | DONE (pre-commit): 221->144 lines; keeps git-only safety (block-main, secret/forbidden-file scan), delegates the quality gate to verify.sh --boundary git. commit-msg (conventional + no-AI-isms) still needs a review pass                                                                       |
| tests/*.sh                                | cpf/scripts            | paths reference old scaffold layout; rewire to runtime/ tree; test-ci-parity.sh is the priority                                                                                                                                                                                                   |

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
2. Rewire the three tests to the new tree; fold the fixture smoke tests into
   tests/test-hooks.sh; get test-ci-parity.sh asserting real boundary parity
   (all three call verify.sh) rather than tool-name presence
3. Extend policy.schema.json for the new sections
4. Dogfood: run /speckit.gates.init against a scratch spec-kit project via `specify extension add --from <url>`
5. Add .github/workflows/gates.yml to THIS repo (self-enforcement)
6. Submit to the spec-kit community catalog (discovery-only) via the extension_submission issue template; installs still go through `--from <url>`
