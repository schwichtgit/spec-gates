---
description: "Project CI enforcement for a platform: github | gitlab | jenkins"
---

# Project CI Enforcement

Project a CI pipeline (or pipeline fragment) that runs the identical
`verify.sh --boundary ci` used by the agent and git boundaries.

## User Input

```text
$ARGUMENTS
```

Required: one of `github`, `gitlab`, `jenkins`.

## Steps

1. Resolve the extension's `ci/<platform>/` directory.
2. Show the user what will be written:
   - github → `.github/workflows/gates.yml`
   - gitlab → merge the `gates` job fragment into `.gitlab-ci.yml`
     (create if absent; if present, show the merged diff first)
   - jenkins → print the `Quality Gates` stage fragment and, if a
     `Jenkinsfile` exists, propose the insertion diff
3. Never clobber an existing workflow silently; always show a diff.
4. Remind the user of the parity property: this job runs the same
   entrypoint as the Stop hook and pre-commit, so local green == CI green.
