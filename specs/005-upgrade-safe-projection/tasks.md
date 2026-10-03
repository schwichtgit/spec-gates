# Tasks: Upgrade-Safe Projection

**Input**: Design documents from `/specs/005-upgrade-safe-projection/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: included. FR-026 requires every new check to ship with a test
that fails against the pre-change code (mutation check: copy the `main`
version of the changed file over the new one, see the test fail,
restore). Suites register in `tests/run.sh`; hooks are executed by path,
never `bash <hook>`, so the stock-macOS bash 3.2 shebang path is what
gets tested.

**Organization**: one phase per user story, in delivery order (plan.md):
US7 (#83) first, then US1–US6. Each phase is one PR under milestone
0.4.0, branched from `main` and rebased after each merge. Accept blocks
are fast sandbox checks (`mktemp -d` outside the repo, under the 30 s
watchdog, read-only); the full suites stay in `tests/run.sh`. Blocks may
be adapted to the final interface during implementation, never weakened.
They are enforced once Status flips to `Complete` (last task).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1 (#72) … US7 (#83), per spec.md

## Phase 1: Setup

**Purpose**: land the design and the projection plumbing every story uses.

- [x] T001 Commit `specs/005-upgrade-safe-projection/` (spec, plan, research, data-model, contracts, quickstart, checklist, tasks) and `.specify/feature.json` on branch `005-upgrade-safe-projection`; open the docs PR (`docs: specify 0.4.0 upgrade-safe projection`) after `pr-check.sh` passes
- [x] T002 [P] Add `.specify/gates/project.sh` to the projected-runtime list in `.gitignore` (the `ci.yml` `cp` lines need no change: CI does not run `project.sh`, and `lib/*.sh` already picks up the new libraries; see T020), and to the package probes in `.github/workflows/release.yml` (`gates/runtime/project.sh`, `gates/runtime/lib/manifest.sh`, `gates/runtime/lib/known-releases.sha256`)
- [x] T003 [P] Create `tests/lib/fixture.sh` with shared helpers: `fx_project` (mktemp git repo + a vendored copy of `extension/` under `.specify/extensions/gates/` + a `.registry` entry at the extension's version), `fx_nojq_path` (shim dir with bash, grep, sed, awk, cat, basename, dirname, git, printf and no jq), `fx_cleanup`; bash 3.2 only

---

## Phase 2: Foundational

**Purpose**: shared libraries that `project.sh` (US1) and doctor (US2,
US5, US6) both source. They block US1–US6, not US7.

- [x] T004 Create `extension/runtime/lib/manifest.sh`: `gates_sha256` (sha256sum → `shasum -a 256` → return 2), manifest read/validate/write per data-model.md (header `# spec-gates-manifest v1 version=X.Y.Z`, atomic temp+mv, corrupt/downgrade detection), the projection table as a single function listing `<source-rel>\t<target-rel>` pairs (the init.md step 3 table plus `project.sh`), holds reader (paths and `ci:` lines, `#` comments), and `gates_classify <target>` returning `absent|upstream|pristine|edited|held` (hooks.local.d never classified)
- [x] T005 [P] Create `extension/runtime/lib/install-state.sh`: `gates_install_state` returning `installed|dev|removed|mismatch|dormant` per data-model.md (`.specify/extensions/.registry` via jq, vendored `extension.yml` version, `.specify-dev/` presence, `.specify/gates/` presence)
- [x] T006 [P] Create `tests/test-manifest.sh` (register in `tests/run.sh`): hash tool fallback order and fail-closed when neither exists; manifest round-trip; corrupt header, bad hash, unknown path → corrupt; newer version → downgrade; classification of each state including a deleted file → `edited` and a held path → `held`; `hooks.local.d/` files never listed; install-state for each of the five states

**Checkpoint**: libraries unit-tested; nothing user-visible changed yet.

---

## Phase 3: User Story 7 — Agent hooks never silently allow (Priority: P1, ships first) — #83

**Goal**: protect-files and validate-bash block on a rule match, ask when
they cannot evaluate, allow benign calls, with or without jq (research
R10, contracts/hooks.md).

**Independent Test**: quickstart US7 — with jq removed from PATH,
destructive commands and sensitive files are still blocked, benign calls
pass with a doctor warning, unevaluable edits return "ask".

- [x] T007 [US7] Rework `extension/runtime/hooks/claude/validate-bash.sh`: replace `trap 'exit 0' ERR` with a trap that emits the static "ask" JSON (naming the line) and exits 0; without jq or on unparseable JSON enter raw mode (unescape `\"` and `\\` in the raw payload, run the same block patterns over it); keep the patterns in one function shared by both modes; raw-mode allow prints a doctor warning on stderr
- [x] T008 [US7] Rework `extension/runtime/hooks/claude/protect-files.sh` the same way: ERR trap → ask; raw mode extracts `file_path` with a POSIX sed expression (unextractable → ask), applies the built-in name rules (block), and returns ask when `policy.json` declares a non-empty `protected_files.extra` (detected with grep, since jq is absent); a present `lib/policy.sh` that fails to source → ask; absent field → allow
- [x] T009 [P] [US7] Add an `ask <reason>` printf helper to both hooks (inline in each hook, since hooks must not depend on `lib/` being loadable); output exactly the shape in research R14
- [x] T010 [US7] Extend `tests/test-hooks.sh`: every block-pattern payload of the existing jq cases also blocks in raw mode (`fx_nojq_path`), raw mode never misses a pattern the jq path blocks (loop over a shared case list), benign command allowed with warning, `.env`/key/cert blocked without jq, extra-declared policy → ask, no extra → allow, malformed JSON → raw mode, forced internal error → ask JSON parses with jq, absent field → allow; mutation-check against `main`
- [x] T011 [US7] Extend `extension/runtime/canary.sh`: `bash` and `protect` canaries each gain a no-jq variant (PATH shim built inside the sandbox) that must block `rm -rf /` and an `.env` edit; update the header comment and `tests/test-canary.sh` counts
- [x] T012 [US7] Update `extension/runtime/doctor.sh` wording for missing jq: name the degraded raw mode and the install command; update `CHANGELOG.md` [Unreleased] (Fixed: #83)

  ```accept
  # verifies: FR-028
  set -eu
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir "$tmp/bin"
  for t in bash grep sed awk cat basename dirname printf git tr head; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$tmp/bin/$t"
  done
  h=extension/runtime/hooks/claude
  ! printf '%s' '{"tool_input":{"command":"rm -rf /"}}' | env PATH="$tmp/bin" "$h/validate-bash.sh" 2>/dev/null
  printf '%s' '{"tool_input":{"command":"ls -la"}}' | env PATH="$tmp/bin" "$h/validate-bash.sh" 2>/dev/null
  ! printf '%s' '{"tool_input":{"file_path":".env"}}' | env PATH="$tmp/bin" "$h/protect-files.sh" 2>/dev/null
  ```

**Checkpoint**: no agent-boundary state silently allows; PR 1 of 0.4.0.

---

## Phase 4: User Story 1 — One reviewable step projects or upgrades the runtime (Priority: P1) — #72

**Goal**: `project.sh` does the whole projection in one invocation,
idempotently, proves it with the canaries, and detects a half-done
remove+add (contracts/project-sh.md).

**Independent Test**: quickstart US1.

- [x] T013 [US1] Create `extension/runtime/project.sh` (bash 3.2, sources T004/T005): option parsing per contracts/project-sh.md; preflight (jq, git, sha tool, install state; exit 2 on `removed`/`mismatch`/corrupt/downgrade, printing the `specify extension add gates --from <url>` finishing command); running from `.specify/gates/` without a vendored source allows only `--check` and the diagnosis
- [x] T014 [US1] Implement the write phase in `extension/runtime/project.sh`: copy per the projection table, `chmod +x` projected and vendored scripts and git hooks (FR-005a), `.runtime-version`, `.specify/gates/.gitignore` attestations entry, agent hooks and the `.claude/settings.json` merge with jq (append-only, identical command paths skipped, `--no-agent-hooks`), plain-hooks stub install (`--no-git-hooks`), manifest write last; `--dry-run`/`--check` print the plan and write nothing; second run prints `no changes`
- [x] T015 [US1] Implement the proof phase in `extension/runtime/project.sh`: run the projected `canary.sh` (all) and exit 1 naming any accepted canary; `--skip-canary` refused unless `GATES_TEST=1`
- [x] T016 [US1] Rewrite `extension/commands/speckit.gates.init.md` step 3–5 and 6.2–6.3 to: run `project.sh --dry-run`, show it, run `project.sh` once; self-test steps 2–3 become `canary.sh --only bash,protect`; keep policy inference (step 2), lint seeding (3b/3c) and the constitution offer (6b) as conversation
- [x] T017 [US1] Rewrite `extension/commands/speckit.gates.upgrade.md` around `project.sh` and the one documented upgrade path: back up, `specify extension remove gates --keep-config --force`, download the zip, verify `sha256sum -c` against `SHA256SUMS` and `cosign verify-blob` (stop on failure), `specify extension add gates --from <release URL>`, `project.sh --dry-run`, `project.sh`
- [x] T018 [P] [US1] README: replace the upgrade section with the same single path (T017) and the version-pinned URLs; note that `add --from` verifies neither checksum nor signature
- [x] T019 [US1] Create `tests/test-project.sh` (register in `tests/run.sh`): fresh projection writes every table entry with exec bits and a valid manifest; idempotent second run (`no changes`, tree hash unchanged); vendored `commit-msg`/`pre-commit` re-chmod'ed; `--dry-run` writes nothing; settings merge preserves user entries and skips duplicates; registry removed → exit 2 with the add command; registry/vendored version mismatch → exit 2; run from `.specify/gates/` without vendored source → exit 2; a broken canary (fixture hook patched to allow) → exit 1 naming it; mutation-check
- [x] T020 [US1] Self-host: run `project.sh` semantics against this repo in CI by replacing the hand-written `cp` lines in `.github/workflows/ci.yml` with `bash extension/runtime/project.sh --no-agent-hooks --no-git-hooks --skip-canary` (with `GATES_TEST=1`) only if it keeps the CI job's behavior identical; otherwise record why the `cp` lines stay. **Decision**: the `cp` lines stay. `project.sh` would also write `.runtime-version`, the manifest, the attestation ignore entry and (without the opt-outs) settings and git hooks into the CI checkout, none of which CI needs; CI's job is to run the runtime from source, which the `cp` lines already do

  ```accept
  # verifies: SC-001
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_project)"; trap 'fx_cleanup "$d"' EXIT
  (cd "$d" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null)
  (cd "$d" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary) | grep -q 'no changes'
  head -1 "$d/.specify/gates/.projected.sha256" | grep -q '^# spec-gates-manifest v1 version='
  ```

**Checkpoint**: one approval projects or upgrades; PR 2.

---

## Phase 5: User Story 2 — Upgrades never silently discard local edits (Priority: P2) — #70

**Goal**: conflicts, holds, the known-release table for manifest-less
0.3.x projects, and CI drift (research R4–R6).

**Independent Test**: quickstart US2.

- [x] T021 [US2] Create `scripts/known-releases.sh`: for each tag `v0.3.0`…`v0.3.x` (the manifest-less releases; 0.4.0+ write a manifest), hash every projected file from `git show <tag>:<source>` and emit `extension/runtime/lib/known-releases.sha256` (`version\tsha256\ttarget`), sorted, deterministic; commit the generated table
- [x] T022 [US2] Use the table in `lib/manifest.sh` classification for any path without a manifest record; content matching any listed release at that path is `pristine`, anything else differing is `edited`
- [x] T023 [US2] (landed with US1: exit 3 without a way to resolve it would have stranded users) Implement conflict handling in `extension/runtime/project.sh`: unresolved `edited` → exit 3 listing paths and both flags, nothing written; `--take-upstream`/`--keep-local` per path; `--keep-local` appends to `.upgrade-holds`; `held` paths skipped and reported
- [x] T024 [P] [US2] Add the CI step signatures (`gates`, `canary`, `pr`, research R6) as `gates_ci_steps` plus `gates_ci_files`/`gates_ci_missing` in `extension/runtime/lib/manifest.sh` (embedded rather than a `ci/steps.tsv`, so the projected doctor needs no installed extension) that finds the pipeline file (GitHub workflow containing `verify.sh --boundary ci`, `.gitlab-ci.yml`, `Jenkinsfile`) and lists missing step ids, honoring `ci:<id>` holds
- [x] T025 [US2] Extend `extension/runtime/doctor.sh` (infer `--no-agent-hooks` from the manifest: no `.claude/hooks/gates/` entries means the agent hooks were opted out, so pass `--no-agent-hooks` to `project.sh --check`; no second flag file): holds section (list; stale hold → fail; hold inside `hooks.local.d/` → redundant note), CI drift section (missing unacknowledged step → fail; no pipeline → info), manifest section (`project.sh --check` result: corrupt → fail, local edits → listed)
- [x] T026 [US2] Report holds and CI drift at the end of `project.sh` (contracts step 7). Also: `--keep-local` on a path that is not `edited` adds the hold anyway (today it is ignored silently); decide whether foreign or unwired git hooks make `--check` exit 1 (today `--check` reports them but exits 0)
- [x] T027 [US2] Tests in `tests/test-project.sh` and `tests/test-doctor.sh`: edited file → exit 3 and untouched; each resolution flag; hold never overwritten; stale hold fails doctor; a 0.3.6 fixture projection (from the table) upgrades with zero conflicts, while one edited file is the only conflict; table covers every tag ≥ v0.3.0 (`git tag -l 'v0.3.*' 'v0.[4-9]*'` ⊆ table versions); CI drift per platform fixture and `ci:` acknowledgment; mutation-check

  ```accept
  # verifies: SC-002
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_project)"; trap 'fx_cleanup "$d"' EXIT
  (cd "$d" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null)
  echo '# local hardening' >>"$d/.specify/gates/verify.sh"
  sum="$(cd "$d" && shasum .specify/gates/verify.sh 2>/dev/null || sha256sum .specify/gates/verify.sh)"
  printf '\n# newer\n' >>"$d/.specify/extensions/gates/runtime/verify.sh"
  rc=0; (cd "$d" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1) || rc=$?
  [ "$rc" -eq 3 ]
  [ "$sum" = "$(cd "$d" && shasum .specify/gates/verify.sh 2>/dev/null || sha256sum .specify/gates/verify.sh)" ]
  ```

**Checkpoint**: no upgrade overwrites a local change without a decision; PR 3.

---

## Phase 6: User Story 3 — Local hardening survives upgrades; sensitive names ask (Priority: P3) — #71

**Goal**: `hooks.local.d/`, the bulk-staging knob, the protect-files
split (research R7–R9).

**Independent Test**: quickstart US3.

- [x] T028 [US3] Create `extension/runtime/lib/local-hooks.sh` with `gates_run_local <hook>`, sourced by each hook only when `.specify/gates/hooks.local.d/<hook>/` has scripts (a lib that then fails to load → ask in agent hooks, refuse in git hooks). It runs `.specify/gates/hooks.local.d/<hook>/*.sh` in lexical order via `bash`, passing stdin (agent) or args (git), refusing on non-zero or unreadable files with the `gates(local <hook>/<file>)` prefix; wire it after the shipped checks in `protect-files.sh`, `validate-bash.sh`, `validate-pr.sh`, `hooks/git/pre-commit`, `hooks/git/commit-msg`
- [x] T029 [US3] Add `git.block_bulk_staging` (boolean, default false) to `extension/runtime/policy.schema.json` and the documented default to `policy-template.json` only if template keys are listed explicitly; implement the rule in `validate-bash.sh` (jq and raw mode; `-A`, `--all`, `.`, `:/`, `*`, trailing `/`, existing directory against payload `cwd`); refusal names the knob
- [x] T030 [US3] Split the protect-files name rule: keep the hard-block list from research R9 (add `*.jks`, `*.keystore`, `.netrc`, `.pypirc`, `credentials`, `credentials.json`), and turn the substring rule into the "ask" decision with the matched word in the reason
- [x] T031 [US3] `project.sh` policy notices: list schema properties with a default that are absent from `policy.json` (e.g. `git.block_bulk_staging`) and point at `/speckit.gates.propose`; never write `policy.json`. As built: properties carry `"x-since"` in `policy.schema.json`, and only those newer than the version that projected the project (manifest, else `.runtime-version`) are listed, so a fresh install and old settings produce no notices
- [x] T032 [US3] Tests: `tests/test-hooks.sh` (local rule refuses after an allow, cannot override a shipped block, unreadable rule refuses, git-hook local rules get args; bulk-staging matrix on/off; `test_no_secret_leak.py` → ask JSON, `.env`/`id_rsa`/`x.pem`/`.netrc` → block); `tests/test-project.sh` (local dir untouched and unreported across an upgrade; policy notice printed, `policy.json` byte-identical); canary additions for a local rule and bulk staging; mutation-check
- [x] T033a [US3] (#95) Protect the local rules from the agent: protect-files blocks Write/Edit under `hooks.local.d/` (also in raw mode); validate-bash asks for a command that appears to modify a protected path (`hooks.local.d` plus `protected_files.extra` literal prefixes); `GATES_BUILTIN_PROTECTED` in `lib/policy.sh` puts `hooks.local.d/**` in `gates_protected_list`, so commit-msg and `pr-check.sh` require the trailers; tests at all three boundaries, mutation-checked
- [x] T033 [P] [US3] README: local extension point section, bulk-staging knob, the block-vs-ask table

  ```accept
  # verifies: FR-015
  set -eu
  h=extension/runtime/hooks/claude/protect-files.sh
  out="$(printf '%s' '{"tool_input":{"file_path":"tests/test_no_secret_leak.py"}}' | "$h" 2>/dev/null)"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null
  ! printf '%s' '{"tool_input":{"file_path":"config/.env"}}' | "$h" >/dev/null 2>&1
  ```

**Checkpoint**: local rules survive; PR 4.

---

## Phase 7: User Story 4 — Only Core Principles are principles (Priority: P4) — #82

**Goal**: parser scope (research R11).

**Independent Test**: quickstart US4.

- [x] T034 [US4] Scope `gates_const_parse` in `extension/runtime/lib/constitution.sh`: track the current `##` heading; `###` opens a principle only under `## Core Principles`; a `gates:enforce` marker elsewhere → `MALFORMED` "gates:enforce marker outside Core Principles"; no Core Principles section → zero principles plus a notice from `constitution.sh check`
- [x] T035 [US4] Tests in `tests/test-constitution.sh`: `###` under Additional Constraints not counted; marker there → MALFORMED with the line; missing section notice; this repo's constitution still yields its 5 principles; mutation-check

  ```accept
  # verifies: FR-016
  set -eu
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  printf '## Core Principles\n\n### I. One\n\n## Additional Constraints\n\n### Budget\n\ntext\n' >"$tmp/c.md"
  . extension/runtime/lib/constitution.sh
  [ "$(gates_const_parse "$tmp/c.md" | grep -c '^PRINCIPLE')" -eq 1 ]
  ```

**Checkpoint**: PR 5.

---

## Phase 8: User Story 5 — Installs that only work on the author's machine are caught (Priority: P5) — #73

**Goal**: doctor install hygiene, dev warning, prettier-clean package
(research R3, R12).

**Independent Test**: quickstart US5.

- [x] T036 [US5] Extend `extension/runtime/doctor.sh` install section (sourcing `lib/install-state.sh`): for each `registered_commands.claude[]` map `speckit.gates.x` → `.claude/skills/speckit-gates-x/SKILL.md`; symlink or non-file → fail with the reinstall-from-release hint (a `.claude/commands/<name>.md` file also counts as installed); `dev` state → warn; vendored script or git hook without exec bit → recommendation (as built: nothing runs the vendored copy and `project.sh` restores the bit)
- [x] T037 [US5] `project.sh` warns on a `dev` install (FR-018); report missing `.prettierignore`/markdownlint ignores for projected paths and append them only with `--add-lint-ignores`
- [x] T038 [P] [US5] `tests/test-package.sh`: the release-shaped tree passes default `prettier --check` (as built: this check already existed in `test-package.sh`)
- [x] T039 [US5] Tests in `tests/test-doctor.sh`: symlinked skill → fail; dangling → fail; regular files → pass; `.specify-dev/` → warning; vendored hook 644 → fail; mutation-check
- [x] T040 [P] [US5] README: `--dev` is for developing spec-gates only, with the symptom (dangling skills in fresh clones)

  ```accept
  # verifies: FR-017
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_project)"; trap 'fx_cleanup "$d"' EXIT
  (cd "$d" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null) || true
  jq '.extensions.gates.registered_commands.claude = ["speckit.gates.doctor"]' "$d/.specify/extensions/.registry" >"$d/r.json"
  mv "$d/r.json" "$d/.specify/extensions/.registry"
  mkdir -p "$d/.claude/skills/speckit-gates-doctor"
  ln -sf /nonexistent "$d/.claude/skills/speckit-gates-doctor/SKILL.md"
  ! (cd "$d" && bash .specify/extensions/gates/runtime/doctor.sh --installed-only >/dev/null 2>&1)
  ```

**Checkpoint**: PR 6.

---

## Phase 9: User Story 6 — Sensible defaults and coexistence (Priority: P6) — #74

**Goal**: hook-manager adapters, behavioral git probe, dormant doctor,
branding docs (research R13, R15, R16).

**Independent Test**: quickstart US6.

- [x] T041 [US6] Add `GATES_PROBE=1` handling to the top of `extension/runtime/hooks/git/pre-commit` and `commit-msg` (print `gates-probe:<name>:<runtime-version>` to stderr, exit 1, before reading policy or args)
- [x] T042 [US6] Create `extension/runtime/lib/managers.sh`: `gates_detect_manager` (`plain|husky|lefthook|pre-commit|unknown`, detection order from research R13, hooks dir via `git rev-parse --git-path hooks`), `gates_manager_entry <kind> <hook>` (contracts/hooks.md table), append-only appliers for husky (shell line) and lefthook / pre-commit YAML (only when the key or id is absent and the file has no tabs; otherwise print and return 1), `gates_git_probe` (run the resolved hook directly with `GATES_PROBE=1` and a temp message file; pass only on the marker)
- [x] T043 [US6] Wire managers into `project.sh`: detect before writing; `plain` → stub; known manager → print the entry in `--dry-run`, apply with `--wire-manager`, else exit 1 after reporting; `unknown` → print the call-through, exit 1; never write a manager's generated files; run `gates_git_probe` in the proof phase
- [x] T044 [US6] Doctor: git probe section (fail naming the resolved path and manager); `--installed-only` mode (registry, vendored version, skills, exec bits, dev warning; skips every `.specify/gates/` section); install state `removed`/`mismatch` → fail in normal mode
- [x] T045 [US6] Remove the call-through-into-generated-files guidance from `speckit.gates.init.md` step 5 and the upgrade command's foreign-hook rule; point both at `project.sh` manager handling
- [x] T046 [US6] Branding: refusal text in `extension/runtime/lib/message.sh` names `git.ai_branding.allow_phrases`; README attribution section with the agent attribution case and an `allow_phrases` example for a repo that integrates a provider; README "when commands and skills are registered" note
- [x] T047 [US6] Tests: `tests/test-project.sh` manager matrix with sandboxed fixtures built without network (husky: `core.hooksPath=.husky/_` plus shim files; lefthook: `lefthook.yml` plus a generated-marker hook; pre-commit: marker hook plus `.pre-commit-config.yaml`; unknown hooksPath) — generated files byte-identical after every run, entries applied only with `--wire-manager`, YAML with existing key → printed + exit 1, unknown → exit 1; `tests/test-doctor.sh` probe pass/fail and `--installed-only` on a dormant fixture; `tests/test-hooks.sh` `GATES_PROBE` marker with every policy rule off; mutation-check
- [x] T048 [P] [US6] README coexistence section (per manager: what gates writes, where, and the doctor probe)

  ```accept
  # verifies: FR-022a
  set -eu
  out="$(GATES_PROBE=1 extension/runtime/hooks/git/commit-msg /dev/null 2>&1 || true)"
  printf '%s' "$out" | grep -q '^gates-probe:commit-msg:'
  ! GATES_PROBE=1 extension/runtime/hooks/git/pre-commit >/dev/null 2>&1
  ```

**Checkpoint**: PR 7; every 0.4.0 issue has a merged fix.

---

## Phase 10: Polish & Release

- [ ] T048a (#98) Coverage: a report-only `coverage` CI job (kcov in node:26-slim, `scripts/coverage.sh` + `scripts/coverage-merge.py`, per-file table in the job summary, every PR and main), then tests for the gaps toward 85%: `lib/policy-infer.sh`, `lib/taskfile-detect.sh`, `hooks/git/pre-commit`, `project.sh` error paths, the contract, constitution and spec-gate libraries
- [ ] T049 Docs sweep: `docs/how-it-works.md`, `README.md` and the command docs agree on `project.sh`, holds, local rules, managers; `CHANGELOG.md` [Unreleased] lists #70–#74, #82, #83
- [ ] T050 Full local suite: `bash tests/run.sh`, `bash .specify/gates/verify.sh --boundary ci`, `bash .specify/gates/canary.sh`; stock macOS (`env -i … /bin/bash tests/run.sh` with the jq/shellcheck/node shim); container matrix (no python3, python3-minimal, full python3) with `node:26-slim`
- [ ] T051 Release candidate: build the release-shaped zip, serve it on 127.0.0.1:8734, send both consumer peers a checklist (sha256, the documented upgrade path, `project.sh --dry-run` then one run, doctor, canary, an agent-created PR) and wait for both reports (SC-006)
- [ ] T052 Flip `**Status**: Complete` in `specs/005-upgrade-safe-projection/spec.md` as the final implementation commit, once every task is checked and every accept block passes
- [ ] T053a Release notes "Upgrading": commit `.specify/gates/.projected.sha256` and `.specify/gates/project.sh` with the upgrade; the first `project.sh` run on a 0.3.x projection compares against the shipped known-release hashes (US2), so only real local edits stop it
- [ ] T053 Bump PR: `extension.yml` and `npm version 0.4.0 --no-git-tag-version` in lockstep, CHANGELOG dated heading; tag only on Frank's explicit go; after release update the pinned install URLs and the catalog issue

  ```accept
  # verifies: SC-004
  set -eu
  for n in 70 71 72 73 74 82 83; do
    grep -q "#$n" CHANGELOG.md
  done
  ```

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001–T003)**: T001 first (docs PR); T002/T003 parallel.
- **Foundational (T004–T006)**: blocks US1–US6. US7 does not need it.
- **US7 (T007–T012)**: independent; ships first.
- **US1 (T013–T020)**: needs T004/T005.
- **US2 (T021–T027)**: needs US1 (`project.sh`).
- **US3 (T028–T033)**: hook parts need only US7; T031/T032 project parts need US1.
- **US4 (T034–T035)**: independent of everything.
- **US5 (T036–T040)**: needs T005; T037 needs US1.
- **US6 (T041–T048)**: needs US1; doctor parts need T005.
- **Polish (T049–T053)**: after all stories.

### Parallel Opportunities

- T002, T003 together; T005, T006 alongside T004 once its interface is fixed.
- US4 can be built at any time, in parallel with any story.
- Within stories: README tasks (T018, T033, T040, T048), T009, T024, T038.

## Implementation Strategy

1. **MVP**: Setup + US7 (#83). Closes the fail-open hooks, needs no new libraries.
2. Foundational + US1: the projection script; downstream upgrades become one approval.
3. US2, US3, US4, US5, US6 in order, one PR each, rebased after every merge.
4. Polish, RC with both consumer peers, bump, tag on Frank's go.

## Notes

- Never name downstream consumer projects in any committed text.
- Commit standards: Conventional Commits, no emoji, subject ≤ 72 chars,
  `pr-check.sh` before every `gh pr create`.
- After editing `extension/runtime/`, re-copy into `.specify/gates/`
  (gitignored) before running the local suite.
