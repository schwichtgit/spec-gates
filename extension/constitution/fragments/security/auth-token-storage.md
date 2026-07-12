---
id: security/auth-token-storage
statement: "Session tokens live in HTTP-only cookies, never in localStorage or any script-readable store."
rationale: "A token any script can read is a token any XSS can steal; the browser boundary is the only durable one."
surface: prose
tags: [security, project-type/spa]
provenance: "accelno frontend corpus (2026): HTTP-only cookies, baseQueryWithReauth refresh"
---

Authentication tokens are stored in HTTP-only, Secure cookies. They are never
placed in `localStorage`, `sessionStorage`, or any location reachable from
page JavaScript, so a cross-site-scripting flaw cannot exfiltrate a session.
