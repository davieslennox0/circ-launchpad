#!/usr/bin/env python3
"""CIRC-TEST end-to-end run on X Layer (or an anvil fork of it).

Drives the full launch lifecycle with `cast`, one transaction at a time, printing each step's tx hash, OKLink link,
balances before/after and PASS/FAIL, and writing the same log to docs/E2E_RESULTS.md.

Keys are read from the environment only (load /root/circ/.env first) and are never printed or logged:
  DEPLOYER_KEY, KEEPER_KEY, BUYER_KEY. The buyer mints its own Nand, so no other wallet's key is needed.
Addresses: MAIN_WALLET (sweep target), CIRC_PROTOCOL, CIRC_SINK (fee recipients, must differ).
Optional: E2E_RPC (default https://rpc.xlayer.tech), E2E_FORK=1 (anvil fork: blocks mined),
          E2E_PAD (skip deploy and reuse a CIRC-TEST pad), E2E_LOG (log file, default docs/E2E_RESULTS.md).

Safety: refuses to send more than CAP_WEI (0.5 OKB) of msg.value in total across all wallets (gas excluded; sweeps to
MAIN_WALLET excluded), and stops on the first unexpected revert or failed check.
"""
import json
import os
import re
import subprocess
import sys
import time
from decimal import Decimal, getcontext

getcontext().prec = 80

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOG_PATH = os.path.join(ROOT, os.environ.get("E2E_LOG", "docs/E2E_RESULTS.md"))

CAP_WEI = 5 * 10**17  # 0.5 OKB hard cap on msg.value across all wallets
E18 = 10**18

# X Layer mainnet
WOKB = "0xe538905cf8410324e03A5A23C1c177a474D59b2b"
POSM = "0xcF1EAFC6928dC385A342E7C6491d371d2871458b"
PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
STATE_VIEW = "0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990"
QUOTER = "0x8928074CA1b241D8Ec02815881c1Af11E8bC5219"
UR = "0x1cd182C94fcF42277B80DBB9060F88024809E61E"
NANDOUT = "0x8A60B4A4BCf4066F5E5F9A406fE09c5e4f52a58E"
ONE_NAND = "0x00000002000003"  # one NAND gate: NAND(in0, in1), nIn=2, nOut=1
TEST_LOGO = "ipfs://bafkreifgwgniocoza3oetpvyllyxb2tlbnvn7sgywmnbwxcb4tcnkc6qsu"  # the throwaway logo pinned on 2026-11-01
OPENER = "0x536adD8F30f03b69f6fbF29d425A816A0dC50106"
REGISTRY = "0x000000006551c19487814612e58FE06813775758"
CONTAINER_IMPL = "0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57"
POOL_FEE, TICK_SPACING, TICK_MAX = 10000, 200, 887200

MAX_U128 = 2**128 - 1

RPC = os.environ.get("E2E_RPC", "https://rpc.xlayer.tech")
FORK = os.environ.get("E2E_FORK") == "1"
EXPLORER = "https://www.oklink.com/x-layer/tx/"


class Abort(Exception):
    pass


# ---------------------------------------------------------------------------------------------------------- logging

_log_lines = []
RESUME = os.environ.get("E2E_RESUME_FROM", "")  # e.g. "7b": continue a stopped run on the deployed instance
if RESUME and os.path.exists(LOG_PATH):
    _log_lines = open(LOG_PATH).read().rstrip("\n").split("\n")


def out(line=""):
    print(line, flush=True)
    _log_lines.append(line)
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    with open(LOG_PATH, "w") as f:
        f.write("\n".join(_log_lines) + "\n")


def okb(wei):
    return f"{Decimal(wei) / Decimal(E18):.9f}".rstrip("0").rstrip(".") if wei else "0"


def tok(wei):
    return f"{Decimal(wei) / Decimal(E18):,.4f}"


RESULTS = []  # (step, PASS/FAIL, detail)


def check(step, cond, detail):
    status = "PASS" if cond else "FAIL"
    RESULTS.append((step, status, detail))
    out(f"- **{status}** {detail}")
    if not cond:
        raise Abort(f"check failed: {step}: {detail}")


# ------------------------------------------------------------------------------------------------------------- cast

def _arg(x):
    return str(x).lower() if isinstance(x, bool) else str(x)


def _run(args, env=None):
    args = [_arg(a) for a in args]
    p = subprocess.run(["cast", *args], capture_output=True, text=True, env=env)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


TRANSIENT = ("null response", "timed out", "timeout", "connection", "429", "error sending request", "502", "503")


def cast(*args):
    """Read-only cast commands, retried on transient RPC errors."""
    for attempt in range(6):
        rc, so, se = _run([*args])
        if rc == 0:
            return so
        if not any(t in se.lower() for t in TRANSIENT):
            break
        time.sleep(2 + 3 * attempt)
    raise Abort(f"cast {args[0]} failed: {se[-600:]}")


def call(to, sig, *args, frm=None, value=0):
    a = ["call", to, sig, *[_arg(x) for x in args], "--rpc-url", RPC]
    if frm:
        a += ["--from", frm]
    if value:
        a += ["--value", str(value)]
    return [ln.split(" ")[0] for ln in cast(*a).splitlines()]


def call_int(to, sig, *args, **kw):
    return int(call(to, sig, *args, **kw)[0], 0)


def call_reverts(to, sig, *args, frm=None, value=0):
    """Returns the revert data/text if the call reverts, else None."""
    a = ["call", to, sig, *[_arg(x) for x in args], "--rpc-url", RPC]
    if frm:
        a += ["--from", frm]
    if value:
        a += ["--value", str(value)]
    rc, so, se = _run(a)
    return None if rc == 0 else (se + " " + so)


def reverted_with(err, signature):
    """True if a call_reverts() result carries this custom error (as raw selector or decoded name)."""
    return err is not None and (sel(signature)[2:].lower() in err.lower() or signature.split("(")[0] in err)


