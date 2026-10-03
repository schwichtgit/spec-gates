#!/usr/bin/env python3
"""Line coverage of the shipped runtime from a kcov cobertura report (#98).

Most tests run the runtime from sandbox copies (a projected
.specify/gates/, a vendored .specify/extensions/gates/runtime/,
.claude/hooks/gates/, hooks installed in .git/hooks), so kcov reports the
same script under many paths. Each path is mapped back to its source file
under extension/runtime/ and the covered lines are unioned. A copy counts
only when kcov found the same executable lines in it as in the source:
tests that run an older release's files (from the v0.3.x tags) would
otherwise add hits on unrelated line numbers. A shipped script that never
ran counts as 0% of its non-blank, non-comment lines.

Usage: coverage-merge.py <cobertura.xml> <repo-root> [--markdown]
"""
import collections
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

PATTERNS = [
    (r"/extension/runtime/(.+)$", ""),
    (r"/\.specify/extensions/gates/runtime/(.+)$", ""),
    (r"/\.specify/gates/lib/([^/]+)$", "lib/"),
    (r"/\.specify/gates/hooks/([^/]+)$", "hooks/git/"),
    (r"/\.specify/gates/([^/]+\.sh)$", ""),
    (r"/\.claude/hooks/gates/([^/]+)$", "hooks/claude/"),
]


def sources(filename):
    """Runtime-relative source paths a reported file may be a copy of."""
    fn = "/" + filename.lstrip("/")
    for pat, prefix in PATTERNS:
        m = re.search(pat, fn)
        if m:
            return [prefix + m.group(1)], "/extension/runtime/" in fn
    m = re.search(r"/\.git/hooks/(pre-commit|commit-msg)$", fn)
    if m:
        return ["hooks/git/" + m.group(1), "hooks/git/stub.sh"], False
    return [], False


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    xml_path, repo = sys.argv[1], sys.argv[2]
    markdown = "--markdown" in sys.argv[3:]
    entries = collections.defaultdict(list)
    for cls in ET.parse(xml_path).getroot().iter("class"):
        rels, is_source = sources(cls.get("filename"))
        lines = {int(l.get("number")): int(l.get("hits")) for l in cls.find("lines")}
        for rel in rels:
            entries[rel].append((is_source, lines))

    shipped = subprocess.run(
        ["git", "-C", repo, "ls-files", "extension/runtime"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    shipped = [
        f[len("extension/runtime/"):]
        for f in shipped
        if f.endswith(".sh") or "/hooks/git/" in f
    ]

    rows, total, hit = [], 0, 0
    for rel in shipped:
        es = entries.get(rel, [])
        ref = next((set(l) for src, l in es if src), None)
        if ref is None and es:
            ref = set(collections.Counter(frozenset(l) for _, l in es).most_common(1)[0][0])
        if ref is None:
            with open(f"{repo}/extension/runtime/{rel}") as fh:
                n = sum(1 for x in fh if x.strip() and not x.strip().startswith("#"))
            rows.append((rel, n, 0, "never run"))
            total += n
            continue
        covered = set()
        for _, l in es:
            if set(l) == ref:
                covered |= {k for k, v in l.items() if v > 0}
        rows.append((rel, len(ref), len(covered), ""))
        total += len(ref)
        hit += len(covered)

    def pct(h, n):
        return 100.0 * h / n if n else 100.0

    rows.sort(key=lambda r: pct(r[2], r[1]))
    overall = pct(hit, total)
    if markdown:
        print(f"### Runtime line coverage: {overall:.1f}% ({hit}/{total})\n")
        print("| Coverage | Lines | File |")
        print("| ---: | ---: | --- |")
        for rel, n, h, note in rows:
            extra = f" ({note})" if note else ""
            print(f"| {pct(h, n):.1f}% | {h}/{n} | `{rel}`{extra} |")
        print("\nReport only (#98): this job never fails on the number. "
              "`hooks/git/stub.sh` is /bin/sh, which kcov's bash mode cannot trace.")
    else:
        for rel, n, h, note in rows:
            print(f"{pct(h, n):6.1f}%  {h:5d}/{n:<5d} {rel} {note}".rstrip())
        print(f"\nTOTAL {hit}/{total} = {overall:.1f}%")


if __name__ == "__main__":
    main()
