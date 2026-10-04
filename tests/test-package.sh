#!/bin/bash
set -euo pipefail

# Package tests: what a CONSUMER's repo sees after installing the extension.
#
# Projection puts our files in someone else's tree, so their repo-wide lint
# runs reach our vendored content. Formatting cannot solve that in general
# (any style we pick fails somebody's config) — but our shipped markdown must
# at least be clean under DEFAULT tooling, and the nested markdownlint config
# that keeps it that way must actually be in the package. Both are asserted
# here against a staged copy that mirrors the release workflow exactly.
#
# Skips (never fails) when the pinned linters are not installed.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/node_modules/.bin"

PASS=0
FAIL=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-package-test)"
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

expect() { # <name> <actual> <wanted>
    TOTAL=$((TOTAL + 1))
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (got '$2', want '$3')"
        FAIL=$((FAIL + 1))
    fi
}

# `if` rather than `A && B || C`: the latter is SC2015 on shellcheck 0.9.0
# (what unpinned CI used to install) even where it is harmless.
present() { # <path>
    if [[ -e "$1" ]]; then echo yes; else echo no; fi
}

# Stage the package exactly as .github/workflows/release.yml does.
STAGE="$WORKDIR/consumer/.specify/extensions/gates"
mkdir -p "$STAGE"
cp -R "$REPO_ROOT/extension/extension.yml" "$REPO_ROOT/extension/commands" \
    "$REPO_ROOT/extension/runtime" "$REPO_ROOT/extension/ci" \
    "$REPO_ROOT/extension/constitution" "$STAGE/"
# Tolerated so a MISSING file is reported by the assertions below rather than
# aborting the suite — the assertions are the diagnostic, not the copy.
cp "$REPO_ROOT/extension/.markdownlint-cli2.jsonc" "$STAGE/" 2>/dev/null || true
cp "$REPO_ROOT/README.md" "$REPO_ROOT/LICENSE" "$REPO_ROOT/CHANGELOG.md" "$STAGE/"

echo "=== package contents ==="
expect "nested markdownlint config ships at the extension root" \
    "$(present "$STAGE/.markdownlint-cli2.jsonc")" "yes"
expect "constitution corpus ships (issue #31 regression)" \
    "$(present "$STAGE/constitution/manifest.yml")" "yes"

# release.yml probes the zip for the files the commands need: every probe
# must exist in the staged package, and the probe list must cover the git
# hooks and the shellcheck installer with its pins (#172).
PROBES="$(sed -n 's/^ *for probe in \(.*\); do$/\1/p' "$REPO_ROOT/.github/workflows/release.yml" | tr ' ' '\n')"
expect "release.yml has a probe list" "$([[ -n "$PROBES" ]] && echo yes || echo no)" "yes"
MISSING_PROBES=""
while IFS= read -r probe; do
    [[ -n "$probe" && ! -e "$STAGE/${probe#gates/}" ]] && MISSING_PROBES="$MISSING_PROBES $probe"
done <<<"$PROBES"
expect "every release.yml probe is in the package" "$MISSING_PROBES" ""
for f in hooks/git/pre-commit hooks/git/commit-msg hooks/git/pre-merge-commit hooks/git/stub.sh \
    install-shellcheck.sh shellcheck.sha256; do
    expect "release.yml probes runtime/$f" \
        "$(grep -qxF "gates/runtime/$f" <<<"$PROBES" && echo yes || echo no)" "yes"
done

# Spec Kit's zip extraction keeps the execute bit only on *.sh files that
# carry it in the zip, which carries the git modes. A shipped script that is
# 100644 in git arrives 644, and project.sh then flips it to 755 inside the
# consumer's vendored copy: a mode diff in every repo that commits
# .specify/extensions/. So every shipped script is 100755 in git.
NOT_EXEC="$(cd "$REPO_ROOT" && git ls-files -s extension/runtime \
    | awk '$1 != "100755" && ($4 ~ /\.sh$/ || $4 ~ /\/hooks\/git\//) { print $4 }' | tr '\n' ' ')"
expect "every shipped runtime script is 100755 in git" "$NOT_EXEC" ""

