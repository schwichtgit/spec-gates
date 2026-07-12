---
id: workflow/branch-first
statement: "All changes reach main via pull request; direct commits to main are refused."
rationale: "Direct-to-main commits were the top pre-CPF incident source; the branch is where review and gates actually run."
surface: git-hook
ref: pre-commit
tags: [workflow, all-projects]
provenance: "CPF-8 baseline (accelno corpus, 2026): CPF_ALLOW_MAIN_COMMIT=1 release-only escape"
---

Every change reaches `main` through a pull request. The git boundary refuses
a direct commit to `main`; the only escape is an explicit, per-commit
override reserved for release automation. Feature branches are cut from
`main` and merged back through review.
