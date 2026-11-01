#!/usr/bin/env python3
"""Circ keeper: graduates every Complete curve on a CurvePad. Permissionless and idempotent.

Watches CurveCompleted(token) logs, confirms the curve is still Complete, and sends graduate(token).
A failed or reverted attempt is retried on the next pass; graduate() leaves the curve unchanged when it reverts.

Reads use plain JSON-RPC (stdlib only, ~15 MB RSS). Only sends go through `cast`. Env (from an EnvironmentFile):
  KEEPER_KEYSTORE      encrypted keystore file (the key is never on a command line, where `ps` could show it)
  KEEPER_PASSWORD_FILE file holding the keystore password
  CIRC_PAD             CurvePad address
  START_BLOCK          first block to scan (the pad's deploy block)
  RPC_URL              primary RPC; may hold an access token, so it is never logged or put on a command line
  RPC_FALLBACK_URL     comma-separated, used when the primary fails or refuses old blocks (default: both official public RPCs)
  STATE_FILE           default /var/lib/circ-keeper/state.json
  POLL_SECONDS         default 5
  MIN_BALANCE_WEI      warn below this keeper balance (default 0.002 OKB)
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

PUBLIC_RPCS = "https://xlayerrpc.okx.com,https://rpc.xlayer.tech"
RPC = os.environ.get("RPC_URL", PUBLIC_RPCS.split(",")[0])
RPCS = list(dict.fromkeys([RPC, *os.environ.get("RPC_FALLBACK_URL", PUBLIC_RPCS).split(",")]))
PAD = os.environ.get("CIRC_PAD", "").lower()
STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/circ-keeper/state.json")
POLL = int(os.environ.get("POLL_SECONDS", "5"))
MIN_BAL = int(os.environ.get("MIN_BALANCE_WEI", str(2 * 10**15)))
CHUNK = 100  # X Layer public RPC caps eth_getLogs at 100 blocks
CONFIRMATIONS = 2

TOPIC_COMPLETED = "0xa0a0c0fe2202393c1af7f6919ecd56c835ac1395aa519b430721ea8135e51acc"  # CurveCompleted(address)
SEL_CURVES = "0x2cc3dc6e"  # curves(address)


def signer_args():
    return ["--keystore", os.environ["KEEPER_KEYSTORE"], "--password-file", os.environ["KEEPER_PASSWORD_FILE"]]


def keeper_address():
    return subprocess.run(["cast", "wallet", "address", *signer_args()], capture_output=True, text=True, check=True).stdout.strip()


def redact(text):
    for i, url in enumerate(RPCS):
        text = str(text).replace(url, f"<rpc{i}>")
    return text


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + redact(msg), flush=True)


_id = 0


def rpc_at(url, method, params):
    global _id
    _id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        res = json.load(r)
    if "error" in res:
        raise RuntimeError(f"{method}: {res['error']}")
    if res.get("result") is None:
        raise RuntimeError(f"{method}: null result")
    return res["result"]


def rpc(method, params):
    """Tries the primary, then the fallback. The primary's plan may refuse old blocks, which only matters after downtime."""
    err = None
    for url in RPCS:
        try:
            return rpc_at(url, method, params)
        except Exception as e:  # network, HTTP or JSON-RPC error
            err = e
    raise RuntimeError(redact(err))


def status(token):
    """Curve status: 0 Trading, 1 Complete, 2 Graduated."""
    data = SEL_CURVES + token[2:].rjust(64, "0")
    out = rpc("eth_call", [{"to": PAD, "data": data}, "latest"])
    return int(out[2 + 64 * 9: 2 + 64 * 10], 16)


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"next_block": int(os.environ.get("START_BLOCK", "0")), "pending": []}


def save_state(s):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, STATE_FILE)


def graduate(token):
    p = None
    for url in RPCS:  # the URL goes in the environment, never on the command line where `ps` could show it
        p = subprocess.run(["cast", "send", PAD, "graduate(address)", token, "--async", *signer_args()],
                           capture_output=True, text=True, env=dict(os.environ, ETH_RPC_URL=url))
        if p.returncode == 0:
            break
    if p.returncode != 0:
        log(f"graduate {token}: not sent: {p.stderr.strip()[-300:]}")
        return False
    h = p.stdout.strip().splitlines()[-1]
    log(f"graduate {token}: sent {h}")
    for _ in range(40):
        time.sleep(3)
        try:
            r = rpc("eth_getTransactionReceipt", [h])
        except RuntimeError:
            continue
        ok = int(r["status"], 16) == 1
        log(f"graduate {token}: {'OK' if ok else 'REVERTED'} block {int(r['blockNumber'], 16)} "
            f"https://www.oklink.com/x-layer/tx/{h}")
        return ok
    log(f"graduate {token}: no receipt yet for {h}; will re-check status")
    return False


def tick(s):
    """One pass: pick up new CurveCompleted logs, then graduate whatever is still Complete."""
    head = int(rpc("eth_blockNumber", []), 16) - CONFIRMATIONS
    while s["next_block"] <= head:
        to = min(head, s["next_block"] + CHUNK - 1)
        logs = rpc("eth_getLogs", [{"address": PAD, "topics": [TOPIC_COMPLETED],
                                    "fromBlock": hex(s["next_block"]), "toBlock": hex(to)}])
        for lg in logs:
            t = "0x" + lg["topics"][1][-40:]
            if t not in s["pending"]:
                s["pending"].append(t)
                log(f"CurveCompleted {t} (block {int(lg['blockNumber'], 16)})")
        s["next_block"] = to + 1
        save_state(s)
    for t in list(s["pending"]):
        st = status(t)
        if st == 1:
            graduate(t)
            st = status(t)
        if st == 2:
            s["pending"].remove(t)
            log(f"{t} graduated")
            save_state(s)


def main():
    keeper = keeper_address()
    log(f"circ keeper up: pad {PAD}, keeper {keeper}, {len(RPCS)} rpc endpoint(s)")
    s = load_state()
    last_warn = 0
    while True:
        try:
            tick(s)
            if time.time() - last_warn > 3600:
                bal = int(rpc("eth_getBalance", [keeper, "latest"]), 16)
                if bal < MIN_BAL:
                    log(f"WARNING keeper balance {bal / 1e18:.6f} OKB is below {MIN_BAL / 1e18:.4f}; top up {keeper}")
                last_warn = time.time()
        except Exception as e:  # RPC hiccups: log and keep going
            log(f"loop error: {e}")
        time.sleep(POLL)


if __name__ == "__main__":
    sys.exit(main())
