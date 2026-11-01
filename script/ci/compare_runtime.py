#!/usr/bin/env python3
"""Compile a solc standard-JSON input and compare CurvePad's runtime with the deployed code.
Usage: compare_runtime.py <solc> <std-input.json> <address> <rpc>
Immutable slots (zeroed in compiler output) are masked on both sides; everything else, including the CBOR metadata
(IPFS hash + solc version) at the end, must match byte for byte."""
import json, subprocess, sys, urllib.request

solc, path, addr, rpc = sys.argv[1:5]
inp = json.load(open(path))
inp["settings"]["outputSelection"] = {"src/CurvePad.sol": {"CurvePad": ["evm.deployedBytecode.object", "evm.deployedBytecode.immutableReferences", "metadata"]}}
out = json.loads(subprocess.run([solc, "--standard-json"], input=json.dumps(inp), capture_output=True, text=True, check=True).stdout)
errs = [e for e in out.get("errors", []) if e["severity"] == "error"]
if errs:
    print("COMPILE ERRORS", errs[:3]); sys.exit(2)
c = out["contracts"]["src/CurvePad.sol"]["CurvePad"]
local = bytes.fromhex(c["evm"]["deployedBytecode"]["object"])
req = urllib.request.Request(rpc, json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [addr, "latest"]}).encode(), {"Content-Type": "application/json"})
chain = bytes.fromhex(json.load(urllib.request.urlopen(req))["result"][2:])
a, b = bytearray(local), bytearray(chain)
for refs in c["evm"]["deployedBytecode"]["immutableReferences"].values():
    for r in refs:
        a[r["start"]:r["start"] + r["length"]] = b"\0" * r["length"]
        b[r["start"]:r["start"] + r["length"]] = b"\0" * r["length"]
mlen = int.from_bytes(local[-2:], "big") + 2
print(f"{path}: sources={len(inp['sources'])} local={len(local)}B chain={len(chain)}B")
print(f"  metadata CBOR equal: {local[-mlen:] == chain[-mlen:]}  (metadata ipfs hash in compiler metadata: {json.loads(c['metadata'])['sources'] is not None})")
same = len(a) == len(b) and a == b
if not same and len(a) == len(b):
    diff = [i for i in range(len(a)) if a[i] != b[i]]
    print(f"  differing bytes: {len(diff)} (first at {diff[0]})")
print("  RUNTIME IDENTICAL (immutables masked): " + str(same))
sys.exit(0 if same else 1)
