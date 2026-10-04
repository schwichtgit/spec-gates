#!/usr/bin/env python3
"""Line coverage of the shipped runtime from a coverage report (#98).

The report is bashcov's SimpleCov .resultset.json (what CI produces) or a
kcov cobertura.xml. Most tests run the runtime from sandbox copies (a projected
.specify/gates/, a vendored .specify/extensions/gates/runtime/,
.claude/hooks/gates/, hooks installed in .git/hooks), so the report has the
same script under many paths. Each path is mapped back to its source file
under extension/runtime/ and the covered lines are unioned. A copy counts
only when it is the same file as the source: tests that run an older
release's files (from the v0.3.x tags) would otherwise add hits on
unrelated line numbers. For bashcov, "the same file" means a line array
that ends within a few lines of the source's end (bashcov trims trailing
lines that hold no code); its executable-line set varies with what ran, so
it cannot identify a copy, and executable lines are the union over the
copies. For kcov, "the same file" means the same executable-line set. A shipped script that never
ran counts as 0% of its non-blank, non-comment lines.

Usage: coverage-merge.py <.resultset.json|cobertura.xml> <repo-root> [--markdown]
"""
import collections
import json
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


def load(report):
    """Yield (filename, {line: hits}, total-lines or None) per reported file."""
    if report.endswith(".json"):
        with open(report) as fh:
            data = json.load(fh)
        for run in data.values():
            for filename, cov in run.get("coverage", {}).items():
                hits = cov["lines"] if isinstance(cov, dict) else cov
                yield filename, {i + 1: h for i, h in enumerate(hits) if h is not None}, len(hits)
    else:
        for cls in ET.parse(report).getroot().iter("class"):
            yield cls.get("filename"), {
                int(l.get("number")): int(l.get("hits")) for l in cls.find("lines")
            }, None


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    report, repo = sys.argv[1], sys.argv[2]
    markdown = "--markdown" in sys.argv[3:]
    entries = collections.defaultdict(list)
    for filename, lines, length in load(report):
        rels, is_source = sources(filename)
        for rel in rels:
            entries[rel].append((is_source, lines, length))

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
        with open(f"{repo}/extension/runtime/{rel}") as fh:
            text = fh.read()
        n_lines = len(text.splitlines())
        if text.startswith("#!/bin/sh"):
            # bash tracing cannot follow /bin/sh; test-hooks covers it by
            # behavior. Listed, but kept out of the total.
            n = sum(1 for x in text.splitlines() if x.strip() and not x.strip().startswith("#"))
            rows.append((rel, n, None, "not traceable (/bin/sh); tested by behavior"))
            continue
        es = entries.get(rel, [])
        ref, covered = None, set()
        if es and es[0][2] is not None:
            same = [l for _, l, length in es if n_lines - 8 <= length <= n_lines]
            if same:
                ref = set().union(*(set(l) for l in same))
                covered = set().union(*({k for k, v in l.items() if v > 0} for l in same))
        else:
            ref = next((set(l) for src, l, _ in es if src), None)
            if ref is None and es:
                ref = set(collections.Counter(frozenset(l) for _, l, _ in es).most_common(1)[0][0])
            for _, l, _ in es:
                if ref is not None and set(l) == ref:
                    covered |= {k for k, v in l.items() if v > 0}
        if ref is None:
            n = sum(1 for x in text.splitlines() if x.strip() and not x.strip().startswith("#"))
            rows.append((rel, n, 0, "never run"))
            total += n
            continue
        rows.append((rel, len(ref), len(covered), ""))
        total += len(ref)
        hit += len(covered)

    def pct(h, n):
        return 100.0 * h / n if n else 100.0

    rows.sort(key=lambda r: 101.0 if r[2] is None else pct(r[2], r[1]))
    overall = pct(hit, total)
    if markdown:
        print(f"### Runtime line coverage: {overall:.1f}% ({hit}/{total})\n")
        print("| Coverage | Lines | File |")
        print("| ---: | ---: | --- |")
        for rel, n, h, note in rows:
            extra = f" ({note})" if note else ""
            if h is None:
                print(f"| n/a | {n} lines | `{rel}`{extra} |")
            else:
                print(f"| {pct(h, n):.1f}% | {h}/{n} | `{rel}`{extra} |")
        print("\nReport only (#98): this job never fails on the number. "
              "/bin/sh files are not traceable and are left out of the total.")
    else:
        for rel, n, h, note in rows:
            if h is None:
                print(f"{'n/a':>7}  {n:11d} {rel} {note}".rstrip())
            else:
                print(f"{pct(h, n):6.1f}%  {h:5d}/{n:<5d} {rel} {note}".rstrip())
        print(f"\nTOTAL {hit}/{total} = {overall:.1f}%")


if __name__ == "__main__":
    main()
