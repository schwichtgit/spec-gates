<!-- markdownlint-disable-file MD041 -->
<!-- PR body has no H1 title by design; sections start at H2. -->

## What

<!-- One or two sentences: what this change does and why. -->

## Boundaries touched

<!-- Delete any that do not apply. -->

- [ ] Agent (Claude hooks: protect-files / validate-bash / verify-quality / …)
- [ ] Git (pre-commit / commit-msg)
- [ ] CI (`ci/` templates or `.github/workflows/`)
- [ ] Runtime lib / `verify.sh`
- [ ] Policy schema / template
- [ ] Docs / tests only

## Checklist

- [ ] `bash tests/run.sh` passes locally
- [ ] The gate is green (`verify.sh --boundary ci`) — CI enforces this
- [ ] New behaviour has test coverage
- [ ] Commit subjects follow Conventional Commits and carry no AI-isms
