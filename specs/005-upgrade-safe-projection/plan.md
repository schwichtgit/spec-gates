# Implementation Plan: Upgrade-Safe Projection

**Branch**: `005-upgrade-safe-projection` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/005-upgrade-safe-projection/spec.md`

## Summary

0.4.0 fixes every open issue in the milestone (#70–#74, #82, #83). The
core is one shipped, non-interactive `project.sh` that does the whole
projection. It writes a hash manifest and honors holds and a
project-owned `hooks.local.d/`. It wires git hooks through the detected
hook manager's own configuration and proves both boundaries
(canaries plus a policy-independent `GATES_PROBE` git probe). Around it:
agent hooks never silently allow (raw-mode block rules without jq, ask
when uncertain), protect-files asks instead of blocking on
name-only evidence, an opt-in bulk-staging knob, a scoped constitution
parser, and doctor checks for install hygiene, stale holds, CI drift and
dormant installs. Decisions and evidence: [research.md](research.md).

## Technical Context

**Language/Version**: bash 3.2-compatible shell (stock macOS floor), POSIX
awk/sed/grep (BSD and GNU).

**Primary Dependencies**: jq, git; `sha256sum` or `shasum -a 256`. Spec Kit
1.0.11–1.0.13 as the installer (not modified).

**Storage**: plain files in the consumer repo (data-model.md).

**Testing**: `tests/run.sh` suites (bash), canary suite, CI jobs
including `macos-bash32`, container matrix (node:26-slim, three python3
variants). Every new check gets a mutation check against `main`.

**Target Platform**: macOS (bash 3.2) and Linux CI runners; GitHub, GitLab,
Jenkins pipelines.

**Project Type**: Spec Kit extension (CLI runtime + command prose).

**Performance Goals**: projection of the full runtime under 10 s,
excluding the canary run; hook overhead unchanged (local rules add one
`bash` per script).

**Constraints**: fail closed; never write `policy.json` after init; never
write a hook manager's generated files; non-interactive scripts (agent
asks, script takes flags); no network in the runtime.

**Scale/Scope**: about 25 projected files, 3 hook managers + unknown, 3
CI platforms, 7 stories / 7 PRs.

## Constitution Check

| Principle                         | Status                    | Notes                                                                                                                                                                                                    |
| --------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| I. Fail Closed                    | Pass                      | #83 ends the silent allow in the two remaining hooks (raw-mode block rules, ask when uncertain); corrupt manifest, half-done install, missing sha tool, unreadable local rule, missing CI step all fail. |
| II. Provable Enforcement          | Pass                      | New canaries (no-jq variants, local rule, bulk staging); behavioral git probe in doctor and projection; init/upgrade run the full canary suite.                                                          |
| III. One Policy, Three Boundaries | Pass, with a stated limit | `block_bulk_staging` is agent-only because the git boundary cannot observe staging. Documented in the contract; no boundary-specific divergence of an observable check.                                  |
| IV. Projection, Not Dependency    | Pass                      | Still copy-only; the manifest makes drift visible; `policy.json` never written.                                                                                                                          |
| V. The Spec Is a Boundary         | Pass                      | Accept blocks per story in tasks.md; Status flips to Complete last.                                                                                                                                      |
| Portability floor                 | Pass                      | bash 3.2, no associative arrays/mapfile; indexed arrays as in canary.sh.                                                                                                                                 |
| Evidence hygiene                  | Pass                      | The git probe uses a temp message file and `GATES_PROBE`; reads no project content. The manifest holds hashes only.                                                                                      |

Re-check after design: no new violations. Complexity table not needed.

## Project Structure

### Documentation (this feature)

```text
specs/005-upgrade-safe-projection/
├── plan.md  research.md  data-model.md  quickstart.md
├── contracts/project-sh.md  contracts/hooks.md
├── checklists/requirements.md
└── tasks.md            # /speckit-tasks
```

### Source Code (repository root)

```text
extension/
├── runtime/
│   ├── project.sh                      # NEW: projection entrypoint (US1)
│   ├── doctor.sh                       # install state, skills, holds, CI drift, probe, --installed-only
│   ├── canary.sh                       # no-jq variants, local-rule, bulk-staging canaries
│   ├── lib/manifest.sh                 # NEW: hash, classify, write manifest (US1/US2)
│   ├── lib/managers.sh                 # NEW: hook-manager detection + entries (US6)
│   ├── lib/local-hooks.sh              # NEW: hooks.local.d runner (US3)
│   ├── lib/known-releases.sha256       # NEW: generated table (US2)
│   ├── lib/constitution.sh             # parser scope (US4)
│   ├── policy.schema.json, policy-template.json   # block_bulk_staging (US3)
│   └── hooks/{claude,git}/*            # fail closed, ask, local rules, GATES_PROBE
├── ci/steps.tsv                        # NEW: CI step signatures (US2)
└── commands/speckit.gates.{init,upgrade,doctor}.md   # call project.sh; one upgrade path
scripts/known-releases.sh               # NEW: generates the table from tags
tests/test-project.sh                   # NEW suite (registered in tests/run.sh)
tests/test-{hooks,doctor,canary,constitution,package}.sh   # extended
README.md, CHANGELOG.md                 # upgrade path, --dev, attribution, coexistence
.gitignore                              # project.sh in .specify/gates/
```

**Structure Decision**: existing extension layout. New logic goes in
`lib/` modules sourced by `project.sh` and `doctor.sh` so both share one
implementation of classification, manager detection and probing.

## Delivery Order (one PR per story, milestone 0.4.0)

1. **US7 #83** agent hooks never silently allow. Small, and US3 touches the same
   hook.
2. **US1 #72** `project.sh` with the full file-format contracts.
   Manifest written now; holds, local directory and manager detection
   are honored as exclusions from day one (contracts fixed here, richer
   behavior in later PRs).
3. **US2 #70** known-release table, conflict resolution flags, holds in
   doctor, CI drift.
4. **US3 #71** local rules, bulk-staging knob, protect-files ask.
5. **US4 #82** parser scope.
6. **US5 #73** install hygiene checks, package prettier test.
7. **US6 #74** managers + probe, `--installed-only`, branding docs.
8. Docs/CHANGELOG sweep, RC to both consumer peers, bump PR.

## Risks

- **YAML append for lefthook / pre-commit**: append-only with a refusal
  fallback; tests cover existing-key and tab-indented files.
- **Raw-mode over-match (#83)**: without jq, a block pattern inside a
  non-command field (e.g. a description) blocks a harmless call. This is
  accepted: it errs toward blocking, only while jq is missing, and
  doctor fails in that state. Tests pin that raw mode never misses a
  pattern the jq path blocks.
- **Known-release table drift**: a test asserts coverage of every tag
  ≥ v0.3.0.

## Notes

- The template's agent-context update step is skipped: there is no such
  script under `.specify/scripts/bash/` here.
