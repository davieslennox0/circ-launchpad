#!/usr/bin/env python3
"""Keyless public indexer for the Circ frontend.

The X Layer public RPC caps eth_getLogs at 100 blocks, so a browser cannot cheaply discover launches from the deploy
block. This process scans CurvePad logs (LaunchCreated, Trade, CurveCompleted, Graduated) and, after tape-out, the Uniswap v4
Swap logs of each pool, and writes a small public JSON file per instance. `prices` holds [timestamp, quote per token] for
the site's 5M / 30M / 1H / 24H changes. It holds no keys and sends no transactions. The site treats it only as a hint: every number it
shows is re-read from the chain, and it scans forward from `scannedTo` itself.

Env: OUT_DIR (default /srv/circ-web/data), RPC_URL, RPC_FALLBACK_URL (comma-separated), POLL_SECONDS. Instances are fixed below.
RPC_URL may hold an access token, so it is never logged. The fallback (default: public RPC) covers outages and old blocks,
which a private plan may refuse. The website doesn't use these: visitors' browsers talk to the public RPC themselves.
"""
import json
import os
import time
import urllib.request

PUBLIC_RPCS = "https://xlayerrpc.okx.com,https://rpc.xlayer.tech"
RPCS = list(dict.fromkeys([os.environ.get("RPC_URL", PUBLIC_RPCS.split(",")[0]), *os.environ.get("RPC_FALLBACK_URL", PUBLIC_RPCS).split(",")]))
OUT = os.environ.get("OUT_DIR", "/srv/circ-web/data")
POLL = int(os.environ.get("POLL_SECONDS", "4"))
CHUNK = 100
KEEP_TRADES = 150
KEEP_PRICE_SECONDS = 86400  # the longest change window
KEEP_PRICES = 3000
INDEX_VERSION = 2  # 2 added `prices`: an older file is scanned again from the start
POOL_MANAGER = "0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32"
TOPIC_SWAP = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"  # Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)
SEL_QUOTE_CONFIG = "0x9cd57cad"  # quoteConfig(address)
BEM = "0x60e62efa9405d6873c5deabd4e6cc91c25363952"  # 8 decimals; WOKB has 18

# abi 2 = LaunchCreated with imageURI (SPEC A9). prod is production v3; test is the v3 CIRC-TEST instance.
INSTANCES = {
    "prod": {"pad": "0x4b9eb3Ee0a25FFE62e159080f392551a99493cC7", "start": 74785331, "abi": 2},
    "test": {"pad": "0x8f2bbd9dA778071a8B6E9C2D3fEC3f3a6850E6BA", "start": 74783260, "abi": 2},
}

# keccak256 of the CurvePad event signatures (cast keccak; see src/CurvePad.sol)
TOPICS = {
    "launch": "0x61374329b2b4e0725b47012a0ca5901e642624565fbbe811e930b8e1c09758a7",
    "launch2": "0x5ad9b4b4e9363f6d4e2023053eabdc5dc7ff9b01d448dd79dd874bf5b82f9ebe",
    "trade": "0x2c76e7a47fd53e2854856ac3f0a5f3ee40d15cfaa82266357ea9779c486ab9c3",
    "completed": "0xa0a0c0fe2202393c1af7f6919ecd56c835ac1395aa519b430721ea8135e51acc",
    "graduated": "0xdf9e4d7e38c0b4f9b2b0c31c082370dd912b89a99ebaf6129c106a6b81253f67",
}


def redact(text):
    for i, url in enumerate(RPCS):
        text = str(text).replace(url, f"<rpc{i}>")
    return text