def deadline():
    return int(cast("block", "latest", "--field", "timestamp", "--rpc-url", RPC)) + 3600


def sel(signature):
    return cast("sig", signature)


def enc(sig, *args):
    return cast("abi-encode", sig, *[_arg(x) for x in args])


def native(addr):
    return int(cast("balance", addr, "--rpc-url", RPC))


def erc20(token, addr):
    return call_int(token, "balanceOf(address)(uint256)", addr)


def block_number():
    return int(cast("block-number", "--rpc-url", RPC))


def gas_price():
    return int(cast("gas-price", "--rpc-url", RPC))


# ----------------------------------------------------------------------------------------------------------- wallets

class Wallet:
    def __init__(self, name, key_env, impersonate=None):
        self.name = name
        self.key = os.environ.get(key_env) if key_env else None
        if impersonate:
            self.addr = impersonate
            self.key = None
        else:
            if not self.key:
                raise Abort(f"{key_env} missing from the environment (.env)")
            self.addr = cast("wallet", "address", "--private-key", self.key)

    def signer_args(self):
        return ["--private-key", self.key] if self.key else ["--unlocked", "--from", self.addr]


SPENT = {"value": 0}
GAS = {}  # phase -> wei
PHASE = {"name": "setup"}


def send(w, to, sig, *args, value=0, sweep=False, label=""):
    """Sends one tx; enforces the spend cap; aborts on revert. Returns the receipt dict."""
    if value and not sweep:
        if SPENT["value"] + value > CAP_WEI:
            raise Abort(f"spend cap: {label} would bring msg.value total to {okb(SPENT['value'] + value)} OKB > 0.5")
    a = ["send", to]
    if sig:
        a += [sig, *[_arg(x) for x in args]]
    a += ["--rpc-url", RPC, "--async", *w.signer_args()]
    if value:
        a += ["--value", str(value)]
    nonce = int(cast("nonce", w.addr, "--rpc-url", RPC))
    rc, so, se = _run(a)
    if rc != 0:
        time.sleep(5)
        if int(cast("nonce", w.addr, "--rpc-url", RPC)) > nonce:
            raise Abort(f"{label or sig}: RPC error after the tx was submitted (nonce {nonce} used); check the "
                        f"explorer for {w.addr} before resuming: {se[-300:]}")
        raise Abort(f"{label or sig}: transaction not sent (simulation reverted or RPC error): {se[-800:]}")
    h = so.strip().splitlines()[-1].strip()
    r = None
    for attempt in range(60):  # up to ~3 minutes
        rc2, so2, _ = _run(["receipt", h, "--json", "--rpc-url", RPC])
        if rc2 == 0 and so2.startswith("{"):
            r = json.loads(so2)
            break
        time.sleep(3)
    if r is None:
        out(f"  - tx `{h}` submitted, receipt not available: {EXPLORER}{h}")
        raise Abort(f"{label or sig}: no receipt after 3 minutes")
    if int(r["status"], 0) != 1:
        out(f"  tx `{h}` {EXPLORER}{h}")
        raise Abort(f"{label or sig}: reverted on chain")
    if value and not sweep:
        SPENT["value"] += value
    fee = int(r["gasUsed"], 0) * int(r.get("effectiveGasPrice", "0x0"), 0) + int(r.get("l1Fee", "0x0") or "0x0", 0)
    GAS[PHASE["name"]] = GAS.get(PHASE["name"], 0) + fee
    out(f"  - tx `{h}` ({label or sig.split('(')[0]}, from {w.name}, value {okb(value)} OKB, gas {int(r['gasUsed'], 0):,})"
        + ("  _(anvil fork, not on chain)_" if FORK else ""))
    out(f"    {EXPLORER}{h}")
    return r


def topic(signature):
    return cast("keccak", signature)


# --------------------------------------------------------------------------------------------------------- balances

def snapshot(wallets, tokens):
    s = {}
    for w in wallets:
        s[(w, "OKB")] = native(w.addr)
        for name, t in tokens:
            s[(w, name)] = erc20(t, w.addr)
    return s


def show_delta(before, after):
    out("  | wallet | asset | before | after | delta |")
    out("  |---|---|---|---|---|")
    for k in before:
        w, a = k
        b, c = before[k], after[k]
        fmt = okb if a in ("OKB", "WOKB") else tok
        d = c - b
        out(f"  | {w.name} | {a} | {fmt(b)} | {fmt(c)} | {'+' if d >= 0 else '-'}{fmt(abs(d))} |")


class Step:
    def __init__(self, title, wallets, tokens):
        self.title, self.wallets, self.tokens = title, wallets, tokens

    def __enter__(self):
        out()
        out(f"### {self.title}")
        self.before = snapshot(self.wallets, self.tokens) if self.wallets else {}
        return self

    def __exit__(self, et, ev, tb):
        if self.wallets:
            show_delta(self.before, snapshot(self.wallets, self.tokens))
        return False

    def d(self, w, asset):
        return snapshot([w], [t for t in self.tokens if t[0] == asset])[(w, asset)] - self.before[(w, asset)]


# ------------------------------------------------------------------------------------------------------------ helpers

def tx_logs(r, address=None, t0=None):
    for lg in r["logs"]:
        if address and lg["address"].lower() != address.lower():
            continue
        if t0 and lg["topics"][0].lower() != t0.lower():
            continue
        yield lg


def words(data):
    d = data[2:]
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]


def addr_of_topic(t):
    return "0x" + t[-40:]


def curve(pad, token):
    v = call(pad, "curves(address)(address,uint128,uint128,uint128,uint128,address,address,uint256,uint64,uint8)", token)
    return {"quote": v[0], "vQuote": int(v[1]), "vToken": int(v[2]), "realQuote": int(v[3]), "tokensLeft": int(v[4]),
            "container": v[5], "launchBlock": int(v[8]), "status": int(v[9])}


