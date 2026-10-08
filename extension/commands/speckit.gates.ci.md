---
description: "Project CI enforcement for a platform: github | gitlab | jenkins (optionally --protect the default branch)"
---

# Project CI Enforcement

Project a CI pipeline (or pipeline fragment) that runs the identical
`verify.sh --boundary ci` used by the agent and git boundaries. Optionally
configure the **server-side boundary**: branch protection that makes the CI
check non-bypassable.

## User Input

```text
$ARGUMENTS
```

Required: one of `github`, `gitlab`, `jenkins`.
Optional: `--protect` (github only) — also require the gates check + a pull
request on the default branch.

## Steps

0. **Prerequisites — the remote must exist.** CI enforcement runs on the
   hosting platform, so a remote project/repository must exist BEFORE this
   is useful. Check `git remote get-url origin`:
   - No remote (typical greenfield): STOP and say so explicitly. Guide the
     user: create the project on the platform first (GitHub: `gh repo
create`; GitLab: `glab repo create` or the web UI; Jenkins: the SCM
     the job will poll), then `git remote add origin <url>` and push.
     Offer to re-run afterwards. Projecting the pipeline file locally
     without a remote is fine to offer, but be clear nothing enforces
     until the repo exists server-side and the branch is pushed.
   - Remote present: verify it is reachable (`git ls-remote origin` — a
     created-locally-only project fails here) before proceeding, and
     match the platform argument against the remote URL (warn on
     `gitlab` with a github.com remote and vice versa).
1. Resolve the extension's `ci/<platform>/` directory. The templates run
   `.specify/gates/install-shellcheck.sh`; if it is missing, the projected
   runtime predates it, so run `/speckit.gates.upgrade` first.
2. Show the user what will be written:
   - github → `.github/workflows/gates.yml`
   - gitlab → merge the `gates` job fragment into `.gitlab-ci.yml`
     (create if absent; if present, show the merged diff first)
   - jenkins → print the `Quality Gates` stage fragment and, if a
     `Jenkinsfile` exists, propose the insertion diff
3. Never clobber an existing workflow silently; always show a diff. If
   the repository already has a gates workflow or CI job (look for
   `verify.sh --boundary ci`), MERGE instead of replacing it. Add only
   what is missing (triggers, `fetch-depth: 0` / `GIT_DEPTH`, steps), and
   keep every stricter setting the user already has: SHA-pinned actions,
   `permissions`, `persist-credentials: false`, `concurrency`, timeouts,
   `npm ci` from the lockfile. The template is a floor, not a
   replacement. Whatever the merge looks like, the pipeline must still run
   the template's three commands: `verify.sh --boundary ci` (the `gates`
   step), `canary.sh` (`canary`) and `pr-check.sh` (`pr`). Doctor and
   `project.sh` recognize the steps by these commands and fail when one is
   missing. If the user deliberately leaves one out (for example `pr` in a
   repository without pull requests), record it as `ci:<step>` in
   `.specify/gates/.upgrade-holds` so the omission is visible, not
   silent: doctor and `project.sh` report each held step as a `[rec]`
   naming the check CI gives up. A repository that holds `pr` only to
   avoid the larger CI change can add that step on its own (see
   "Adopting only the pr step" below).
4. Remind the user of the parity property: this job runs the same
   entrypoint as the Stop hook and pre-commit, so local green == CI green.
   It holds only when CI resolves the same tool versions, so every template
   installs them before the gate runs:
   - node linters with `npm ci` from the lockfile (latest only when the
     repository pins nothing);
   - shellcheck with `bash .specify/gates/install-shellcheck.sh`, which
     installs the version pinned in `.tool-versions` for the runner's OS
     and architecture (linux and macOS, x86_64 and aarch64) and refuses a
     download that does not match `.specify/gates/shellcheck.sha256`.
     Without a `shellcheck` line in `.tool-versions` the templates install
     the distro package instead (GitHub, GitLab) or use the agent's own
     (Jenkins): unpinned, so offer to add the pin. spec-gates ships
     checksums for the version it pins; for another version, set it in
     `.tool-versions` and run
     `bash .specify/gates/install-shellcheck.sh --update`, which reads the
     release's published digests, checks them against a download, and
     writes `.specify/gates/shellcheck.local.sha256` (commit it; upgrades
     never touch it). shellcheck releases carry those digests only from
     v0.11.0 on; for an older version `--update` refuses, and the
     checksums go into that file by hand.

   When merging into an existing pipeline, keep these install steps. The
   `canary.sh` step fails when a linter the policy enables is not
   installed, so a pipeline that installs nothing is red, never a green
   run that linted nothing.

