# Security Policy

spec-gates is an enforcement layer: it runs as Claude Code hooks, git hooks,
and CI steps in consuming repositories. Vulnerabilities in it — a gate that
can be bypassed silently, a hook that executes untrusted input, a probe that
touches user files — are security issues even when no data is exfiltrated.

## Supported versions

| Version                 | Supported |
| ----------------------- | --------- |
| Latest release (v0.1.x) | yes       |
| Older tags              | no        |

## Reporting a vulnerability

Please do **not** open a public issue for security reports.

- Preferred: [GitHub private vulnerability reporting](https://github.com/schwichtgit/spec-gates/security/advisories/new)
- Alternatively: email <schwicht@googlemail.com> with `spec-gates security` in
  the subject

You can expect an acknowledgement within a week. Confirmed issues are fixed on
`main`, released as a new tagged version, and credited in the release notes
unless you prefer otherwise.

## Verifying releases

Each release ships the installable package alongside a SHA-256 checksum and a
sigstore keyless signature produced by the release workflow (from v0.2.0 on):

```bash
sha256sum -c gates-X.Y.Z.zip.sha256
cosign verify-blob \
  --bundle gates-X.Y.Z.zip.sigstore.json \
  --certificate-identity-regexp '^https://github.com/schwichtgit/spec-gates/.github/workflows/release.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  gates-X.Y.Z.zip
```

A successful verification proves the artifact was built by this repository's
release workflow on GitHub Actions, not assembled elsewhere.

## Scope notes for researchers

The agent boundary raises the cost of noncompliance; it does not claim to make
noncompliance impossible (see "Threat model honesty" in
`docs/how-it-works.md`). Reports that a sufficiently privileged local agent
can edit its own hook wiring describe the documented threat model, not a
vulnerability — the git and CI boundaries exist precisely to backstop that.
Bypasses of the git/CI boundaries, silent-skip behaviors, sandbox escapes of
the canary probes, or attestation forgery that survives `doctor` are all very
much in scope.