def accrued(vault, asset, who):
    return call_int(vault, "accrued(address,address)(uint256)", asset, who)


def wait_blocks_until(target):
    if FORK:
        n = target - block_number()
        if n > 0:
            cast("rpc", "anvil_mine", hex(n), "--rpc-url", RPC)
        return
    while block_number() < target:
        time.sleep(2)


def pool_key(token, hook):
    c0, c1 = sorted([token, WOKB], key=lambda a: int(a, 16))
    return c0, c1, f"({c0},{c1},{POOL_FEE},{TICK_SPACING},{hook})"


def quote_exact_in(key_t, zero_for_one, amount):
    sig = "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))(uint256,uint256)"
    return int(call(QUOTER, sig, f"({key_t},{str(zero_for_one).lower()},{amount},0x)")[0])


def ensure_allowances(w, token, spender_amount):
    """token -> Permit2 (max), Permit2 -> Universal Router (amount, 1h)."""
    if call_int(token, "allowance(address,address)(uint256)", w.addr, PERMIT2) < spender_amount:
        send(w, token, "approve(address,uint256)", PERMIT2, 2**256 - 1, label="approve Permit2")
    exp = deadline()
    send(w, PERMIT2, "approve(address,address,uint160,uint48)", token, UR, spender_amount, exp,
         label="Permit2 approve Universal Router")


def ur_swap(w, key, token_in, token_out, amount, slippage_bps=100):
    c0, c1, key_t = key
    zfo = token_in.lower() == c0.lower()
    q = quote_exact_in(key_t, zfo, amount)
    min_out = q * (10000 - slippage_bps) // 10000
    ensure_allowances(w, token_in, amount)
    p0 = enc("f(((address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes))",
             f"({key_t},{str(zfo).lower()},{amount},{min_out},0,0x)")
    p1 = enc("f(address,uint256)", token_in, amount)
    p2 = enc("f(address,uint256)", token_out, min_out)
    inp = enc("f(bytes,bytes[])", "0x060c0f", f"[{p0},{p1},{p2}]")
    r = send(w, UR, "execute(bytes,bytes[],uint256)", "0x10", f"[{inp}]", deadline(),
             label=f"Universal Router V4_SWAP exact-in {tok(amount) if token_in != WOKB else okb(amount)}")
    return r, q, min_out


def split_expect(amount):
    c = amount * 5000 // 10000
    s = amount * 2000 // 10000
    return c, amount - c - s, s  # container, protocol, sink


def tick_sqrt(t):
    return Decimal("1.0001") ** (Decimal(t) / 2)


# ---------------------------------------------------------------------------------------------------------------- main

