#!/usr/bin/env python3
"""Make Slither able to fail CI. Compares a Slither JSON report with the triaged baseline and exits 1 on anything new.

A finding's key is its detector plus the code it points at (no line numbers), so moving code around doesn't re-open a
triaged finding but changing the flagged code does. Every baseline entry must say why it is accepted (docs/SLITHER_TRIAGE.md).
Usage: slither_gate.py <slither.json> <baseline.json>
"""
import json
import sys


def key(d):
    parts = []
    for e in d.get("elements", []):
        parent = e.get("type_specific_fields", {}).get("parent", {}).get("name", "")
        parts.append(f"{e.get('type')}:{parent}.{e.get('name')}")
    return d["check"] + " | " + " ; ".join(sorted(set(parts)))


try:
    report = json.load(open(sys.argv[1]))
except (OSError, ValueError) as err:
    sys.exit(f"FAIL: no usable Slither report ({err}); Slither itself failed")
if not report.get("success"):
    sys.exit(f"FAIL: Slither reported an error: {report.get('error')}")
baseline = json.load(open(sys.argv[2]))
if any(not str(v).strip() for v in baseline.values()):
    sys.exit("FAIL: every baseline entry needs a justification")

found = {}
for d in report.get("results", {}).get("detectors", []):
    found.setdefault(key(d), d)
new = [k for k in sorted(found) if k not in baseline]
stale = [k for k in sorted(baseline) if k not in found]
print(f"Slither: {len(found)} distinct findings, {len(found) - len(new)} triaged, {len(new)} new, {len(stale)} stale baseline")
for k in stale:
    print(f"  stale (no longer reported, remove it): {k}")
for k in new:
    d = found[k]
    print(f"  NEW [{d.get('impact')}/{d.get('confidence')}] {k}\n      {d.get('description', '').strip().splitlines()[0][:200]}")
if new:
    sys.exit(f"FAIL: {len(new)} untriaged Slither finding(s). Fix them, or justify them in {sys.argv[2]} and docs/SLITHER_TRIAGE.md.")
print("OK: no untriaged findings")