# Spec Kit 1.x scaffolds a provides.config entry only as <id>-config.yml
# (the names `remove --keep-config` preserves) and warns on every install
# otherwise (#118). The policy lives at .specify/gates/policy.json, seeded by
# init, so the manifest declares no config file at all.
expect "extension.yml declares no provides.config" \
    "$(awk '/^provides:/ { p = 1; next } /^[^[:space:]]/ { p = 0 } p && /^  config:/ { print "yes" }' "$REPO_ROOT/extension/extension.yml")" ""

echo ""
echo "=== a consumer's repo-wide lint sweep over the installed extension ==="

if [[ -x "$BIN/markdownlint-cli2" ]]; then
    # No config at the consumer root: our nested config must carry the file.
    ML_OUT="$(cd "$WORKDIR/consumer" && "$BIN/markdownlint-cli2" '**/*.md' 2>&1)" || true
    ML_ERRORS="$(printf '%s\n' "$ML_OUT" | grep -cE ' (error|warning) MD[0-9]+' || true)"
    expect "shipped markdown has zero markdownlint errors under consumer defaults" \
        "$ML_ERRORS" "0"
    if [[ "$ML_ERRORS" != "0" ]]; then
        printf '%s\n' "$ML_OUT" | grep -E ' (error|warning) MD[0-9]+' | head -5 | awk '{ print "    " $0 }'
    fi
else
    echo "SKIP: markdownlint-cli2 not installed (npm ci to enable this check)"
fi

if [[ -x "$BIN/prettier" ]]; then
    # Default prettier settings: our files are authored with defaults, so a
    # consumer running stock prettier must see a clean tree. (A consumer with
    # a CUSTOM config is handled by the .prettierignore seeding in init step
    # 3c — no shipped formatting can satisfy every config.)
    PR_RC=0
    (cd "$WORKDIR/consumer" && "$BIN/prettier" --check . >"$WORKDIR/prettier.out" 2>&1) || PR_RC=$?
    expect "shipped files are clean under default prettier" "$PR_RC" "0"
    [[ "$PR_RC" -ne 0 ]] && grep '^\[warn\]' "$WORKDIR/prettier.out" | head -5 | awk '{ print "    " $0 }'
else
    echo "SKIP: prettier not installed (npm ci to enable this check)"
fi

echo ""
echo "=== we do not ship files that violate our own policy ==="

# The package carries executable shell into someone else's repository. It must
# satisfy the same shellcheck bar this project enforces on its own sources —
# at the PINNED version, because shellcheck's findings differ across releases
# (0.9.0 flags SC2015 where 0.11.0 does not, which is how an unpinned CI
# turned green local runs red).
PINNED_SC="$(awk '$1 == "shellcheck" { print $2 }' "$REPO_ROOT/.tool-versions" 2>/dev/null || true)"
expect "shellcheck version is declared in .tool-versions" \
    "$([[ -n "$PINNED_SC" ]] && echo yes || echo no)" "yes"

if command -v shellcheck >/dev/null 2>&1; then
    LOCAL_SC="$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2 }')"
    if [[ -n "$PINNED_SC" && "$LOCAL_SC" != "$PINNED_SC" ]]; then
        echo "SKIP: local shellcheck $LOCAL_SC != pinned $PINNED_SC — the parity gate reports this drift; not asserting findings against an unpinned binary"
    else
        SHIPPED_SH="$(find "$STAGE" -name '*.sh' -type f | sort)"
        SC_RC=0
        # shellcheck disable=SC2086  # deliberate word split of the file list
        shellcheck $SHIPPED_SH >"$WORKDIR/shellcheck.out" 2>&1 || SC_RC=$?
        expect "shipped shell passes shellcheck $PINNED_SC" "$SC_RC" "0"
        [[ "$SC_RC" -ne 0 ]] && head -12 "$WORKDIR/shellcheck.out" | awk '{ print "    " $0 }'
    fi
else
    echo "SKIP: shellcheck not installed"
fi

