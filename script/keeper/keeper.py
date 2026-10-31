#!/usr/bin/env python3
"""Circ keeper: graduates every Complete curve on a CurvePad. Permissionless and idempotent.

Watches CurveCompleted(token) logs, confirms the curve is still Complete, and sends graduate(token) from KEEPER_KEY.
A failed or reverted attempt is retried on the next pass; graduate() leaves the curve unchanged when it reverts.

Reads use plain JSON-RPC (stdlib only, ~15 MB RSS). Only sends go through `cast`, so the key never touches this
process's logs. Env (from an EnvironmentFile, never printed):
  KEEPER_KEY      keeper private key
  CIRC_PAD        CurvePad address
  START_BLOCK     first block to scan (the pad's deploy block)
  RPC_URL         default https://rpc.xlayer.tech
  STATE_FILE      default /var/lib/circ-keeper/state.json
  POLL_SECONDS    default 5
  MIN_BALANCE_WEI warn below this keeper balance (default 0.002 OKB)
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

RPC = os.environ.get("RPC_URL", "https://rpc.xlayer.tech")
PAD = os.environ["CIRC_PAD"].lower()
KEY = os.environ["KEEPER_KEY"]
STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/circ-keeper/state.json")
POLL = int(os.environ.get("POLL_SECONDS", "5"))
MIN_BAL = int(os.environ.get("MIN_BALANCE_WEI", str(2 * 10**15)))
CHUNK = 100  # X Layer public RPC caps eth_getLogs at 100 blocks
CONFIRMATIONS = 2

TOPIC_COMPLETED = "0x" + subprocess.run(["cast", "keccak", "CurveCompleted(address)"], capture_output=True,
                                        text=True, check=True).stdout.strip()[2:]
SEL_CURVES = "0x" + subprocess.run(["cast", "sig", "curves(address)"], capture_output=True,
                                   text=True, check=True).stdout.strip()[2:]
KEEPER = subprocess.run(["cast", "wallet", "address", "--private-key", KEY], capture_output=True, text=True,
                        check=True).stdout.strip()


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg, flush=True)


_id = 0


def rpc(method, params):
    global _id
    _id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        res = json.load(r)
    if "error" in res:
        raise RuntimeError(f"{method}: {res['error']}")
    if res.get("result") is None:
        raise RuntimeError(f"{method}: null result")
    return res["result"]


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
    p = subprocess.run(["cast", "send", PAD, "graduate(address)", token, "--rpc-url", RPC, "--async",
                        "--private-key", KEY], capture_output=True, text=True)
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


def main():
    log(f"circ keeper up: pad {PAD}, keeper {KEEPER}, rpc {RPC}")
    s = load_state()
    last_warn = 0
    while True:
        try:
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
            if time.time() - last_warn > 3600:
                bal = int(rpc("eth_getBalance", [KEEPER, "latest"]), 16)
                if bal < MIN_BAL:
                    log(f"WARNING keeper balance {bal / 1e18:.6f} OKB is below {MIN_BAL / 1e18:.4f}; top up {KEEPER}")
                last_warn = time.time()
        except Exception as e:  # RPC hiccups: log and keep going
            log(f"loop error: {e}")
        time.sleep(POLL)


if __name__ == "__main__":
    sys.exit(main())
