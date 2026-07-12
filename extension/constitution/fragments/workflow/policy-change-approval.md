---
id: workflow/policy-change-approval
statement: "Enforcement policy and generated spec artifacts are changed only by prior human approval, never hand-edited in place."
rationale: "The one file that decides what blocks must itself be governed, or enforcement quietly softens itself."
surface: agent-hook
ref: protect-files.sh
tags: [workflow, governance, all-projects]
provenance: "accelno halo corpus (2026): no-policy-changes.sh hook with one-shot marker"
---

Changes to the enforcement policy require prior human approval and land as a
reviewed diff. Machine-generated artifacts (specs, plans, tracking files) are
never hand-edited to pass a gate; the input that produced them is corrected
instead.
