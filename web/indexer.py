#!/usr/bin/env python3
"""Keyless public indexer for the Circ frontend.

The X Layer public RPC caps eth_getLogs at 100 blocks, so a browser cannot cheaply discover launches from the deploy
block. This process scans CurvePad logs (LaunchCreated, Trade, CurveCompleted, Graduated) and writes a small public
JSON file per instance. It holds no keys and sends no transactions. The site treats it only as a hint: every number it
shows is re-read from the chain, and it scans forward from `scannedTo` itself.

Env: OUT_DIR (default /srv/circ-web/data), RPC_URL, POLL_SECONDS. Instances are fixed below.
"""
import json
import os
import time
import urllib.request

RPC = os.environ.get("RPC_URL", "https://rpc.xlayer.tech")
OUT = os.environ.get("OUT_DIR", "/srv/circ-web/data")
POLL = int(os.environ.get("POLL_SECONDS", "4"))
CHUNK = 100
KEEP_TRADES = 150

# v2 = CurvePad with imageURI in LaunchCreated (SPEC A9); v1 = original ABI (CIRC-TEST only).
INSTANCES = {
    "prod": {"pad": "0x071a1ff737415Ddc2085629D80B7C68741e17A18", "start": 74725398, "abi": 2},
    "test": {"pad": "0xa66D7020a374BCC3e6424B9075E481617C669057", "start": 74714250, "abi": 1},
}

# keccak256 of the CurvePad event signatures (cast keccak; see src/CurvePad.sol)
TOPICS = {
    "launch": "0x61374329b2b4e0725b47012a0ca5901e642624565fbbe811e930b8e1c09758a7",
    "launch2": "0x5ad9b4b4e9363f6d4e2023053eabdc5dc7ff9b01d448dd79dd874bf5b82f9ebe",
    "trade": "0x2c76e7a47fd53e2854856ac3f0a5f3ee40d15cfaa82266357ea9779c486ab9c3",
    "completed": "0xa0a0c0fe2202393c1af7f6919ecd56c835ac1395aa519b430721ea8135e51acc",
    "graduated": "0xdf9e4d7e38c0b4f9b2b0c31c082370dd912b89a99ebaf6129c106a6b81253f67",
}


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        res = json.load(r)
    if "error" in res or res.get("result") is None:
        raise RuntimeError(f"{method}: {res.get('error')}")
    return res["result"]


def words(data):
    d = data[2:]
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]


def addr(t):
    return "0x" + t[-40:]


_ts = {}


def block_ts(n):
    if n not in _ts:
        _ts[n] = int(rpc("eth_getBlockByNumber", [hex(n), False])["timestamp"], 16)
        if len(_ts) > 5000:
            _ts.clear()
    return _ts[n]


def load(name):
    try:
        with open(os.path.join(OUT, f"index-{name}.json")) as f:
            s = json.load(f)
        if s.get("pad", "").lower() == INSTANCES[name]["pad"].lower():
            return s  # same pad: resume; a repointed instance starts fresh below
    except (OSError, ValueError):
        inst = INSTANCES[name]
        return {"pad": inst["pad"], "startBlock": inst["start"], "scannedTo": inst["start"] - 1, "launches": {}}


def save(name, s):
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, f"index-{name}.json")
    with open(p + ".tmp", "w") as f:
        json.dump(s, f, separators=(",", ":"))
    os.replace(p + ".tmp", p)


def image_uri(data):
    """Decode the trailing `string imageURI` of a v2 LaunchCreated. Returned raw; the site validates and escapes it."""
    try:
        d = bytes.fromhex(data[2:])
        off = int.from_bytes(d[96:128], "big")
        ln = int.from_bytes(d[off:off + 32], "big")
        if ln > 256:
            return ""
        return d[off + 32:off + 32 + ln].decode("utf-8", "replace")
    except Exception:
        return ""


def apply(s, lg):
    t0 = lg["topics"][0]
    n = int(lg["blockNumber"], 16)
    if t0 in (TOPICS["launch"], TOPICS["launch2"]):
        token = addr(lg["topics"][1])
        w = words(lg["data"])
        s["launches"][token] = {
            "token": token, "quote": addr(lg["topics"][2]), "circuitNft": addr(lg["topics"][3]),
            "circuitId": w[0], "container": "0x" + hex(w[1])[2:].rjust(40, "0"),
            "creator": "0x" + hex(w[2])[2:].rjust(40, "0"), "block": n, "ts": block_ts(n),
            "tx": lg["transactionHash"], "trades": [], "graduated": None,
            "imageURI": image_uri(lg["data"]) if t0 == TOPICS["launch2"] else "",
        }
    else:
        token = addr(lg["topics"][1])
        L = s["launches"].get(token)
        if L is None:
            return
        if t0 == TOPICS["trade"]:
            w = words(lg["data"])
            L["trades"].append({"b": n, "ts": block_ts(n), "tx": lg["transactionHash"], "who": addr(lg["topics"][2]),
                                "buy": w[0] == 1, "q": str(w[1]), "t": str(w[2]), "fee": str(w[3])})
            L["trades"] = L["trades"][-KEEP_TRADES:]
        elif t0 == TOPICS["graduated"]:
            w = words(lg["data"])
            L["graduated"] = {"poolId": lg["topics"][2], "positionId": w[0], "block": n, "tx": lg["transactionHash"]}


def step(name, s):
    head = int(rpc("eth_blockNumber", []), 16) - 1
    launch = TOPICS["launch2"] if INSTANCES[name]["abi"] == 2 else TOPICS["launch"]
    topics = [[launch, TOPICS["trade"], TOPICS["completed"], TOPICS["graduated"]]]
    while s["scannedTo"] < head:
        fr = s["scannedTo"] + 1
        to = min(head, fr + CHUNK - 1)
        logs = rpc("eth_getLogs", [{"address": s["pad"], "topics": topics, "fromBlock": hex(fr), "toBlock": hex(to)}])
        for lg in sorted(logs, key=lambda x: (int(x["blockNumber"], 16), int(x["logIndex"], 16))):
            apply(s, lg)
        s["scannedTo"] = to
        s["updated"] = int(time.time())
        if to == head or (to - s["startBlock"]) % 2000 < CHUNK:
            save(name, s)


def main():
    states = {n: load(n) for n in INSTANCES}
    print(f"circ indexer up: {', '.join(f'{n}={v['pad']}' for n, v in INSTANCES.items())}", flush=True)
    while True:
        for n, s in states.items():
            try:
                step(n, s)
                save(n, s)
            except Exception as e:
                print(f"{n}: {e}", flush=True)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