5. Explain the PR/MR step (`pr-check.sh`). It checks the PR/MR title and
   description against the commit-message rules, and Protected-Change
   declarations across the PR's commits (declarations in the description
   count for every commit, since a squash merge keeps the description).
   It also scans every commit in the range for secrets and forbidden
   files with the `pre-commit` rules, since commits made by
   `cherry-pick`, `rebase`, `am` or `revert` never ran that hook; a
   secret removed again later in the range still fails, because it is in
   the pushed history. Merge commits are checked too, and the rules come from the policy at
   the PR's base, so the PR cannot relax its own check. It needs full history (`fetch-depth: 0` / `GIT_DEPTH: 0`, set in the
   templates) and skips itself outside PR/MR pipelines. A base policy
   that is not valid fails the step (exit 2) and names the problem. A base
   with no policy (the PR that adopts spec-gates) is checked against the
   PR's own policy, with `policy.json`, the constitution, `hooks.local.d`
   and the contract artifacts protected regardless.

   The step runs the BASE revision's `pr-check.sh`: it extracts
   `.specify/gates/pr-check.sh` and `lib/` from the base with
   `git archive` into a temporary directory and runs that copy against
   the PR checkout with `GATES_RUNTIME_DIR` pointing at it, so a PR cannot
   replace the check that judges it. A base without `pr-check.sh` runs
   the PR's own copy and says so in the log. When merging into an
   existing pipeline, keep this extraction; a plain
   `bash .specify/gates/pr-check.sh` runs the PR's copy. A base whose
   `pr-check.sh` predates `GATES_RUNTIME_DIR` still loads the PR's
   libraries, so the protection starts once the base carries this
   release.

   The pipeline file, `verify.sh` and `canary.sh` still come from the PR.
   Recommend the human backstop every time: branch protection requiring
   the gates check and a review, and CODEOWNERS entries for
   `.specify/gates/**` and the pipeline file with code-owner review
   required (`--protect` sets up the first; CODEOWNERS is the user's to
   write). Platform notes:
   - github: the workflow also runs on `edited`, so a title or
     description change re-runs the check.
   - gitlab: editing an MR title or description does NOT start a
     pipeline. Re-run the pipeline after such edits, or require a fresh
     pipeline before merge. GitLab exposes the MR description to CI from
     16.7, and truncates long ones
     (`CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED`). In both cases the
     check fetches the full description from the API using
     `GATES_GITLAB_TOKEN` (offer to set it as a masked CI/CD variable
     holding a `read_api` token) or `CI_JOB_TOKEN`. A truncated
     description it cannot fetch fails the job. Before 16.7 without a
     token, only the title is checked, and the job prints a notice.
   - jenkins: only the title is available (`CHANGE_TITLE`); the
     description is not checked.

## Adopting only the pr step

A pipeline that runs the gates step but not the rest of the template can
add the `pr` step on its own, without the hardened workflow. A
`ci:pr` hold instead leaves PR titles, descriptions and Protected-Change
declarations unchecked in CI, and doctor reports it as a `[rec]` saying
so. When `project.sh` reports the `pr` step missing or held, it prints
the step for the platforms the gates run on; it never writes a pipeline
file. Each form runs the same commands as the template: it extracts the
base revision's `.specify/gates` with `git archive` and runs that
`pr-check.sh` with `GATES_RUNTIME_DIR`, so a PR cannot replace the
check that judges it. Add it to the pipeline file that runs
`verify.sh --boundary ci`: doctor looks for the step there.

GitHub: a step in the job that runs `verify.sh --boundary ci`, so the
required `gates` check covers it. That job checks out with
`fetch-depth: 0` (without full history the base revision cannot be
read), and the workflow runs on `pull_request` with `edited` among its
types. A PR opened by Dependabot or Renovate is checked without its
description, which quotes upstream release notes nobody in the project
wrote; its title, protected changes and secrets are still checked. Add
other bots' logins to the list in `GATES_PR_BODY`.

```yaml
# spec-gates pr step (GitHub): add under steps: of the job that runs
# verify.sh --boundary ci, so its required check covers it. That job
# checks out with fetch-depth: 0, and the workflow runs on
# pull_request with types: [opened, synchronize, reopened, edited].
- name: Check the pull request (text, protected changes, secrets)
  if: github.event_name == 'pull_request'
  env:
    GATES_PR_TITLE: ${{ github.event.pull_request.title }}
    GATES_PR_BODY: ${{ !contains(fromJSON('["dependabot[bot]", "renovate[bot]"]'), github.event.pull_request.user.login) && github.event.pull_request.body || '' }}
  run: |
    base="origin/$GITHUB_BASE_REF"
    if git cat-file -e "$base:.specify/gates/pr-check.sh" 2>/dev/null; then
      rt="$(mktemp -d)"
      git archive "$base" .specify/gates | tar -x -C "$rt"
      echo "pr-check: running the base revision's pr-check.sh ($base)"
      GATES_RUNTIME_DIR="$rt/.specify/gates" bash "$rt/.specify/gates/pr-check.sh"
    else
      echo "pr-check: the base ($base) has no pr-check.sh (adoption PR); running the pull request's own copy"
      bash .specify/gates/pr-check.sh
    fi
```

