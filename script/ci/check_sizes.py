"""Fail if any deployable contract breaks EIP-170 (runtime > 24,576 B) or EIP-3860 (initcode > 49,152 B).
Input: the JSON from `forge build --sizes --json`. Prints a table either way."""
import json
import os
import re
import sys

RUNTIME_LIMIT, INIT_LIMIT = 24_576, 49_152
raw = open(sys.argv[1]).read()
try:
    data = json.loads(raw[raw.index("{"):])  # tolerate any leading log lines
except ValueError:
    data = None
if not isinstance(data, dict) or not data or not all(isinstance(v, dict) for v in data.values()):
    sys.exit(f"forge build did not produce a size table (compile error?):\n{raw[:3000]}")

# The build includes scripts and test helpers (never deployed); the limits apply to contracts defined in src/.
src_names = set()
for dirpath, _, files in os.walk(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "src")):
    for f in files:
        src_names |= set(re.findall(r"^(?:abstract )?contract (\w+)", open(os.path.join(dirpath, f)).read(), re.M))
data = {k: v for k, v in data.items() if k in src_names}
if "CurvePad" not in data:
    sys.exit("CurvePad is missing from the size table")

bad = []
print(f"{'contract':<28}{'runtime':>10}{'margin':>10}{'initcode':>10}{'margin':>10}")
for name, v in sorted(data.items()):
    rt, init = int(v["runtime_size"]), int(v["init_size"])
    print(f"{name:<28}{rt:>10}{RUNTIME_LIMIT - rt:>10}{init:>10}{INIT_LIMIT - init:>10}")
    if rt > RUNTIME_LIMIT or init > INIT_LIMIT:
        bad.append(name)
if bad:
    sys.exit(f"over the EIP-170 / EIP-3860 limit: {', '.join(bad)}")
print("all contracts within EIP-170 and EIP-3860 limits")