# Every shipped shell file must parse under the oldest bash it meets: hooks
# run through their shebang (#!/bin/bash), which on macOS is bash 3.2.
# 0.3.4 shipped a validate-pr.sh that only bash >= 4 could parse. Runs
# wherever a 3.x /bin/bash exists (any Mac, and the macOS CI job).
echo ""
echo "=== shipped shell parses under the stock macOS bash (3.2) ==="
if [[ -x /bin/bash ]] && /bin/bash -c '[[ ${BASH_VERSINFO[0]} -lt 4 ]]'; then
    BAD32=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in *.json | *.md | *.yml | *.yaml) continue ;; esac
        head -n 1 "$f" | grep -q 'bash' || [[ "$f" == *.sh ]] || continue
        /bin/bash -n "$f" 2>/dev/null || BAD32="$BAD32 ${f#"$REPO_ROOT"/}"
    done < <(find "$REPO_ROOT/extension/runtime" -type f | sort)
    expect "every shipped script parses under /bin/bash $(/bin/bash -c 'echo $BASH_VERSION')" "${BAD32:-none}" "none"
else
    echo "SKIP: no bash 3.x at /bin/bash (the macOS CI job covers this)"
fi

# Every script runs under pipefail. `echo "$x" | grep -q` (or `| head`)
# stops reading at the first match, the writer dies of SIGPIPE once $x
# outgrows the pipe buffer, and pipefail turns the match into a miss: the
# secret scan let a key through in any staged file over 64 KB (#117). Feed
# grep -q from a here-string instead.
echo ""
echo "=== no pipe into grep -q or head in shipped shell (#117) ==="
PIPED="$(grep -rnE '(^|[^|])[|][[:space:]]*grep[[:space:]]+-[A-Za-z]*q|(echo|printf)[^|]*[|][[:space:]]*head' \
    "$REPO_ROOT/extension/runtime" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
expect "no shipped line pipes into grep -q or head" "${PIPED:-none}" "none"
# shellcheck disable=SC2001  # sed, not ${PIPED//...}: the slow form in bash 3.2
[[ -n "$PIPED" ]] && sed "s|$REPO_ROOT/||; s/^/    /" <<<"$PIPED"

# The CI templates install shellcheck with the projected installer (#138):
# the pinned version, for the runner's architecture, checksum-verified.
# Exercised offline: curl and uname are stubs, the release asset a local
# tarball holding a fake shellcheck.
echo ""
echo "=== shellcheck installer ships and verifies (#138) ==="
expect "installer ships in the runtime" "$(present "$STAGE/runtime/install-shellcheck.sh")" "yes"
expect "installer checksums ship in the runtime" "$(present "$STAGE/runtime/shellcheck.sha256")" "yes"
for plat in linux.x86_64 linux.aarch64; do
    expect "shipped checksums cover shellcheck $PINNED_SC on $plat" \
        "$(awk -v a="shellcheck-v$PINNED_SC.$plat.tar.xz" '$2 == a { n++ } END { print n + 0 }' \
            "$STAGE/runtime/shellcheck.sha256")" "1"
done
# This repository's CI runs the same installer and checksums (test-parity
# checks the workflow), so there is no second pin file to compare (#148).

IW="$WORKDIR/installer"
mkdir -p "$IW/proj/.specify/gates" "$IW/stub" "$IW/asset/shellcheck-v9.9.9" "$IW/evil/shellcheck-v9.9.9"
cp "$REPO_ROOT/extension/runtime/install-shellcheck.sh" "$IW/proj/.specify/gates/"
printf '#!/bin/sh\necho "version: 9.9.9"\n' >"$IW/asset/shellcheck-v9.9.9/shellcheck"
printf '#!/bin/sh\necho "version: 6.6.6"\n' >"$IW/evil/shellcheck-v9.9.9/shellcheck"
chmod +x "$IW/asset/shellcheck-v9.9.9/shellcheck" "$IW/evil/shellcheck-v9.9.9/shellcheck"
cat >"$IW/stub/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >>"$STUB_LOG"
case "$url" in
    *api.github.com*) cp "$STUB_RELEASE" "$out" ;;
    *) cp "$STUB_ASSET" "$out" ;;
esac
EOF
cat >"$IW/stub/uname" <<'EOF'
#!/bin/bash
case "$1" in
    -s) echo "$STUB_OS" ;;
    -m) echo "$STUB_ARCH" ;;
