#!/usr/bin/env python3
"""Make Slither able to fail CI. Compares a Slither JSON report with the triaged baseline and exits 1 on anything new.

A finding's key is its detector plus the code it points at (no line numbers), so moving code around doesn't re-open a
triaged finding but changing the flagged code does. Every baseline entry must say why it is accepted (docs/SLITHER_TRIAGE.md).
Usage: slither_gate.py <slither.json> <baseline.json>
"""
import json
import os
import re
import sys

GUARDED = {
    "src/CurvePad.sol": ["createLaunch", "buy", "buyWithOKB", "sell", "graduate"],
    "src/FeeVault.sol": ["claim", "claimCreator"],
    "src/PositionLocker.sol": ["collect"],
}


def element(e):
    parent = e.get("type_specific_fields", {}).get("parent", {})
    grand = parent.get("type_specific_fields", {}).get("parent", {}).get("name", "")
    sig = parent.get("type_specific_fields", {}).get("signature") or parent.get("name", "")
    return f"{e.get('type')}:{grand + '.' if grand else ''}{sig}.{e.get('name')}"


def key(d):
    return d["check"] + " | " + " ; ".join(sorted(element(e) for e in d.get("elements", [])))


def keyed(detectors):
    """Key -> finding, numbering identical keys so a second identical finding can't hide behind the first."""
    out, seen = {}, {}
    for d in sorted(detectors, key=key):
        k = key(d)
        seen[k] = seen.get(k, 0) + 1
        out[k if seen[k] == 1 else f"{k} #{seen[k]}"] = d
    return out


def check_guards_and_suppressions(root):
    """The reentrancy triage rests on these guards, and Slither's key doesn't see modifiers, so check them directly.
    Inline suppressions or a triage database would hide findings from this gate, so they are not allowed."""
    problems = []
    for path, names in GUARDED.items():
        src = open(os.path.join(root, path)).read()
        for name in names:
            m = re.search(rf"function {name}\([^{{;]*\{{", src)
            if not m or "nonReentrant" not in m.group(0):
                problems.append(f"{path}: {name}() must be nonReentrant (triage #6)")
    for dirpath, _, files in os.walk(os.path.join(root, "src")):
        for f in files:
            if "slither-disable" in open(os.path.join(dirpath, f)).read():
                problems.append(f"{os.path.join(dirpath, f)}: slither-disable comments are not allowed; use the baseline")
    if os.path.exists(os.path.join(root, "slither.db.json")):
        problems.append("slither.db.json must not be committed; use the baseline")
    return problems


try:
    report = json.load(open(sys.argv[1]))
except (OSError, ValueError) as err:
    sys.exit(f"FAIL: no usable Slither report ({err}); Slither itself failed")
if not report.get("success"):
    sys.exit(f"FAIL: Slither reported an error: {report.get('error')}")
baseline = json.load(open(sys.argv[2]))
if any(not isinstance(v, str) or len(v.strip()) < 20 for v in baseline.values()):
    sys.exit("FAIL: every baseline entry needs a written justification")
problems = check_guards_and_suppressions(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
if problems:
    sys.exit("FAIL:\n  " + "\n  ".join(problems))

found = keyed(report.get("results", {}).get("detectors", []))
new = [k for k in sorted(found) if k not in baseline]
stale = [k for k in sorted(baseline) if k not in found]
print(f"Slither: {len(found)} distinct findings, {len(found) - len(new)} triaged, {len(new)} new, {len(stale)} stale baseline")
for k in stale:
    print(f"  stale (no longer reported, remove it): {k}")
for k in new:
    d = found[k]
    print(f"  NEW [{d.get('impact')}/{d.get('confidence')}] {k}\n      {d.get('description', '').strip().splitlines()[0][:200]}")
if stale:
    sys.exit(f"FAIL: {len(stale)} baseline entries were not reported: Slither analysed less than before, or a finding "
             "is gone and its entry must be removed so it can't return unreviewed.")
if new:
    sys.exit(f"FAIL: {len(new)} untriaged Slither finding(s). Fix them, or justify them in {sys.argv[2]} and docs/SLITHER_TRIAGE.md.")
print("OK: no untriaged findings")