GitLab: a job of its own, with full history (`GIT_DEPTH: "0"`) and the
tools `pr-check.sh` needs, in merge request pipelines. With "Pipelines
must succeed" set, a failure blocks the merge.

```yaml
# spec-gates pr step (GitLab): add as a job to the pipeline file that
# runs verify.sh --boundary ci. pr-check.sh needs bash, git, jq and
# python3 (curl fetches a truncated description). Editing an MR title
# or description starts no pipeline; re-run it after such edits.
gates-pr:
  stage: test
  image: node:26-slim
  timeout: 10m
  variables:
    GIT_DEPTH: "0"
  before_script:
    - apt-get update -q && apt-get install -y -q jq git python3 curl
  script:
    - |
      set -e
      base="${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}"
      if [ -z "$base" ]; then
        bash .specify/gates/pr-check.sh
      elif git cat-file -e "$base:.specify/gates/pr-check.sh" 2>/dev/null; then
        rt="$(mktemp -d)"
        git archive "$base" .specify/gates | tar -x -C "$rt"
        echo "pr-check: running the base revision's pr-check.sh ($base)"
        GATES_RUNTIME_DIR="$rt/.specify/gates" bash "$rt/.specify/gates/pr-check.sh"
      else
        echo "pr-check: the base ($base) has no pr-check.sh (adoption MR); running the merge request's own copy"
        bash .specify/gates/pr-check.sh
      fi
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
```

Jenkins: a stage in the declarative pipeline's `stages`, on an agent with
bash, git and jq and a full-history checkout. Only the title is checked
(Jenkins exposes no description).

```groovy
// spec-gates pr step (Jenkins): add as a stage to the Jenkinsfile that
// runs verify.sh --boundary ci. The agent needs bash, git and jq, and a
// full-history checkout; outside PR builds the check skips itself.
stage('PR check') {
    steps {
        sh '''
            set -e
            if [ -z "${CHANGE_TARGET:-}" ]; then
                bash .specify/gates/pr-check.sh
                exit 0
            fi
            base="origin/$CHANGE_TARGET"
            if git cat-file -e "$base:.specify/gates/pr-check.sh" 2>/dev/null; then
                rt="$(mktemp -d)"
                git archive "$base" .specify/gates | tar -x -C "$rt"
                echo "pr-check: running the base revision's pr-check.sh ($base)"
                GATES_RUNTIME_DIR="$rt/.specify/gates" bash "$rt/.specify/gates/pr-check.sh"
            else
                echo "pr-check: the base ($base) has no pr-check.sh (adoption PR); running the pull request's own copy"
                bash .specify/gates/pr-check.sh
            fi
        '''
    }
}
```

## `--protect` (github)

Branch protection is the fourth boundary: the local git hook can be
bypassed (an agent with unrestricted bash can delete `.git/hooks`), but a
required status check on the default branch cannot. When `--protect` is
passed for github:

1. Resolve `owner/repo` and the default branch (`gh repo view`).
2. Confirm with the user before changing repository settings — this is
   outward-facing.
3. Create/replace a branch ruleset on the default branch that requires:
   - a pull request (`required_approving_review_count: 0` unless the user
     wants reviews),
   - the `gates` status check (`strict_required_status_checks_policy: true`),
   - and blocks force-push and deletion.

   ```bash
   gh api -X POST repos/<owner>/<repo>/rulesets --input - <<'JSON'
   {
     "name": "main protection (spec-gates)",
     "target": "branch",
     "enforcement": "active",
     "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
     "rules": [
       { "type": "deletion" },
       { "type": "non_fast_forward" },
       { "type": "pull_request", "parameters": {
           "required_approving_review_count": 0,
           "dismiss_stale_reviews_on_push": false,
           "require_code_owner_review": false,
           "require_last_push_approval": false,
           "required_review_thread_resolution": false } },
       { "type": "required_status_checks", "parameters": {
           "strict_required_status_checks_policy": true,
           "required_status_checks": [ { "context": "gates" } ] } }
     ]
   }
   JSON
   ```

4. Verify: `gh api repos/<owner>/<repo>/rules/branches/<default-branch>`
   should list `pull_request` and `required_status_checks`.

**Note:** branch protection and rulesets require a **public repository** or a
paid plan (GitHub Pro/Team) on private repos — the API returns HTTP 403
otherwise. If `--protect` fails with 403, tell the user their options
(make the repo public, or upgrade) rather than silently skipping; the CI
workflow itself still works regardless.

Scope: `--protect` covers only the enforcement-relevant server-side
settings (required check + PR). It does not write files: CODEOWNERS,
Dependabot and PR templates belong to a Spec Kit bundle or a template
repo. Still recommend a CODEOWNERS entry for `.specify/gates/**` and the
workflow file, with `require_code_owner_review` set in the ruleset: the
workflow comes from the PR under review, so owner review is what keeps a
PR from rewriting its own checks.
