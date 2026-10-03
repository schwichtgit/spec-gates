#!/usr/bin/env python3
"""Turn the output of tests/run.sh into a JUnit report and a PR comment.

tests/run.sh frames each suite with its name and ends it with
`>> <suite> OK|FAILED`; inside, every case prints one line starting with
`PASS:`, `FAIL:` or `SKIP:`. A suite that fails without a FAIL line (it
crashed, or its summary disagreed) gets a synthetic failing case, so a
broken suite can never read as green.

Usage:
  test-report.py <run.log> --junit <out.xml>
  test-report.py <run.log> --comment <out.md> [--coverage <summary.txt>]
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET

SUITE_RE = re.compile(r"^  (test-[\w-]+)\s*$")
END_RE = re.compile(r"^>> (test-[\w-]+) (OK|FAILED)\s*$")
CASE_RE = re.compile(r"^(PASS|FAIL|SKIP): (.*)$")


def parse(path):
    """Return [(suite, status, [(result, name, detail)])] in run order."""
    suites, current, cases = [], None, []
    with open(path, errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            m = SUITE_RE.match(line)
            if m:
                current, cases = m.group(1), []
                continue
            m = END_RE.match(line)
            if m and current == m.group(1):
                status = m.group(2)
                if status == "FAILED" and not any(r == "FAIL" for r, _, _ in cases):
                    cases.append(("FAIL", "suite exited non-zero", "see the run log"))
                suites.append((current, status, cases))
                current = None
                continue
            m = CASE_RE.match(line)
            if m and current:
                result, text = m.groups()
                detail = ""
                d = re.search(r"\s\((.*)\)\s*$", text)
                if result != "PASS" and d:
                    detail, text = d.group(1), text[: d.start()]
                cases.append((result, text.strip(), detail))
    if current:  # the run stopped inside a suite
        suites.append((current, "FAILED", cases + [("FAIL", "suite did not finish", "see the run log")]))
    return suites


def counts(cases):
    p = sum(1 for r, _, _ in cases if r == "PASS")
    f = sum(1 for r, _, _ in cases if r == "FAIL")
    s = sum(1 for r, _, _ in cases if r == "SKIP")
    return len(cases), p, s, f


def write_junit(suites, out):
    root = ET.Element("testsuites")
    total = [0, 0, 0]
    for name, _status, cases in suites:
        n, _p, s, f = counts(cases)
        total = [total[0] + n, total[1] + f, total[2] + s]
        ts = ET.SubElement(root, "testsuite", name=name, tests=str(n), failures=str(f), skipped=str(s))
        for result, case, detail in cases:
            tc = ET.SubElement(ts, "testcase", classname=name, name=case)
            if result == "FAIL":
                ET.SubElement(tc, "failure", message=detail or "failed")
            elif result == "SKIP":
                ET.SubElement(tc, "skipped", message=detail or "skipped")
    root.set("tests", str(total[0]))
    root.set("failures", str(total[1]))
    root.set("skipped", str(total[2]))
    ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)


def coverage_section(path):
    if not path or not os.path.exists(path):
        return []
    rows, total = [], None
    with open(path) as fh:
        for line in fh:
            m = re.match(r"^TOTAL (\d+)/(\d+) = ([\d.]+)%", line.strip())
            if m:
                total = m
                continue
            m = re.match(r"^\s*([\d.]+)%\s+(\d+)/(\d+)\s+(\S+)", line)
            if m:
                rows.append(m)
    if not total:
        return []
    out = ["", f"### Runtime line coverage: {total.group(3)}% ({total.group(1)}/{total.group(2)})", ""]
    out.append("Report only: coverage never fails the build (#98). Lowest-covered files:")
    out.append("")
    for m in rows[:5]:
        out.append(f"- `{m.group(4)}`: {m.group(1)}% ({m.group(2)}/{m.group(3)})")
    out.append("")
    out.append("_The full per-file table is in the coverage job summary and its artifact._")
    return out


def write_comment(suites, out, coverage):
    tot = [0, 0, 0, 0]
    for _, _, cases in suites:
        tot = [a + b for a, b in zip(tot, counts(cases))]
    failed = tot[3] > 0 or any(st == "FAILED" for _, st, _ in suites)
    lines = [f"### unit test results: {'FAIL' if failed else 'pass'}", ""]
    lines.append("| Suite | Tests | Passed | Skipped | Failed |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    for name, _status, cases in suites:
        n, p, s, f = counts(cases)
        lines.append(f"| `{name}` | {n} | {p} | {s} | {f} |")
    lines.append(f"| **all {len(suites)} suites** | **{tot[0]}** | **{tot[1]}** | **{tot[2]}** | **{tot[3]}** |")
    bad = [(sn, c, d) for sn, _, cs in suites for r, c, d in cs if r == "FAIL"]
    if bad:
        lines += ["", "#### Failures", ""]
        for sn, c, d in bad[:100]:
            lines.append(f"- `{sn}`: {c}" + (f" ({d})" if d else ""))
        if len(bad) > 100:
            lines.append(f"- … and {len(bad) - 100} more; see the check run")
    skips = [(sn, c, d) for sn, _, cs in suites for r, c, d in cs if r == "SKIP"]
    if skips:
        lines += ["", f"<details><summary>Skipped ({len(skips)})</summary>", ""]
        for sn, c, d in skips:
            lines.append(f"- `{sn}`: {c}" + (f" ({d})" if d else ""))
        lines += ["", "</details>"]
    lines += coverage_section(coverage)
    server = os.environ.get("GITHUB_SERVER_URL")
    repo = os.environ.get("GITHUB_REPOSITORY")
    run = os.environ.get("GITHUB_RUN_ID")
    if server and repo and run:
        url = f"{server}/{repo}/actions/runs/{run}"
        lines += ["", "---", "", f"Per-test results: the **unit test results** check. [Workflow run]({url}) · [artifacts]({url}#artifacts)"]
    with open(out, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--junit")
    ap.add_argument("--comment")
    ap.add_argument("--coverage")
    a = ap.parse_args()
    suites = parse(a.log)
    if not suites:
        sys.exit(f"test-report: no suites found in {a.log}")
    if a.junit:
        write_junit(suites, a.junit)
    if a.comment:
        write_comment(suites, a.comment, a.coverage)


if __name__ == "__main__":
    main()
