---
id: governance/codeowners-governance
statement: "The governance surface itself — CI, hooks, policy, and specs — carries CODEOWNERS review."
rationale: "If the files that define enforcement are not themselves reviewed, enforcement can be edited away in an ordinary PR."
surface: prose
tags: [governance, posture/team]
provenance: "Kahi corpus (2026): CODEOWNERS on .claude/, ci/, hooks, .specify/memory/"
---

The directories that define how the project is governed — CI configuration,
hook scripts, the enforcement policy, and the specifications — require review
from designated owners. A change that weakens a gate cannot merge on the same
authority as an ordinary code change.