esac
EOF
chmod +x "$IW/stub/curl" "$IW/stub/uname"
if (cd "$IW/asset" && tar -cJf "$IW/good.tar.xz" shellcheck-v9.9.9) 2>/dev/null \
    && (cd "$IW/evil" && tar -cJf "$IW/evil.tar.xz" shellcheck-v9.9.9) 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
        GOOD_SHA="$(sha256sum "$IW/good.tar.xz" | cut -d' ' -f1)"
    else
        GOOD_SHA="$(shasum -a 256 "$IW/good.tar.xz" | cut -d' ' -f1)"
    fi
    write_sums() { # <file> <platform>...
        local f="$1" p
        shift
        : >"$f"
        for p in "$@"; do printf '%s  shellcheck-v9.9.9.%s.tar.xz\n' "$GOOD_SHA" "$p" >>"$f"; done
    }
    write_sums "$IW/proj/.specify/gates/shellcheck.sha256" linux.x86_64 linux.aarch64
    printf '# pins\nshellcheck 9.9.9\n' >"$IW/proj/.tool-versions"
    # inst <os> <arch> <asset> [args...] -> exit code; output in $IW/out
    inst() {
        local os="$1" arch="$2" asset="$3" rc=0
        shift 3
        rm -rf "${IW:?}/bin"
        : >"$IW/log"
        PATH="$IW/stub:$PATH" CLAUDE_PROJECT_DIR="$IW/proj" STUB_OS="$os" STUB_ARCH="$arch" \
            STUB_ASSET="$asset" STUB_LOG="$IW/log" STUB_RELEASE="$IW/release.json" \
            bash "$IW/proj/.specify/gates/install-shellcheck.sh" "${@:-$IW/bin}" >"$IW/out" 2>&1 || rc=$?
        echo "$rc"
    }

    expect "linux x86_64: pinned version installs" "$(inst Linux x86_64 "$IW/good.tar.xz")" "0"
    expect "linux x86_64: the installed binary is the pinned one" \
        "$("$IW/bin/shellcheck" --version 2>/dev/null)" "version: 9.9.9"
    expect "linux x86_64: downloads the x86_64 asset of the pinned release" \
        "$(cat "$IW/log")" "https://github.com/koalaman/shellcheck/releases/download/v9.9.9/shellcheck-v9.9.9.linux.x86_64.tar.xz"
    expect "linux aarch64: installs" "$(inst Linux aarch64 "$IW/good.tar.xz")" "0"
    expect "linux aarch64: downloads the aarch64 asset" \
        "$(grep -c 'shellcheck-v9.9.9.linux.aarch64.tar.xz$' "$IW/log")" "1"
    expect "arm64 is read as aarch64" "$(inst Linux arm64 "$IW/good.tar.xz")" "0"
    expect "tampered download: refused" "$(inst Linux x86_64 "$IW/evil.tar.xz")" "1"
    expect "tampered download: reported as a checksum mismatch" \
        "$(grep -c 'checksum mismatch for shellcheck-v9.9.9.linux.x86_64.tar.xz' "$IW/out")" "1"
    expect "tampered download: nothing installed" "$(present "$IW/bin/shellcheck")" "no"
    expect "platform without a pinned checksum: refused" "$(inst Darwin arm64 "$IW/good.tar.xz")" "1"
    expect "platform without a pinned checksum: says so" \
        "$(grep -c 'no pinned checksum for shellcheck-v9.9.9.darwin.aarch64.tar.xz' "$IW/out")" "1"
    expect "platform without a pinned checksum: nothing downloaded" "$(wc -l <"$IW/log" | tr -d ' ')" "0"
    expect "unsupported architecture: refused" "$(inst Linux riscv64 "$IW/good.tar.xz")" "1"
    # An unknown flag is a usage error, never the install directory (#172).
    for flag in --force --bogus -f; do
        expect "$flag: usage error" "$(cd "$IW" && inst Linux x86_64 "$IW/good.tar.xz" "$flag")" "1"
        expect "$flag: named as an unknown option" \
            "$(grep -c "unknown option: $flag" "$IW/out")" "1"
        expect "$flag: nothing downloaded" "$(wc -l <"$IW/log" | tr -d ' ')" "0"
        expect "$flag: no directory of that name" "$(present "$IW/$flag")" "no"
    done
    expect "two arguments: usage error" "$(inst Linux x86_64 "$IW/good.tar.xz" "$IW/bin" extra)" "1"
    expect "two arguments: says so" "$(grep -c 'too many arguments' "$IW/out")" "1"
    write_sums "$IW/proj/.specify/gates/shellcheck.local.sha256" darwin.aarch64
    expect "a project pin in shellcheck.local.sha256 is honoured" "$(inst Darwin arm64 "$IW/good.tar.xz")" "0"
    rm -f "$IW/proj/.specify/gates/shellcheck.local.sha256"

    # --update: digests come from the release API and must match a fresh
    # download; the pins land in shellcheck.local.sha256, other versions kept.
    jq -n --arg d "sha256:$GOOD_SHA" '{assets: [("darwin.aarch64", "darwin.x86_64", "linux.aarch64", "linux.x86_64")
        | {name: "shellcheck-v9.9.9.\(.).tar.xz", digest: $d}]}' >"$IW/release.json"
    printf 'abc  shellcheck-v1.0.0.linux.x86_64.tar.xz\n' >"$IW/proj/.specify/gates/shellcheck.local.sha256"
    expect "--update pins the version in .tool-versions" "$(inst Linux x86_64 "$IW/good.tar.xz" --update)" "0"
    expect "--update writes all four platforms" \
        "$(grep -c "^$GOOD_SHA  shellcheck-v9.9.9\." "$IW/proj/.specify/gates/shellcheck.local.sha256")" "4"
    expect "--update keeps the pins of other versions" \
        "$(grep -c 'shellcheck-v1.0.0.linux.x86_64.tar.xz' "$IW/proj/.specify/gates/shellcheck.local.sha256")" "1"
    expect "--update leaves the shipped checksums alone" \
        "$(wc -l <"$IW/proj/.specify/gates/shellcheck.sha256" | tr -d ' ')" "2"
    expect "--update refuses a download that differs from the published digest" \
        "$(inst Linux x86_64 "$IW/evil.tar.xz" --update)" "1"

    # Run from the packaging source (#159): the installer in
    # extension/runtime/ of a git work tree, no CLAUDE_PROJECT_DIR, started
    # from another directory. The project pins live in the project's
    # .specify/gates/, never next to the script.
    SRC="$IW/proj/extension/runtime"
    mkdir -p "$SRC"
    cp "$REPO_ROOT/extension/runtime/install-shellcheck.sh" "$IW/proj/.specify/gates/shellcheck.sha256" "$SRC/"
    git -C "$IW/proj" init -q
    rm -f "$IW/proj/.specify/gates/shellcheck.local.sha256"
    inst_src() { # <os> <arch> [args...] -> exit code; output in $IW/out
        local os="$1" arch="$2" rc=0
        shift 2
        rm -rf "${IW:?}/bin"
        (cd "$IW" && env -u CLAUDE_PROJECT_DIR PATH="$IW/stub:$PATH" STUB_OS="$os" STUB_ARCH="$arch" \
            STUB_ASSET="$IW/good.tar.xz" STUB_LOG="$IW/log" STUB_RELEASE="$IW/release.json" \
            bash "$SRC/install-shellcheck.sh" "${@:-$IW/bin}") >"$IW/out" 2>&1 || rc=$?
        echo "$rc"
    }
    expect "from the source tree: --update succeeds" "$(inst_src Linux x86_64 --update)" "0"
    expect "from the source tree: --update writes the project's .specify/gates pin file" \
        "$(grep -c "^$GOOD_SHA  shellcheck-v9.9.9\." "$IW/proj/.specify/gates/shellcheck.local.sha256" 2>/dev/null)" "4"
    expect "from the source tree: nothing written next to the script" \
        "$(present "$SRC/shellcheck.local.sha256")" "no"
    expect "from the source tree: the project pin is honoured on install" "$(inst_src Darwin arm64)" "0"
    rm -f "$IW/proj/.specify/gates/shellcheck.local.sha256"
    rm -rf "$IW/proj/.git" "$IW/proj/extension"

    printf 'nodejs 22\n' >"$IW/proj/.tool-versions"
    expect "no shellcheck pin in .tool-versions: refused" "$(inst Linux x86_64 "$IW/good.tar.xz")" "1"
    expect "no shellcheck pin: says so" "$(grep -c 'declares no shellcheck version' "$IW/out")" "1"
else
    echo "SKIP: tar cannot write .tar.xz here (install xz to run the installer checks)"
fi

echo ""
echo "test-package: $PASS/$TOTAL passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