def rpc_at(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        res = json.load(r)
    if "error" in res or res.get("result") is None:
        raise RuntimeError(f"{method}: {res.get('error')}")
    return res["result"]


def rpc(method, params):
    err = None
    for url in RPCS:
        try:
            return rpc_at(url, method, params)
        except Exception as e:  # network, HTTP or JSON-RPC error: try the next endpoint
            err = e
    raise RuntimeError(redact(err))


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


def migrate(s):
    """Keeps what's there and scans again from the start, to fill in `prices`."""
    s["v"] = INDEX_VERSION
    s["scannedTo"] = s["startBlock"] - 1
    s.pop("poolScannedTo", None)
    for L in s["launches"].values():
        L["prices"], L["lastPt"], L["startPt"] = [], None, False


def add_point(L, n, i, ts, price, now=None):
    """Appends a price once. Scans only move forward, and a repeated window is skipped by (block, logIndex)."""
    if L.get("lastPt") and [n, i] <= L["lastPt"]:
        return
    L["lastPt"] = [n, i]
    pts = L.setdefault("prices", [])
    pts.append([ts, price])
    cutoff = (now if now is not None else time.time()) - KEEP_PRICE_SECONDS
    while len(pts) > 1 and pts[1][0] <= cutoff:  # keep one point older than the window, as its anchor
        pts.pop(0)
    del pts[:-KEEP_PRICES]


def quote_decimals(quote):
    return 8 if quote.lower() == BEM else 18


def curve_price(v_quote, v_token, quote):
    return (v_quote / 10 ** quote_decimals(quote)) / (v_token / 1e18)


def pool_price(sqrt_price_x96, token, quote):
    """Quote per token. v4 sorts a pool's currencies by address, and sqrtPrice is currency1 per currency0."""
    raw = (sqrt_price_x96 / 2 ** 96) ** 2
    if int(token, 16) > int(quote, 16):
        raw = 1 / raw
    return raw * 10 ** (18 - quote_decimals(quote))


_cfg = {}


def add_start_points(s):
    """The launch price anchors a token younger than the window. It isn't in any log, so it comes from quoteConfig."""
    for L in s["launches"].values():
        if L.get("startPt"):
            continue
        key = (s["pad"], L["quote"])
        if key not in _cfg:
            _cfg[key] = words(rpc("eth_call", [{"to": s["pad"], "data": SEL_QUOTE_CONFIG + L["quote"][2:].rjust(64, "0")}, "latest"]))
        L.setdefault("prices", []).insert(0, [L["ts"], curve_price(_cfg[key][0], _cfg[key][1], L["quote"])])
        L["startPt"] = True


def scan_pools(s):
    """Prices after tape-out: Swap logs of every graduated pool, up to where the pad scan has reached."""
    pools = {L["graduated"]["poolId"]: L for L in s["launches"].values() if L.get("graduated")}
    if not pools:
        s["poolScannedTo"] = s["scannedTo"]
        return
    if "poolScannedTo" not in s:
        s["poolScannedTo"] = min(L["graduated"]["block"] for L in pools.values()) - 1
    while s["poolScannedTo"] < s["scannedTo"]:
        fr = s["poolScannedTo"] + 1
        to = min(s["scannedTo"], fr + CHUNK - 1)
        logs = rpc("eth_getLogs", [{"address": POOL_MANAGER, "topics": [TOPIC_SWAP, list(pools)], "fromBlock": hex(fr), "toBlock": hex(to)}])
        for lg in sorted(logs, key=lambda x: (int(x["blockNumber"], 16), int(x["logIndex"], 16))):
            L = pools.get(lg["topics"][1])
            if L:
                n = int(lg["blockNumber"], 16)
                add_point(L, n, int(lg["logIndex"], 16), block_ts(n), pool_price(words(lg["data"])[2], L["token"], L["quote"]))
        s["poolScannedTo"] = to


def load(name):
    inst = INSTANCES[name]
    try:
        with open(os.path.join(OUT, f"index-{name}.json")) as f:
            s = json.load(f)
        if s.get("pad", "").lower() == inst["pad"].lower():
            if s.get("v") != INDEX_VERSION:
                migrate(s)
            return s  # same pad: resume
    except (OSError, ValueError):
        pass
    return {"v": INDEX_VERSION, "pad": inst["pad"], "startBlock": inst["start"], "scannedTo": inst["start"] - 1, "launches": {}}  # new or repointed


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
    """Applies one log. Idempotent: a window that failed halfway (e.g. a 429 on block_ts) is simply scanned again."""
    t0 = lg["topics"][0]
    n = int(lg["blockNumber"], 16)
    if t0 in (TOPICS["launch"], TOPICS["launch2"]):
        token = addr(lg["topics"][1])
        if token in s["launches"]:
            return
        w = words(lg["data"])
        s["launches"][token] = {
            "token": token, "quote": addr(lg["topics"][2]), "circuitNft": addr(lg["topics"][3]),
            "circuitId": w[0], "container": "0x" + hex(w[1])[2:].rjust(40, "0"),
            "creator": "0x" + hex(w[2])[2:].rjust(40, "0"), "block": n, "ts": block_ts(n),
            "tx": lg["transactionHash"], "trades": [], "graduated": None, "prices": [],
            "imageURI": image_uri(lg["data"]) if t0 == TOPICS["launch2"] else "",
        }
    else:
        token = addr(lg["topics"][1])
        L = s["launches"].get(token)
        if L is None:
            return
        if t0 == TOPICS["trade"]:
            i = int(lg["logIndex"], 16)
            v = words(lg["data"])
            if len(v) >= 6 and v[5]:  # the Trade event carries the reserves after the trade
                add_point(L, n, i, block_ts(n), curve_price(v[4], v[5], L["quote"]))
            if any(t["tx"] == lg["transactionHash"] and t.get("i") == i for t in L["trades"]):
                return
            w = words(lg["data"])
            L["trades"].append({"b": n, "i": i, "ts": block_ts(n), "tx": lg["transactionHash"], "who": addr(lg["topics"][2]),
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
        add_start_points(s)
        s["scannedTo"] = to
        s["updated"] = int(time.time())
        if to == head or (to - s["startBlock"]) % 2000 < CHUNK:
            save(name, s)
    add_start_points(s)
    scan_pools(s)


def main():
    states = {n: load(n) for n in INSTANCES}
    print(f"circ indexer up: {', '.join(f'{n}={v['pad']}' for n, v in INSTANCES.items())}", flush=True)
    while True:
        for n, s in states.items():
            try:
                step(n, s)
                save(n, s)
            except Exception as e:
                print(f"{n}: {redact(e)}", flush=True)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
