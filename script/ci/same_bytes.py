#!/usr/bin/env python3
"""Fail unless two forge build directories hold identical runtime and creation bytecode for every deployable contract.
via-IR output depends on the forge version and on which files are in the build, so "the tests passed" only speaks for
the deployed contracts if those tests ran on these exact bytes. Usage: same_bytes.py <out_a> <out_b>"""
import hashlib, json, os, sys

CONTRACTS = ["CurvePad", "PositionLocker", "Graduator", "CircHook", "TokenDeployer", "LaunchToken"]
bad = 0
for name in CONTRACTS:
    a, b = (json.load(open(os.path.join(d, f"{name}.sol", f"{name}.json"))) for d in sys.argv[1:3])
    for part in ("bytecode", "deployedBytecode"):
        x, y = a[part]["object"], b[part]["object"]
        same = x == y
        bad += not same
        print(f"{name:16} {part:17} {(len(x) - 2) // 2:6} B {hashlib.sha256(x.encode()).hexdigest()[:12]} {'same' if same else 'DIFFERENT'}")
sys.exit(f"{bad} bytecode mismatch(es)" if bad else 0)