def main():
    if not RESUME:
        out("# CIRC-TEST end-to-end results")
        out()
    else:
        out()
        out(f"## Resumed from step {RESUME} ({time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}) on the same CIRC-TEST instance")

    chain = int(cast("chain-id", "--rpc-url", RPC))
    out(f"- network: X Layer chain id {chain}{' (**anvil fork rehearsal**, nothing on chain)' if FORK else ' (mainnet)'}")
    out(f"- started: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}, block {block_number()}")
    out(f"- spend cap: {okb(CAP_WEI)} OKB msg.value across all wallets (gas excluded)")
    if chain != 196:
        raise Abort("not X Layer (196)")

    deployer = Wallet("deployer", "DEPLOYER_KEY")
    keeper = Wallet("keeper", "KEEPER_KEY")
    buyer = Wallet("buyer", "BUYER_KEY")
    holder = buyer  # the test wallet mints and holds its own Nand: the real new-user path
    main_wallet = os.environ.get("MAIN_WALLET", "")
    protocol = os.environ.get("CIRC_PROTOCOL", "")
    sink = os.environ.get("CIRC_SINK", "")
    for n, a in (("MAIN_WALLET", main_wallet), ("CIRC_PROTOCOL", protocol), ("CIRC_SINK", sink)):
        if not re.fullmatch(r"0x[0-9a-fA-F]{40}", a):
            raise Abort(f"{n} missing or malformed in .env")
    circuit_id = int(os.environ.get("E2E_CIRCUIT_ID", "0"))  # set only when resuming; otherwise minted in step 2
    if RESUME and not circuit_id:
        raise Abort("resuming needs E2E_CIRCUIT_ID")
    if os.environ.get("TEST_RAISE_WEI"):
        raise Abort("TEST_RAISE_WEI is set: the spend plan and funding assume the default test curve")
    out(f"- sweep target MAIN_WALLET: {main_wallet}; test wallet: {buyer.addr}")
    ours = [deployer, keeper, buyer]

    if not RESUME or RESUME == "0":
        # ------------------------------------------------------------------ 0. preflight
        PHASE["name"] = "preflight"
        with Step("0. Preflight", [deployer, keeper, buyer, holder], []):
            addrs = {w.addr.lower() for w in ours}
            check("preflight", len(addrs) == 3, "deployer, keeper and buyer are three distinct addresses")
            check("preflight", protocol.lower() != sink.lower(), "CIRC_PROTOCOL and CIRC_SINK differ (needed for the split check)")
            opened = False  # a freshly minted Nand's Container is never open
            open_fee = call_int(OPENER, "FEE()(uint256)")
            gp = gas_price()
            t_addr = call(NANDOUT, "transistors()(address)")[0]
            mint_cost = call_int(t_addr, "mintPrice()(uint256)") + call_int(t_addr, "protocolFee()(uint256)") + call_int(NANDOUT, "TAPEOUT_FEE()(uint256)")
            out(f"  - new Nand costs {okb(mint_cost)} OKB; Container open fee {okb(open_fee)} OKB; gas price {gp / 1e9:.4f} gwei")
            # Cost estimate (gas from the anvil-fork rehearsal).
            deploy_gas, e2e_gas = 8_600_000, 4_500_000
            out(f"  - estimate: TEST deploy {okb(deploy_gas * gp)} OKB gas; e2e run {okb(e2e_gas * gp)} OKB gas "
                f"+ ~0.19 OKB value (fill ~0.1, Nand {okb(mint_cost)}, Container open {okb(open_fee)}, withdraw fee 0.0013); "
                f"prod deploy {okb(deploy_gas * gp)} OKB gas")
            # The keeper only needs gas. The buyer pays the fill, the Nand, the Container open and the withdraw fee.
            for w, need in ((deployer, 3 * 10**15), (keeper, 10**15), (buyer, 108 * 10**15 + mint_cost + open_fee + 2 * 10**15)):
                check("preflight", native(w.addr) >= need, f"{w.name} {w.addr} holds >= {okb(need)} OKB")

        # ------------------------------------------------------------------ 1. deploy
        PHASE["name"] = "deploy"
        pad = os.environ.get("E2E_PAD")
        with Step("1. Deploy CIRC-TEST (script/Deploy.s.sol:DeployTest)", [deployer], []):
            if pad:
                out(f"  reusing E2E_PAD {pad}")
            else:
                    # Deploy only the CI-built artifact: a silent recompile here could produce different bytes.
                v = subprocess.run(["forge", "--version"], capture_output=True, text=True).stdout
                if "1.7.1" not in v:
                    raise Abort(f"forge must be 1.7.1, the version CI builds with: {v.splitlines()[0] if v else 'not found'}")
                if not FORK:
                    b = subprocess.run(["forge", "build", "--skip", "test"], cwd=ROOT, capture_output=True, text=True)
                    if "No files changed" not in b.stdout + b.stderr:
                        raise Abort("out/ and cache/ aren't the CI artifact for this commit; refusing to recompile and deploy different bytes")
                env = dict(os.environ, PRIVATE_KEY=deployer.key, CIRC_PROTOCOL=protocol, CIRC_SINK=sink)
                p = subprocess.run(["forge", "script", "script/Deploy.s.sol:DeployTest", "--rpc-url", RPC, "--broadcast",
                                    "--slow", "-vv"], cwd=ROOT, capture_output=True, text=True, env=env)
                text = p.stdout + p.stderr
                if p.returncode != 0:
                    raise Abort("forge script DeployTest failed:\n" + text[-1500:])
                m = re.findall(r"CurvePad +(0x[0-9a-fA-F]{40})", text)
                pad = m[-1]
                bj = os.path.join(ROOT, "broadcast", "Deploy.s.sol", str(chain), "run-latest.json")
                b = json.load(open(bj))
                for rc in b["receipts"]:
                    h = rc["transactionHash"]
                    fee = int(rc["gasUsed"], 0) * int(rc.get("effectiveGasPrice", "0x0"), 0)
                    GAS["deploy"] = GAS.get("deploy", 0) + fee
                    out(f"  - tx `{h}` (deploy, gas {int(rc['gasUsed'], 0):,})" + ("  _(anvil fork)_" if FORK else ""))
                    out(f"    {EXPLORER}{h}")
                for ln in text.splitlines():
                    if re.search(r"TEST_|LABEL|PositionLocker|CurvePad|CircHook|Graduator|TokenDeployer|protocol|sink", ln):
                        out("    " + ln.strip())
            locker = call(pad, "locker()(address)")[0]
            hook = call(pad, "hook()(address)")[0]
            graduator = call(pad, "graduator()(address)")[0]
            vq0 = int(call(pad, "quoteConfig(address)((uint128,uint128,uint128,uint128))", WOKB)[0].strip("("). rstrip(","))
            check("deploy", int(hook, 16) & 0x3FFF == 0x2800 and not hook.lower().startswith("0x91"),
                  f"CircHook {hook} has exactly beforeInitialize|beforeAddLiquidity flags")
            check("deploy", call(locker, "pad()(address)")[0].lower() == pad.lower(), f"PositionLocker {locker} is bound to CurvePad {pad}")
            check("deploy", call(pad, "protocol()(address)")[0].lower() == protocol.lower()
                  and call(pad, "sink()(address)")[0].lower() == sink.lower(), "protocol and sink are your addresses")
            raise_wei = vq0 * 805950034987136158382022685 // (1061538461538461538461538462 - 805950034987136158382022685)
            check("deploy", raise_wei <= 2 * 10**17, f"TEST WOKB vQuote0 {vq0} -> raise {okb(raise_wei)} WOKB (tiny TEST curve)")

        toks = [("WOKB", WOKB)]

        # ------------------------------------------------------------------ 2. launch
        PHASE["name"] = "e2e"
        with Step("2a. Mint a new Nand (buy 1 NAND transistor, tape out)", [buyer], []):
            last = call_int(NANDOUT, "nextId()(uint256)")
            send(buyer, t_addr, "mint(uint256,uint256)", 0, 1, value=mint_cost - call_int(NANDOUT, "TAPEOUT_FEE()(uint256)"), label="buy NAND transistor")
            r = send(buyer, NANDOUT, "tapeout(bytes,uint32,uint32)", ONE_NAND, 2, 1, value=call_int(NANDOUT, "TAPEOUT_FEE()(uint256)"), label="tape out")
            lg = next(tx_logs(r, NANDOUT, topic("TapedOut(uint256,address,uint32,uint32)")))
            circuit_id = int(lg["topics"][1], 16)
            check("mint", circuit_id == last + 1, f"nextId() was the last id ({last}); the new Nand is #{circuit_id}")
            check("mint", call(NANDOUT, "ownerOf(uint256)(address)", circuit_id)[0].lower() == buyer.addr.lower(), "the buyer holds it")
        sig = "createLaunch(address,uint256,string,string,string,address,uint256,uint256)"
        with Step("2b. Launch limits (simulated, nothing sent)", [], []):
            err = call_reverts(pad, sig, NANDOUT, circuit_id, "", "X", "", WOKB, 0, 0, frm=holder.addr)
            check("limits", reverted_with(err, "BadName()"), "empty name reverts BadName")
            err = call_reverts(pad, sig, NANDOUT, circuit_id, "x" * 65, "X", "", WOKB, 0, 0, frm=holder.addr)
            check("limits", reverted_with(err, "BadName()"), "65-byte name reverts BadName")
            err = call_reverts(pad, sig, NANDOUT, circuit_id, "X", "x" * 17, "", WOKB, 0, 0, frm=holder.addr)
            check("limits", reverted_with(err, "BadSymbol()"), "17-byte symbol reverts BadSymbol")
            bps = call_int(pad, "tradeFeeBps()(uint256)")
            split = [int(x) for x in call(pad, "feeSplitBps()(uint256,uint256,uint256)")]
            check("views", bps == 100 and split == [5000, 3000, 2000], f"tradeFeeBps {bps}, feeSplitBps {split}")
        with Step(f"2c. Launch CIRC-TEST from Nand #{circuit_id}", [holder], toks):
            check("launch", call(pad, "isLaunched(address,uint256)(bool)", NANDOUT, circuit_id)[0] == "false", "isLaunched is false before")
            r = send(holder, pad, sig, NANDOUT, circuit_id, "CIRC-TEST", "CIRCTEST", TEST_LOGO, WOKB, 0, 0, label="createLaunch")
            check("launch", call(pad, "isLaunched(address,uint256)(bool)", NANDOUT, circuit_id)[0] == "true", "isLaunched is true after")
            err = call_reverts(pad, sig, NANDOUT, circuit_id, "Again", "AGAIN", "", WOKB, 0, 0, frm=holder.addr)
            check("launch", reverted_with(err, "AlreadyLaunched()"), "a second launch from this Nand reverts AlreadyLaunched")
            t_launch = topic("LaunchCreated(address,address,address,uint256,address,address,string)")
            lg = next(tx_logs(r, pad, t_launch))
            check("launch", TEST_LOGO.encode().hex() in lg["data"], "imageURI is emitted in LaunchCreated")
            token = addr_of_topic(lg["topics"][1])
            c = curve(pad, token)
            container = c["container"]
            out(f"  - token **{token}**, Container {container}, launch block {c['launchBlock']}")
            check("launch", c["status"] == 0 and c["quote"].lower() == WOKB.lower(), "curve is Trading, quoted in WOKB")
            check("launch", erc20(token, pad) == 10**27, "pad holds the full 1,000,000,000 supply")
        toks = [("WOKB", WOKB), ("CIRCTEST", token)]
        key = pool_key(token, hook)

        fees = []  # per-trade curve fees (WOKB) from Trade events, for the split check

        def record_fee(r):
            t_trade = topic("Trade(address,address,bool,uint256,uint256,uint256,uint256,uint256)")
            for lg in tx_logs(r, pad, t_trade):
                fees.append(words(lg["data"])[3])

        # ------------------------------------------------------------------ 3. anti-snipe
        with Step("3. Anti-snipe: buy inside the 30-block guard is capped at 0.5% of supply", [buyer], toks) as st:
            cap = call_int(pad, "MAX_EARLY_BUY()(uint256)")
            now = block_number()
            guard_end = c["launchBlock"] + 30
            if now + 2 >= guard_end:
                RESULTS.append(("anti-snipe", "SKIPPED", "guard window passed before the buy could land"))
                out("- **SKIPPED** guard window already over (covered by unit tests)")
            else:
                v = 10**15  # 0.001 OKB buys far more than 5M tokens at the TEST price; the cap trims it, excess refunded
                r = send(buyer, pad, "buyWithOKB(address,uint256,uint256)", token, 0, deadline(),
                         value=v, label="buyWithOKB inside guard")
                record_fee(r)
                got = st.d(buyer, "CIRCTEST")
                blk = int(r["blockNumber"], 0)
                check("anti-snipe", blk < guard_end, f"buy landed in block {blk}, inside the guard (ends {guard_end})")
                check("anti-snipe", got == cap, f"tokens received {tok(got)} == cap {tok(cap)} (0.5% of supply)")
                eb = call(pad, "earlyBlock(address)(uint64,uint192)", token)
                check("anti-snipe", int(eb[1]) == cap, "curve-wide per-block counter recorded the capped amount")
                spent_net = -st.d(buyer, "OKB")
                check("anti-snipe", spent_net < v, f"excess refunded: net OKB out {okb(spent_net)} < sent {okb(v)} (incl. gas)")

        # ------------------------------------------------------------------ 4. buys / sells after the guard
        wait_blocks_until(c["launchBlock"] + 31)
        with Step("4a. Buy 0.01 OKB after the guard", [buyer], toks) as st:
            v = 10**16
            exp_out, _ = (int(x) for x in call(pad, "previewBuy(address,uint256)(uint256,uint256)", token, v))
            r = send(buyer, pad, "buyWithOKB(address,uint256,uint256)", token, exp_out * 99 // 100,
                     deadline(), value=v, label="buyWithOKB 0.01")
            record_fee(r)
            check("buy", st.d(buyer, "CIRCTEST") == exp_out, f"received {tok(exp_out)} CIRCTEST == previewBuy")
        with Step("4b. Sell half the buyer's tokens back to the curve", [buyer], toks) as st:
            bal = erc20(token, buyer.addr)
            amt = bal // 2
            exp_q = call_int(pad, "previewSell(address,uint256)(uint256)", token, amt)
            send(buyer, token, "approve(address,uint256)", pad, amt, label="approve pad")
            r = send(buyer, pad, "sell(address,uint256,uint256,uint256)", token, amt, exp_q * 99 // 100,
                     deadline(), label="sell")
            record_fee(r)
            check("sell", st.d(buyer, "WOKB") == exp_q, f"received {okb(exp_q)} WOKB == previewSell")
            check("sell", st.d(buyer, "CIRCTEST") == -amt, f"sent {tok(amt)} CIRCTEST")

        # ------------------------------------------------------------------ 5. fill
        with Step("5. Fill the curve -> Complete", [buyer], toks):
            _, need = (int(x) for x in call(pad, "previewBuy(address,uint256)(uint256,uint256)", token, MAX_U128))
            out(f"  - quote needed to complete: {okb(need)} WOKB")
            r = send(buyer, pad, "buyWithOKB(address,uint256,uint256)", token, 0,
                     deadline(), value=need + 10**12, label="buyWithOKB fill")
            record_fee(r)
            c = curve(pad, token)
            t_done = topic("CurveCompleted(address)")
            check("fill", c["status"] == 1 and any(True for _ in tx_logs(r, pad, t_done)),
                  "curve status Complete, CurveCompleted emitted")
            check("fill", c["tokensLeft"] == 0, "curve supply sold out")
            err = call_reverts(pad, "buyWithOKB(address,uint256,uint256)", token, 0, 2**40, frm=buyer.addr, value=10**12)
            check("fill", reverted_with(err, "CurveClosed()"), "further curve buys revert CurveClosed")

        with Step("5b. Curve fee split 50/30/20 (CurvePad FeeVault)", [], []):
            total = call_int(pad, "totalAccrued(address)(uint256)", WOKB)
            acc = {k: accrued(pad, WOKB, a) for k, a in (("container", container), ("protocol", protocol), ("sink", sink))}
            all_fees = fees
            check("split", total == sum(fees), f"FeeVault total {okb(total)} WOKB == sum of {len(fees)} Trade-event fees")
            exp = [0, 0, 0]
            for f in all_fees:
                e = split_expect(f)
                exp = [exp[i] + e[i] for i in range(3)]
            out(f"  - fees: {', '.join(okb(f) for f in all_fees)} WOKB (total {okb(total)})")
            check("split", acc["container"] == exp[0], f"Container {okb(acc['container'])} = 50%")
            check("split", acc["protocol"] == exp[1], f"protocol {okb(acc['protocol'])} = 30% (+rounding)")
            check("split", acc["sink"] == exp[2], f"sink {okb(acc['sink'])} = 20%")
            check("split", sum(acc.values()) == total, "shares sum to the total fee")

        # ------------------------------------------------------------------ 6. graduate
        with Step("6. Keeper graduates (permissionless)", [keeper], toks):
            pre_proto = accrued(pad, WOKB, protocol)
            r = send(keeper, pad, "graduate(address)", token, label="graduate")
            t_grad = topic("Graduated(address,bytes32,uint256,uint256,uint256)")
            lg = next(tx_logs(r, pad, t_grad))
            pool_id = lg["topics"][2]
            position_id, raised, lp_used = words(lg["data"])
            out(f"  - poolId {pool_id}, position #{position_id}, quote in LP {okb(raised)} WOKB, tokens in LP {tok(lp_used)}")
            check("graduate", curve(pad, token)["status"] == 2, "curve status Graduated")
            check("graduate", call(POSM, "ownerOf(uint256)(address)", position_id)[0].lower() == locker.lower(),
                  "position NFT owned by PositionLocker")
            check("graduate", call(locker, "containerOf(uint256)(address)", position_id)[0].lower() == container.lower(),
                  "locker records the launch's Container")
            check("graduate", call(hook, "isOpen(bytes32)(bool)", pool_id)[0] == "true", "hook reports the pool open")
            check("graduate", erc20(WOKB, graduator) == 0 and erc20(token, graduator) == 0, "Graduator holds nothing")
            cc = curve(pad, token)
            sqrtp = int(call(STATE_VIEW, "getSlot0(bytes32)(uint160,int24,uint24,uint24)", pool_id)[0])
            tok_is0 = int(token, 16) < int(WOKB, 16)
            exp_x192 = (cc["vQuote"] << 192) // cc["vToken"] if tok_is0 else (cc["vToken"] << 192) // cc["vQuote"]
            got = sqrtp * sqrtp
            check("graduate", abs(got - exp_x192) * 1000 <= exp_x192, "pool opened at the curve's final price (within 0.1%)")
            liq = int(call(POSM, "getPositionLiquidity(uint256)(uint128)", position_id)[0])
            check("graduate", int(call(STATE_VIEW, "getLiquidity(bytes32)(uint128)", pool_id)[0]) == liq,
                  f"pool liquidity == locked position liquidity ({liq:,})")
            out(f"  - graduation dust booked to protocol: {okb(accrued(pad, WOKB, protocol) - pre_proto)} WOKB")
            err = call_reverts(pad, "graduate(address)", token, frm=keeper.addr)
            check("graduate", reverted_with(err, "AlreadyGraduated()"), "second graduate reverts AlreadyGraduated")

        # ------------------------------------------------------------------ 7. Universal Router swaps
        with Step("7a. Universal Router 2.1.2: buy with WOKB", [buyer], toks) as st:
            amt = min(2 * 10**15, erc20(WOKB, buyer.addr))
            r, q, mn = ur_swap(buyer, key, WOKB, token, amt)
            check("UR buy", st.d(buyer, "WOKB") == -amt and st.d(buyer, "CIRCTEST") >= mn,
                  f"paid {okb(amt)} WOKB, got {tok(st.d(buyer, 'CIRCTEST'))} CIRCTEST (quoted {tok(q)})")
    elif RESUME == "7b":
        PHASE["name"] = "e2e"
        pad, token, position_id = os.environ["E2E_PAD"], os.environ["E2E_TOKEN"], int(os.environ["E2E_POSITION_ID"])
        locker = call(pad, "locker()(address)")[0]
        hook = call(pad, "hook()(address)")[0]
        graduator = call(pad, "graduator()(address)")[0]
        container = curve(pad, token)["container"]
        check("resume", curve(pad, token)["status"] == 2, f"CIRC-TEST token {token} is Graduated on pad {pad}")
        check("resume", call(POSM, "ownerOf(uint256)(address)", position_id)[0].lower() == locker.lower(),
              f"position #{position_id} is locked")
        toks = [("WOKB", WOKB), ("CIRCTEST", token)]
        key = pool_key(token, hook)
        pool_id = cast("keccak", enc("f((address,address,uint24,int24,address))", key[2]))
        liq = int(call(POSM, "getPositionLiquidity(uint256)(uint128)", position_id)[0])
        # msg.value already spent in the stopped run counts against the cap
        SPENT["value"] = sum(int(Decimal(m) * E18) for m in re.findall(r"value ([0-9.]+) OKB, gas", "\n".join(_log_lines)))
        out(f"- msg.value already spent before the stop: {okb(SPENT['value'])} OKB (counted against the 0.5 cap)")
    else:
        raise Abort(f"unsupported E2E_RESUME_FROM={RESUME}")
    with Step("7b. Universal Router 2.1.2: sell 10% of the buyer's tokens", [buyer], toks) as st:
        amt = erc20(token, buyer.addr) // 10
        r, q, mn = ur_swap(buyer, key, token, WOKB, amt)
        check("UR sell", st.d(buyer, "CIRCTEST") == -amt and st.d(buyer, "WOKB") >= mn,
              f"sold {tok(amt)} CIRCTEST for {okb(st.d(buyer, 'WOKB'))} WOKB (quoted {okb(q)})")

    # ------------------------------------------------------------------ 8. collect + split
    with Step("8. Locker collect (permissionless) + LP fee split 50/30/20", [keeper], []):
        c0, c1, _ = key
        pre = {(a, k): accrued(locker, a, who) for a in (c0, c1)
               for k, who in (("container", container), ("protocol", protocol), ("sink", sink))}
        r = send(keeper, locker, "collect(uint256)", position_id, label="collect")
        t_col = topic("Collected(uint256,uint256,uint256)")
        a0, a1 = words(next(tx_logs(r, locker, t_col))["data"])
        out(f"  - collected {a0} (currency0 {c0}) and {a1} (currency1 {c1}) wei")
        check("collect", a0 > 0 and a1 > 0, "fees collected in both currencies (one UR buy, one UR sell)")
        for a, amt in ((c0, a0), (c1, a1)):
            e = split_expect(amt)
            got = [accrued(locker, a, who) - pre[(a, k)] for k, who in
                   (("container", container), ("protocol", protocol), ("sink", sink))]
            name = "WOKB" if a.lower() == WOKB.lower() else "CIRCTEST"
            check("collect split", got == list(e), f"{name}: Container {got[0]} / protocol {got[1]} / sink {got[2]} = 50/30/20")
        lid = position_id
        liq_after = int(call(POSM, "getPositionLiquidity(uint256)(uint128)", lid)[0])
        check("collect", liq_after == liq, "locked liquidity unchanged by collect")

    # ------------------------------------------------------------------ 9. protocol / sink claims
    with Step("9. Protocol and sink claims (permissionless push to your addresses)", [], []):
        for vault, vname in ((pad, "CurvePad"), (locker, "PositionLocker")):
            for who, wname in ((protocol, "protocol"), (sink, "sink")):
                amt = accrued(vault, WOKB, who)
                if amt == 0:
                    continue
                b = erc20(WOKB, who)
                send(keeper, vault, "claim(address,address)", WOKB, who, label=f"{vname}.claim WOKB -> {wname}")
                check("claim", erc20(WOKB, who) - b == amt, f"{wname} received {okb(amt)} WOKB from {vname}")
        err = call_reverts(pad, "claim(address,address)", WOKB, container, frm=keeper.addr)
        check("claim", reverted_with(err, "CreatorClaimOnly()"),
              "claim() cannot push creator fees (CreatorClaimOnly)")
        err = call_reverts(pad, "claimCreator(address,address,bool)", container, WOKB, True, frm=keeper.addr)
        check("claim", reverted_with(err, "NotHolder()"), "non-holder claimCreator reverts NotHolder")

    # ------------------------------------------------------------------ 10. Container open + withdraw
    with Step("10. Container open + creator claim to Container + holder withdraw", [holder], toks):
        if len(cast("code", container, "--rpc-url", RPC)) <= 2:
            open_fee = call_int(OPENER, "FEE()(uint256)")
            send(holder, OPENER, "open(address,uint256)", NANDOUT, circuit_id, value=open_fee,
                 label=f"TapeOut opener.open (fee {okb(open_fee)} OKB)")
            check("container", len(cast("code", container, "--rpc-url", RPC)) > 2, f"Container {container} deployed")
        else:
            out("  - Container already opened")
        amt = accrued(pad, WOKB, container)
        cb = erc20(WOKB, container)
        send(holder, pad, "claimCreator(address,address,bool)", container, WOKB, False, label="claimCreator -> Container")
        check("container", erc20(WOKB, container) - cb == amt and accrued(pad, WOKB, container) == 0,
              f"Container received {okb(amt)} WOKB creator fees")
        # Withdraw through the Container (TapeOut charges a per-execute fee; read it from the revert)
        xfer = cast("calldata", "transfer(address,uint256)", holder.addr, amt)
        err = call_reverts(container, "execute(address,uint256,bytes,uint8)", WOKB, 0, xfer, 0, frm=holder.addr) or ""
        m = re.search(r"afd49700([0-9a-fA-F]{64})([0-9a-fA-F]{64})", err)
        exec_fee = int(m.group(2), 16) if m else 13 * 10**14
        out(f"  - Container execute fee: {okb(exec_fee)} OKB")
        hb = erc20(WOKB, holder.addr)
        send(holder, container, "execute(address,uint256,bytes,uint8)", WOKB, 0, xfer, 0, value=exec_fee,
             label="Container.execute withdraw")
        check("container", erc20(WOKB, holder.addr) - hb == amt, f"holder withdrew {okb(amt)} WOKB from the Container")

    # ------------------------------------------------------------------ 11. fallback holder claim
    with Step("11. Fallback: holder claims LP creator fees straight to the holder wallet", [holder], toks):
        for a, name in ((WOKB, "WOKB"), (token, "CIRCTEST")):
            amt = accrued(locker, a, container)
            b = erc20(a, holder.addr)
            send(holder, locker, "claimCreator(address,address,bool)", container, a, True,
                 label=f"locker.claimCreator {name} -> holder")
            check("fallback", erc20(a, holder.addr) - b == amt and accrued(locker, a, container) == 0,
                  f"holder wallet received {okb(amt) if a == WOKB else tok(amt)} {name}")

    # ------------------------------------------------------------------ 12. cleanup
    PHASE["name"] = "cleanup"
    with Step("12. Cleanup: sell all CIRCTEST back into the pool, unwrap, sweep the buyer to MAIN_WALLET",
              [buyer], toks):
        for w in (buyer,):
            bal = erc20(token, w.addr)
            if bal > 0 and quote_exact_in(key[2], token.lower() == key[0].lower(), bal) > 0:
                ur_swap(w, key, token, WOKB, bal, slippage_bps=300)
                check("cleanup", erc20(token, w.addr) == 0, f"{w.name} holds no CIRCTEST")
        # The keeper is also the production keeper, so it is left alone.
        for w in (buyer,):
            wb = erc20(WOKB, w.addr)
            if wb:
                send(w, WOKB, "withdraw(uint256)", wb, label="unwrap WOKB")
        gp = gas_price()
        for w in (buyer,):
            margin = 10**12
            for _ in range(4):
                bal = native(w.addr)
                v = bal - 21000 * gp - margin
                if v <= 0:
                    break
                try:
                    send(w, main_wallet, None, value=v, sweep=True, label=f"sweep {okb(v)} OKB -> MAIN_WALLET")
                    break
                except Abort as e:
                    if "insufficient" not in str(e).lower():
                        raise
                    margin *= 10
            left = native(w.addr)
            out(f"  - {w.name} left with {okb(left)} OKB")
            if left > 10**15:
                raise Abort(f"sweep failed: {w.name} still holds {okb(left)} OKB")

    # ------------------------------------------------------------------ 13. locked LP report
    with Step("13. Locked LP (stays forever by design)", [], []):
        sqrtp = int(call(STATE_VIEW, "getSlot0(bytes32)(uint160,int24,uint24,uint24)", pool_id)[0])
        L = Decimal(int(call(POSM, "getPositionLiquidity(uint256)(uint128)", position_id)[0]))
        sp = Decimal(sqrtp) / Decimal(2**96)
        sa, sb = tick_sqrt(-TICK_MAX), tick_sqrt(TICK_MAX)
        amt0 = L * (sb - sp) / (sp * sb)
        amt1 = L * (sp - sa)
        tok_is0 = int(token, 16) < int(WOKB, 16)
        okb_locked, tok_locked = (amt1, amt0) if tok_is0 else (amt0, amt1)
        out(f"- locked position #{position_id}: ~{okb(int(okb_locked))} OKB (as WOKB) + ~{tok(int(tok_locked))} CIRCTEST")
        RESULTS.append(("locked LP", "INFO", f"{okb(int(okb_locked))} OKB locked in position #{position_id}"))

    # ------------------------------------------------------------------ summary
    out()
    out("## Summary")
    out()
    out(f"- CurvePad (CIRC-TEST): `{pad}`; PositionLocker `{locker}`; CircHook `{hook}`; Graduator `{graduator}`")
    out(f"- token `{token}`; pool `{pool_id}`; locked position #{position_id}")
    out(f"- msg.value spent (cap 0.5 OKB): {okb(SPENT['value'])} OKB")
    # Gas actually paid, from every receipt in the log (covers resumed runs); phase by step heading.
    gas, phase = {}, "e2e"
    for ln in list(_log_lines):
        if ln.startswith("### "):
            phase = "deploy" if ln.startswith("### 1.") else "cleanup" if ln.startswith("### 12.") else "e2e"
        m = re.match(r"\s+- tx `(0x[0-9a-f]{64})`", ln)
        if m:
            rc = json.loads(cast("receipt", m.group(1), "--json", "--rpc-url", RPC))
            fee = int(rc["gasUsed"], 0) * int(rc.get("effectiveGasPrice", "0x0"), 0)
            gas[phase] = gas.get(phase, 0) + fee
    for ph, w in gas.items():
        out(f"- gas paid, {ph}: {okb(w)} OKB")
    out(f"- gas paid, total: {okb(sum(gas.values()))} OKB")
    out(f"- prod deploy estimate: ~{okb(gas.get('deploy', 8_600_000 * gas_price()))} OKB gas (same contracts)")
    text = "\n".join(_log_lines)
    out(f"- checks: {text.count('**PASS**')} PASS, {text.count('**FAIL**')} FAIL, {text.count('**SKIPPED**')} SKIPPED")
    out()
    out("E2E RESULT: PASS")


if __name__ == "__main__":
    try:
        main()
    except (Abort, StopIteration) as e:
        out()
        out(f"**STOPPED: {e}**")
        out()
        out("E2E RESULT: FAIL")
        sys.exit(1)
