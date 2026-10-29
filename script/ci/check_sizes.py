"""Fail if any deployable contract breaks EIP-170 (runtime > 24,576 B) or EIP-3860 (initcode > 49,152 B).
Input: the JSON from `forge build --sizes --json`. Prints a table either way."""
import json
import sys

RUNTIME_LIMIT, INIT_LIMIT = 24_576, 49_152
raw = open(sys.argv[1]).read()
data = json.loads(raw[raw.index("{"):])  # tolerate any leading log lines
if not isinstance(data, dict) or not data:
    sys.exit(f"unexpected sizes JSON: {raw[:500]}")

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
