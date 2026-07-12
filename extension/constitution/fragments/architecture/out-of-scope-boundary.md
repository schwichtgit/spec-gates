---
id: architecture/out-of-scope-boundary
statement: "The repository names what it must not contain and which sibling owns each excluded concern."
rationale: "Unstated boundaries erode; an explicit out-of-scope list is what keeps a service from quietly absorbing its neighbors."
surface: prose
tags: [architecture, all-projects]
provenance: "CPF-8 baseline (accelno corpus, 2026): out-of-scope section naming the owning sibling"
---

The constitution states what this repository deliberately does not own, and
for each excluded concern names the sibling repository or service that does.
A change that would cross one of those boundaries is redirected to its owner
rather than absorbed here.
