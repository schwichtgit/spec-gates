# spec-gates

**Deterministic quality enforcement for [Spec Kit](https://github.com/github/spec-kit) projects.**

Spec Kit is a guidance layer: templates, prompts, and checklists _ask_ the
agent to comply. spec-gates is the enforcement layer underneath it: hooks
and pipelines that _force_ compliance — the bash call is rejected, the
protected file is refused, the session cannot end with failing checks.

Extracted from
[claude-project-foundation](https://github.com/schwichtgit/claude-project-foundation)
(now EOL), whose spec-authoring half was superseded by Spec Kit and whose
enforcement half lives on here.

## One policy, three boundaries

```text
                    .specify/gates/policy.json
                               |
        +----------------------+----------------------+
        |                      |                      |
  AGENT BOUNDARY         GIT BOUNDARY            CI BOUNDARY
  Claude Code hooks      pre-commit /            GitHub Actions /
  PreToolUse: block      commit-msg:             GitLab CI /
    protected files,     block main commits,     Jenkins:
    dangerous bash       conventional commits,
  PostToolUse:           no AI-isms
    auto-format
  Stop: refuse to end            \                    /
    with failing checks           \                  /
        \                          \                /
         +------------->  .specify/gates/verify.sh  <-----------+
                          (identical at every boundary)
```

**The parity property:** if the agent boundary passed, the git boundary
passes; if the git boundary passed, CI passes. Every boundary runs the
same `verify.sh` with the same policy. `tests/test-ci-parity.sh` asserts
this invariant.

## Install

```bash
specify extension add gates --from https://github.com/schwichtgit/spec-gates
```

Spec Kit's community catalog is discovery-only (`install_allowed: false`),
so `--from <url>` is the install path even after `gates` is listed there;
catalog listing buys discoverability, not a bare `specify extension add gates`.

Then, in Claude Code:

```text
/speckit.gates.init        # infer policy, project runtime, wire hooks, self-test
/speckit.gates.ci github   # project the CI boundary (github | gitlab | jenkins)
```

From that point the normal Spec Kit loop is unchanged —
`/speckit.specify → clarify → plan → tasks → implement` — but during
`implement` every edit is auto-formatted, protected files and dangerous
bash are refused with actionable messages, and the session cannot stop
with red checks. After `implement`, the extension's `after_implement`
hook offers a gate run before you move to commit/PR.

## Commands

| Command                  | Purpose                                                          |
| ------------------------ | ---------------------------------------------------------------- |
| `/speckit.gates.init`    | Infer policy, project runtime, wire agent + git hooks, self-test |
| `/speckit.gates.verify`  | Run the full suite on demand (also runs after `implement`)       |
| `/speckit.gates.doctor`  | Health check: hooks wired, policy valid, versions in sync        |
| `/speckit.gates.ci`      | Project CI enforcement: `github` \| `gitlab` \| `jenkins`        |
| `/speckit.gates.upgrade` | Re-project runtime after update; never touches policy.json       |

## Workflow-engine integration

Insert a hard gate into any Spec Kit workflow:

```yaml
- id: quality-gate
  type: shell
  run: .specify/gates/verify.sh --boundary ci --json
- id: human-review
  type: gate
  prompt: "Gates green. Approve merge preparation?"
```

A red gate pauses the run; fix and `specify workflow resume <run_id>`.

## Agent support

Git and CI boundaries work with **any** coding agent — they are plain git
hooks and CI jobs. Agent-boundary enforcement currently supports
**Claude Code** (hook system). Adapters for other harnesses are welcome
as they grow hook APIs.

## Design rules

- `policy.json` is user-owned: `init` seeds it, `upgrade` never overwrites it.
- Runtime is **projected** (copied) into the repo — enforcement survives
  extension removal and works for every collaborator who clones.
- Fail closed: a gate that cannot demonstrably block is reported broken.

## License

MIT
