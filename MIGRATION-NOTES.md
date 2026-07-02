# Migration notes: CPF -> spec-gates

Status of each component and the review pass it still needs.

## Adapted mechanically (sed rename: CPF_->GATES_, cpf_->gates_, .cpf/->.specify/gates/)

| File                                      | Origin                 | Review needed                                                                                                                                                         |
| ----------------------------------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| runtime/lib/policy.sh                     | cpf-policy.sh          | comment paths mention .claude-plugin; loader is fail-open by design — confirm still wanted                                                                            |
| runtime/lib/policy-infer.sh               | cpf-policy-infer.sh    | verify inference globs against policy-template.json shape                                                                                                             |
| runtime/lib/formatter-dispatch.sh         | _formatter-dispatch.sh | confirm --check/--tool/--project-root flags match verify.sh call sites                                                                                                |
| runtime/lib/taskfile-detect.sh            | cpf-taskfile-detect.sh | trivial                                                                                                                                                               |
| runtime/policy.schema.json                | cpf-policy.schema.json | extend for protected_files + git sections added in template                                                                                                           |
| runtime/hooks/claude/*.sh                 | CPF hooks              | verify-quality.sh should be SLIMMED to delegate to verify.sh --boundary agent (its 600-line legacy walk is now redundant); check-upgrade.sh was intentionally dropped |
| runtime/hooks/git/{pre-commit,commit-msg} | CPF scaffold           | pre-commit should call verify.sh --boundary git instead of its own walk                                                                                               |
| tests/*.sh                                | cpf/scripts            | paths reference old scaffold layout; rewire to runtime/ tree; test-ci-parity.sh is the priority                                                                       |

## Written new

- extension/extension.yml (+ after_implement hook into the core loop)
- extension/commands/*.md (init is the full draft; others are solid drafts)
- extension/templates/policy-template.json (adds protected_files, git sections)
- runtime/verify.sh (smoke-tested: dry-run, --json, custom-orchestrator fail-closed exit 2)
- runtime/hooks/claude/settings.fragment.json
- ci/{github,gitlab,jenkins}
- README.md, docs/how-it-works.md

## Deliberately dropped from CPF

- specforge skill (superseded by Spec Kit core)
- scaffold projection of repo boilerplate (CODEOWNERS, issue templates, release workflows) — out of scope; keep as a personal template repo or Spec Kit bundle
- upstream-cache / check-upgrade UserPromptSubmit hook (replaced by doctor + .runtime-version)

## Next actions (ordered)

1. Slim verify-quality.sh and pre-commit to delegate to verify.sh (kills ~700 lines, makes parity structural rather than tested-for)
2. Rewire the three tests to the new tree; get test-ci-parity.sh green
3. Extend policy.schema.json for the new sections
4. Dogfood: run /speckit.gates.init against a scratch spec-kit project via `specify extension add --source`
5. Add .github/workflows/gates.yml to THIS repo (self-enforcement)
6. Submit to the spec-kit community catalog via the extension_submission issue template
