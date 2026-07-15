#!/bin/bash
set -euo pipefail

# Generate the spec-kit catalog update issue body for a release.
#
#   catalog-issue-draft.sh <version>        # e.g. 0.3.2
#
# Emits, on stdout, a complete issue body whose "### <label>" headings match
# github/spec-kit's extension_submission form field-for-field — their
# add-community-extension agentic workflow parses exactly those headings and
# opens the in-place catalog update PR (add vs update is decided upstream by
# catalog lookup). Every volatile field (version, URL, counts, command list,
# tags) is extracted from extension.yml so the draft cannot drift from the
# manifest; run it from the repo root at the release tag.
#
# Used by release.yml to publish the draft in the job summary; usable by hand:
#   .github/scripts/catalog-issue-draft.sh 0.3.2 > /tmp/body.md
#   gh issue create -R github/spec-kit \
#     --title "[Extension]: Update gates (Quality Gates — Enforcement Layer) to 0.3.2" \
#     --body-file /tmp/body.md

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: catalog-issue-draft.sh <version>" >&2
    exit 1
fi

MANIFEST="extension/extension.yml"
if [[ ! -f "$MANIFEST" ]]; then
    echo "catalog-issue-draft: $MANIFEST not found (run from the repo root)" >&2
    exit 1
fi

REPO_URL="https://github.com/schwichtgit/spec-gates"
DOWNLOAD_URL="$REPO_URL/releases/download/v$VERSION/gates-$VERSION.zip"

DESC="$(awk '/^  description: >-$/{f=1;next} f&&/^  [a-z_]+:/{exit} f{gsub(/^ +/,"");printf "%s ",$0} END{print ""}' "$MANIFEST" | sed 's/ $//')"
SPECKIT_REQ="$(sed -n 's/^  speckit_version: "\(.*\)"$/\1/p' "$MANIFEST")"
TAGS="$(sed -n '/^tags:/,$p' "$MANIFEST" | grep '^  - ' | sed 's/^  - "\(.*\)"$/\1/' | paste -sd ',' - | sed 's/,/, /g')"
CMD_COUNT="$(grep -c '^      file: commands/' "$MANIFEST")"
HOOK_COUNT="$(awk '/^hooks:/{f=1;next} f&&/^[a-z]/{exit} f&&/^  [a-z_]+:$/{c++} END{print c+0}' "$MANIFEST")"
COMMANDS="$(awk '/^    - name: /{n=$3} /^      description: "/{d=$0; sub(/^      description: "/,"",d); sub(/"$/,"",d); printf "- `/%s` — %s\n", n, d}' "$MANIFEST")"
TOOLS="$(awk '/^  tools:/{f=1;next} f&&/^[a-z]/{exit} f&&/name:/{n=$3} f&&/required:/{printf "- %s (%s)\n", n, ($2=="true"?"required":"optional")}' "$MANIFEST")"
SUITES="$(grep -o 'test-[a-z-]*' tests/run.sh | sort -u | wc -l | tr -d ' ')"
TAG_DATE="$(date -u +%Y-%m-%dT00:00:00Z)"

TAGS_JSON="$(printf '%s' "$TAGS" | tr -d ' ' | jq -R -c 'split(",")')"

cat <<EOF
### Extension ID

gates

### Extension Name

Quality Gates (Enforcement Layer)

### Version

$VERSION

### Description

$DESC

### Author

schwichtgit

### Repository URL

$REPO_URL

### Download URL

$DOWNLOAD_URL

### License

MIT

### Homepage (optional)

$REPO_URL

### Documentation URL (optional)

$REPO_URL/blob/main/docs/how-it-works.md

### Changelog URL (optional)

$REPO_URL/releases/tag/v$VERSION

### Required Spec Kit Version

$SPECKIT_REQ

### Required Tools (optional)

$TOOLS
- node with pinned prettier/markdownlint-cli2 (optional, for the lint gates)
- shellcheck (optional, for shell linting)

### Number of Commands

$CMD_COUNT

### Number of Hooks (optional)

$HOOK_COUNT

### Tags

$TAGS

### Key Features

$COMMANDS

### Testing Checklist

- [x] Extension installs successfully via download URL
- [x] All commands execute without errors
- [x] Documentation is complete and accurate
- [x] No security vulnerabilities identified
- [x] Tested on at least one real project

### Submission Requirements

- [x] Valid \`extension.yml\` manifest included
- [x] README.md with installation and usage instructions
- [x] LICENSE file included
- [x] GitHub release created with version tag
- [x] All command files exist and are properly formatted
- [x] Extension ID follows naming conventions (lowercase-with-hyphens)

### Testing Details

**Tested on:** macOS (bash 3.2, BSD toolchain) and Linux/GNU (ubuntu-latest CI).

**Test project:** the extension repository dogfoods itself — CI projects the
released runtime and runs \`verify.sh --boundary ci\`, the canary suite
(planted violations must be rejected), and $SUITES test suites on every PR.
The release asset is sha256-checksummed and sigstore-signed; the release
workflow fails closed if the tag, manifest, and package versions disagree, or
if required package contents (manifest, constitution corpus, runtime) are
missing from the zip.

**Downstream:** in production use by real downstream projects (GitHub and
GitLab CI backstops); the 0.3.1 line carries fixes from structured downstream
feedback (issues #31–#34).

### Example Usage

\`\`\`bash
# Install (this exact version)
specify extension add gates --from $DOWNLOAD_URL

# Or always the latest release
specify extension add gates --from $REPO_URL/releases/latest/download/gates.zip

# Set up enforcement (infer policy, project runtime, wire hooks, self-test)
/speckit.gates.init

# Prove it holds
/speckit.gates.verify
\`\`\`

### Proposed Catalog Entry

\`\`\`json
$(jq -n \
    --arg desc "This is an UPDATE of the existing 'gates' entry — replace version, download_url, provides, and updated_at in place; preserve created_at, downloads, and stars." \
    --arg version "$VERSION" \
    --arg url "$DOWNLOAD_URL" \
    --arg speckit "$SPECKIT_REQ" \
    --argjson commands "$CMD_COUNT" \
    --argjson hooks "$HOOK_COUNT" \
    --argjson tags "$TAGS_JSON" \
    --arg updated "$TAG_DATE" \
    '{ _note: $desc,
       gates: {
         version: $version,
         download_url: $url,
         requires: { speckit_version: $speckit },
         provides: { commands: $commands, hooks: $hooks },
         tags: $tags,
         updated_at: $updated } }')
\`\`\`

### Additional Context

Update of the existing \`gates\` catalog entry (first listed at 0.1.0 via
github/spec-kit PR #3431). The entry's \`provides\` counts changed since
listing: $CMD_COUNT commands and $HOOK_COUNT hooks. Release assets are
sha256-checksummed and sigstore keyless-signed; verification instructions are
in the release notes.
EOF
