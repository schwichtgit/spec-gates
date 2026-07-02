---
description: "Check enforcement health: hooks wired, policy valid, runtime version matches extension"
---

# Gates Doctor

Diagnose the enforcement setup without changing anything.

## Checks

1. **Policy**: `.specify/gates/policy.json` exists and validates against
   `.specify/gates/policy.schema.json` (jq-based validation).
2. **Runtime**: `.specify/gates/verify.sh` and `lib/` present and
   executable; `.specify/gates/.runtime-version` matches the installed
   extension version (warn on drift → suggest `/speckit.gates.upgrade`).
3. **Agent boundary**: `.claude/settings.json` contains the gates hook
   entries and the referenced scripts exist in `.claude/hooks/gates/`.
4. **Git boundary**: `.git/hooks/pre-commit` and `commit-msg` invoke the
   gates hooks.
5. **CI boundary**: at least one projected pipeline references
   `verify.sh --boundary ci` (report which platform, or "not projected").
6. **Tools**: jq present; each formatter/linter named in policy.json
   resolvable on PATH (warn, don't fail, for missing optional tools).

## Output

A table: check | status (OK / WARN / FAIL) | remediation. Exit summary
states whether enforcement is fully active at each boundary.
