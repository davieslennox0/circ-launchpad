/* Circ Launchpad by Sarf: static front end. No backend keys, no private keys.
 * Every curve number (constants, progress, targets, prices) is read live from the chain.
 * /data/index-*.json (keyless indexer) is only a list of launch addresses and recent trades; it is re-checked on chain
 * and the page scans forward past its head itself. Transactions are built only when the user presses a button and are
 * signed in the user's own wallet. */
"use strict";
const E = ethers;
const { kingOfTheHill, floorStage, filterLaunches, sortBy, chartLine, priceChange, formatChange, esc, short, initials, safeImage: safeImageCore, nandIds, nextNandId, previewCurveBuy, guardBlocksLeft, recommendDirect, parseContainerRevert,
  uncollectedFee, encodeSwap, devHolding, okxWalletLink, isMobile, byteLength } = CircCore;

const CHAIN_ID = 196;
const RPC = "https://rpc.xlayer.tech";
const RPCS = ["https://xlayerrpc.okx.com", RPC]; // both official public RPCs; retries move to the other one
const EXPLORER = "https://www.oklink.com/x-layer";
const INSTANCES = {
  prod: { pad: "0x4b9eb3Ee0a25FFE62e159080f392551a99493cC7" },     // production v3
  test: { pad: "0x8f2bbd9dA778071a8B6E9C2D3fEC3f3a6850E6BA" },   // v3 test instance, used only by the staging copy (config.js)
};
const PIN_ENDPOINT = "https://circ-launchpad-pin.vercel.app/api/pin"; // Vercel Function; the Pinata key lives only there
const IPFS_GATEWAYS = ["https://ipfs.filebase.io/ipfs/", "https://dweb.link/ipfs/"]; // tried in order, then initials
const A = {
  USDT0_WOKB_POOL: "0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082",
  BEM_WOKB_POOL: "0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A",
  OPENER: "0x536adD8F30f03b69f6fbF29d425A816A0dC50106",
  UR: "0x1cd182C94fcF42277B80DBB9060F88024809E61E",
  PERMIT2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  QUOTER: "0x8928074CA1b241D8Ec02815881c1Af11E8bC5219",
  MULTICALL3: "0xcA11bde05977b3631167028862bE2a173976CA11",
  STATE_VIEW: "0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990",
  NANDOUT: "0x8A60B4A4BCf4066F5E5F9A406fE09c5e4f52a58E",
};

const ABI = {
  pad: [
    "function wokb() view returns (address)", "function bem() view returns (address)",
    "function locker() view returns (address)", "function hook() view returns (address)",
    "function protocol() view returns (address)", "function sink() view returns (address)",
    "function registry() view returns (address)", "function containerImpl() view returns (address)",
    "function circuitFactory() view returns (address)", "function graduator() view returns (address)",
    "function GUARD_BLOCKS() view returns (uint256)", "function MAX_EARLY_BUY() view returns (uint256)",
    "function TOTAL_SUPPLY() view returns (uint256)",
    "function tradeFeeBps() pure returns (uint256)", "function feeSplitBps() pure returns (uint256,uint256,uint256)",
    "function MAX_NAME_BYTES() view returns (uint256)", "function MAX_SYMBOL_BYTES() view returns (uint256)",
    "error BadName()", "error BadSymbol()", "error ImageURITooLong()", "error AlreadyLaunched()", "error NotHolder()", "error Slippage()", "error EarlyBlockCapReached()", "error CurveClosed()",
    "function quoteConfig(address) view returns (tuple(uint128 vQuote0,uint128 vToken0,uint128 curveSupply,uint128 lpTokens))",
    "function curves(address) view returns (address quote,uint128 vQuote,uint128 vToken,uint128 realQuote,uint128 tokensLeft,address container,address circuitNft,uint256 circuitId,uint64 launchBlock,uint8 status)",
    "function earlyBlock(address) view returns (uint64 blockNumber,uint192 sold)",
    "function previewBuy(address,uint256) view returns (uint256 tokensOut,uint256 quoteUsed)",
    "function previewSell(address,uint256) view returns (uint256)",
    "function accrued(address,address) view returns (uint256)",
    "function createLaunch(address,uint256,string,string,string,address,uint256,uint256) payable returns (address)",
    "function isLaunched(address,uint256) view returns (bool)",
    "function buyWithOKB(address,uint256,uint256) payable returns (uint256)",
    "function buy(address,uint256,uint256,uint256) returns (uint256)",
    "function sell(address,uint256,uint256,uint256) returns (uint256)",
    "function graduate(address)",
    "function claimCreator(address,address,bool)",
    "event LaunchCreated(address indexed token,address indexed quote,address indexed circuitNft,uint256 circuitId,address container,address creator,string imageURI)",
  ],
  locker: ["function accrued(address,address) view returns (uint256)", "function claimCreator(address,address,bool)",
    "function positionManager() view returns (address)", "function collect(uint256)"],
  ur: ["function execute(bytes,bytes[],uint256) payable"],
  permit2: ["function approve(address,address,uint160,uint48)", "function allowance(address,address,address) view returns (uint160,uint48,uint48)"],
  quoter: ["function quoteExactInputSingle(tuple(tuple(address,address,uint24,int24,address),bool,uint128,bytes)) returns (uint256,uint256)"],
  erc20: [
    "function name() view returns (string)", "function symbol() view returns (string)",
    "function decimals() view returns (uint8)", "function balanceOf(address) view returns (uint256)",
    "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)",
    "function totalSupply() view returns (uint256)",
  ],
  nft: ["function ownerOf(uint256) view returns (address)", "function name() view returns (string)"],
  registry: ["function account(address,bytes32,uint256,address,uint256) view returns (address)"],
  factory: ["function isCPU(address) view returns (bool)"],
  opener: ["function FEE() view returns (uint256)", "function open(address,uint256) payable"],
  pool: ["function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)", "function token0() view returns (address)"],
  graduator: ["function poolKey(address,address) view returns (tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks))",
    "function TICK_LOWER() view returns (int24)", "function TICK_UPPER() view returns (int24)"],
  stateView: ["function getSlot0(bytes32) view returns (uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)",
    "function getFeeGrowthInside(bytes32,int24,int24) view returns (uint256,uint256)",
    "function getPositionInfo(bytes32,address,int24,int24,bytes32) view returns (uint128,uint256,uint256)"],
  nandout: ["function transistors() view returns (address)", "function nextId() view returns (uint256)",
    "function TAPEOUT_FEE() view returns (uint256)", "function ownerOf(uint256) view returns (address)",
    "function tapeout(bytes,uint32,uint32) payable returns (uint256)",
    "event TapedOut(uint256 indexed circuitId, address indexed author, uint32 gateCount, uint32 nState)"],
  transistors: ["function mintPrice() view returns (uint256)", "function protocolFee() view returns (uint256)",
    "function supplyCap() view returns (uint256)", "function minted() view returns (uint256)",
    "function balanceOf(address,uint256) view returns (uint256)", "function mint(uint256,uint256) payable"],
  multicall: ["function aggregate3(tuple(address target,bool allowFailure,bytes callData)[] calls) view returns (tuple(bool success,bytes returnData)[])"],
  container: ["function execute(address,uint256,bytes,uint8) payable returns (bytes)"],
};

// The public RPC allows about 7 requests a second per visitor, and its 429s carry no CORS header, so a browser sees them as
// network failures. Those are retried with a short backoff; contract reverts come back in the reply and aren't retried.
// Public endpoints are rate limited, and a 429 reaches the browser as a CORS error. So: few requests at once,
// a short timeout instead of ethers' five minutes, and each retry goes to the other endpoint.
const RPC_TIMEOUT_MS = 8000, RPC_MAX_INFLIGHT = 4;
let rpcInflight = 0;
const rpcWaiting = [];
class RetryProvider extends E.JsonRpcProvider {
  async _send(payload) {
    if (rpcInflight >= RPC_MAX_INFLIGHT) await new Promise((r) => rpcWaiting.push(r));
    rpcInflight++;
    try {
      for (let i = 0; ; i++) {
        try {
          const r = await fetch(RPCS[i % RPCS.length], { method: "POST", headers: { "content-type": "application/json" },
            body: JSON.stringify(payload), signal: AbortSignal.timeout(RPC_TIMEOUT_MS) });
          if (!r.ok) throw new Error(`RPC HTTP ${r.status}`);
          const j = await r.json();
          return Array.isArray(j) ? j : [j];
        } catch (e) {
          if (i >= 3) throw new Error("The X Layer network isn't responding right now.");
          await new Promise((r) => setTimeout(r, 300 * 2 ** i));
        }
      }
    } finally {
      rpcInflight--;
      rpcWaiting.shift()?.();
    }
  }
}
const rp = new RetryProvider(RPC, CHAIN_ID, { staticNetwork: true, batchMaxCount: 1 });
const C = (addr, abi, runner = rp) => new E.Contract(addr, abi, runner);
const $ = (s, el = document) => el.querySelector(s);
const STATUS = ["Trading", "Complete", "Taped out"];
const STATUS_CLS = ["trading", "complete", "grad"];

const CFG = window.CIRC_CONFIG || {}; // config.js; a staging copy sets { staging: true }: TEST pad only, launching allowed
const state = {
  inst: CFG.staging ? "test" : "prod", // fixed per site: there is no switch between instances
  account: null, signer: null,
  pad: null,       // on-chain pad facts
  prices: null,    // {okbUsd, bemUsd}
  launches: [],    // [{token, ...curve}]
  head: 0,
};


// ---------------------------------------------------------------- formatting
function num(x, d = 2) {
  if (!isFinite(x)) return "–";
  const a = Math.abs(x);
  if (a >= 1e9) return (x / 1e9).toFixed(d) + "B";
  if (a >= 1e6) return (x / 1e6).toFixed(d) + "M";
  if (a >= 1e3) return (x / 1e3).toFixed(1) + "k";
  if (a >= 1) return x.toLocaleString("en-US", { maximumFractionDigits: d });
  if (a === 0) return "0";
  return x.toPrecision(3);
}
const usd = (x) => isFinite(x) ? "$" + num(x, x >= 1e6 ? 2 : 1) : "–";
const units = (v, dec) => Number(E.formatUnits(v, dec));
function ago(ts) {
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 60) return Math.floor(s) + "s";
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h";
  return Math.floor(s / 86400) + "d";
}
function hue(addr) { // stable avatar colour from the token address, drawn from muted Sarf tones
  const pal = ["#2A2B2E", "#3A3D42", "#3F4F45", "#54472F", "#454A52", "#533A37"];
  return pal[parseInt(addr.slice(2, 6), 16) % pal.length];
}
function toast(msg, ms = 4200) {
  const t = document.createElement("div");
  t.className = "toast"; t.textContent = msg; document.body.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

// ---------------------------------------------------------------- chain reads
async function priceE18(pool, base) { // human price of `base` in the pool's other token, 1e18 fixed point (as LivePrices.sol)
  const p = new E.Contract(pool, [...ABI.pool, "function token1() view returns (address)"], rp);
  const [[sqrtP], t0, t1] = await Promise.all([p.slot0(), p.token0(), p.token1()]);
  const [dec0, dec1] = await Promise.all([C(t0, ABI.erc20).decimals(), C(t1, ABI.erc20).decimals()]);
  const d0 = 10n ** BigInt(dec0), d1 = 10n ** BigInt(dec1), Q128 = 1n << 128n;
  const ratioX128 = (sqrtP * sqrtP) >> 64n; // raw token1 per raw token0, Q128
  return t0.toLowerCase() === base.toLowerCase()
    ? (ratioX128 * d0 * 10n ** 18n) / (Q128 * d1)
    : (Q128 * d1 * 10n ** 18n) / (ratioX128 * d0);
}

async function loadPad() {
  const inst = INSTANCES[state.inst];
  const pad = C(inst.pad, ABI.pad);
  // One request per batch instead of twenty, so a page load doesn't run into the public RPC's rate limit.
  const padI = new E.Interface(ABI.pad);
  const read = async (calls) => (await multicall(calls.map(([fn, args = []]) => [inst.pad, padI, fn, args])))
    .map((v) => (v && v.length === 1 ? v[0] : v));
  const facts = await read([["wokb"], ["bem"], ["locker"], ["hook"], ["protocol"], ["sink"], ["registry"], ["containerImpl"],
    ["circuitFactory"], ["GUARD_BLOCKS"], ["MAX_EARLY_BUY"], ["TOTAL_SUPPLY"], ["graduator"]]);
  if (facts.some((v) => v === null)) throw new Error("CurvePad couldn't be read.");
  const [wokb, bem, locker, hook, protocol, sink, registry, containerImpl, factory, guard, maxEarly, total, graduator] = facts;
  const [cw, cb, fee, spl, nameMax, symMax] = await read([["quoteConfig", [wokb]], ["quoteConfig", [bem]], ["tradeFeeBps"], ["feeSplitBps"], ["MAX_NAME_BYTES"], ["MAX_SYMBOL_BYTES"]]);
  if (!cw || !cb) throw new Error("CurvePad couldn't be read.");
  // tradeFeeBps() / feeSplitBps() exist from v3 on; earlier pads charge the same 1% and 50/30/20.
  const feeBps = fee ?? 100n, split = spl ?? [5000n, 3000n, 2000n];
  const maxName = Number(nameMax ?? 64n), maxSymbol = Number(symMax ?? 16n);
  const cfg = (c, dec, sym) => {
    const vQ0 = c.vQuote0, vT0 = c.vToken0, cs = c.curveSupply, lp = c.lpTokens, tEnd = vT0 - cs;
    const qEnd = (vQ0 * vT0) / tEnd;
    return {
      vQ0, vT0, cs, lp, tEnd, dec, sym,
      raise: qEnd - vQ0,                                   // quote raised at graduation
      p0: units(vQ0, dec) / units(vT0, 18),                // launch price (quote per token)
      pEnd: units(qEnd, dec) / units(tEnd, 18),            // graduation price
    };
  };
  state.pad = {
    addr: inst.pad, contract: pad, feeBps, split: split.map(Number), maxName, maxSymbol, graduator, wokb, bem, locker, hook, protocol, sink, registry, containerImpl, factory,
    guard: Number(guard), maxEarly, total, totalTokens: units(total, 18),
    cfg: { [wokb.toLowerCase()]: cfg(cw, 18, "WOKB"), [bem.toLowerCase()]: cfg(cb, 8, "BEM") },
  };
}

async function loadPrices() {
  const okb = await priceE18(A.USDT0_WOKB_POOL, state.pad.wokb);
  const bemInOkb = await priceE18(A.BEM_WOKB_POOL, state.pad.bem);
  state.prices = { okbUsd: Number(okb) / 1e18, bemUsd: (Number(bemInOkb) / 1e18) * (Number(okb) / 1e18) };
  $("#okb").textContent = "OKB $" + state.prices.okbUsd.toFixed(2);
}
const quoteUsd = (q) => q.toLowerCase() === state.pad.wokb.toLowerCase() ? state.prices.okbUsd : state.prices.bemUsd;
const isBem = (q) => q.toLowerCase() === state.pad.bem.toLowerCase();

let INDEX = null;
async function loadLaunches() {
  INDEX = null;
  try {
    const r = await fetch(`data/index-${state.inst}.json?t=${Date.now()}`, { cache: "no-store" });
    if (r.ok) INDEX = await r.json();
  } catch {}
  const known = new Map();
  for (const L of Object.values(INDEX?.launches || {})) known.set(L.token.toLowerCase(), L);
  // Scan forward past the index head ourselves (public RPC: 100-block windows), bounded so a stale index can't stall us.
  state.head = await rp.getBlockNumber();
  let from = (INDEX?.scannedTo ?? state.head - 300) + 1;
  from = Math.max(from, state.head - 1500);
  const iface = new E.Interface(ABI.pad);
  const topic = iface.getEvent("LaunchCreated").topicHash;
  for (let b = from; b <= state.head; b += 100) {
    try {
      const logs = await rp.getLogs({ address: state.pad.addr, topics: [topic], fromBlock: b, toBlock: Math.min(state.head, b + 99) });
      for (const lg of logs) {
        const ev = iface.parseLog(lg);
        const t = ev.args.token.toLowerCase();
        if (!known.has(t)) known.set(t, { token: ev.args.token, block: lg.blockNumber, ts: Date.now() / 1000, trades: [],
          creator: ev.args.creator, imageURI: ev.args.imageURI || "" });
      }
    } catch {}
  }
  const { launches, failed } = await readLaunches([...known.values()]);
  state.launches = launches.sort((a, b) => b.block - a.block);
  state.readFailed = failed;
}

async function multicall(calls) { // calls: [target, Interface, fn, args]. Returns decoded results, null where a call failed.
  const mc = C(A.MULTICALL3, ABI.multicall), out = [];
  for (let i = 0; i < calls.length; i += 120) {
    const chunk = calls.slice(i, i + 120);
    const res = await mc.aggregate3(chunk.map(([target, ifc, fn, args]) => ({ target, allowFailure: true, callData: ifc.encodeFunctionData(fn, args) })));
    res.forEach((r, j) => { let v = null; try { if (r.success) v = chunk[j][1].decodeFunctionResult(chunk[j][2], r.returnData); } catch {} out.push(v); });
  }
  return out;
}

async function readLaunches(list) {
  if (!list.length) return { launches: [], failed: 0 };
  const padI = new E.Interface(ABI.pad), ercI = new E.Interface(ABI.erc20), gradI = new E.Interface(ABI.graduator), svI = new E.Interface(ABI.stateView);
  const first = await multicall(list.flatMap((L) => [[state.pad.addr, padI, "curves", [L.token]], [L.token, ercI, "name", []], [L.token, ercI, "symbol", []], [L.token, ercI, "totalSupply", []],
    [L.token, ercI, "balanceOf", [L.creator || E.ZeroAddress]]]));
  const rows = list.map((L, i) => ({ L, c: first[i * 5], name: first[i * 5 + 1]?.[0], symbol: first[i * 5 + 2]?.[0], dev: L.creator ? devHolding(first[i * 5 + 4]?.[0], first[i * 5 + 3]?.[0]) : null }));
  const ok = rows.filter((r) => r.c && r.c.quote !== E.ZeroAddress && r.name != null && r.symbol != null);
  const grad = ok.filter((r) => Number(r.c.status) === 2);
  const keys = await multicall(grad.map((r) => [state.pad.graduator, gradI, "poolKey", [r.L.token, r.c.quote]]));
  const coder = E.AbiCoder.defaultAbiCoder();
  grad.forEach((r, i) => {
    if (!keys[i]) return;
    const k = keys[i][0];
    r.key = k;
    r.poolId = E.keccak256(coder.encode(["tuple(address,address,uint24,int24,address)"], [[k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks]]));
  });
  const withKey = grad.filter((r) => r.poolId);
  const slots = await multicall(withKey.map((r) => [A.STATE_VIEW, svI, "getSlot0", [r.poolId]]));
  withKey.forEach((r, i) => { r.sqrt = slots[i]?.sqrtPriceX96; });
  return { launches: ok.map((r) => ({ ...buildLaunch(r.L, r.c, r.name, r.symbol, r.poolId, r.key, r.sqrt), dev: r.dev })), failed: list.length - ok.length };
}

async function readLaunch(L) { // one launch, e.g. a token page opened by direct link
  const { launches } = await readLaunches([L]);
  return launches[0] || null;
}

function buildLaunch(L, c, name, symbol, poolId, key, sqrtPriceX96) {
  const cfg = state.pad.cfg[c.quote.toLowerCase()];
  const sold = cfg.cs - c.tokensLeft;
  let price = units(c.vQuote, cfg.dec) / units(c.vToken, 18);
  if (Number(c.status) === 2 && sqrtPriceX96) { // taped out: live price from the Uniswap v4 pool, not the closed curve
    const r = (Number(sqrtPriceX96) / 2 ** 96) ** 2; // raw currency1 per raw currency0
    const raw = key.currency0.toLowerCase() === L.token.toLowerCase() ? r : 1 / r; // raw quote per raw token
    price = raw * 10 ** (18 - cfg.dec);
  }
  const qUsd = quoteUsd(c.quote);
  return {
    ...L, token: L.token, name, symbol, quote: c.quote, cfg,
    vQuote: c.vQuote, vToken: c.vToken, realQuote: c.realQuote, tokensLeft: c.tokensLeft,
    container: c.container, circuitNft: c.circuitNft, circuitId: c.circuitId, launchBlock: Number(c.launchBlock),
    status: Number(c.status), poolId: poolId || null,
    progress: Number((sold * 10000n) / cfg.cs) / 100,
    price, mcQuote: price * state.pad.totalTokens, mcUsd: price * state.pad.totalTokens * qUsd,
  };
}

// ---------------------------------------------------------------- wallet
// EIP-6963: every installed wallet announces itself, so several wallets can coexist. window.ethereum is the fallback.
const announced = new Map();
window.addEventListener("eip6963:announceProvider", (e) => { if (e.detail?.info?.uuid) announced.set(e.detail.info.uuid, e.detail); });
window.dispatchEvent(new Event("eip6963:requestProvider"));
function chooseWallet() {
  const list = [...announced.values()];
  if (list.length === 1) return Promise.resolve(list[0].provider);
  if (!list.length) return Promise.resolve(window.ethereum || null);
  return new Promise((resolve) => {
    const d = document.createElement("div"); d.className = "wallets";
    const icon = (i) => /^data:image\//.test(i || "") ? `<img src="${esc(i)}" alt="">` : "";
    d.innerHTML = `<div><h3>Choose a wallet</h3>${list.map((w, i) => `<button class="w" data-i="${i}">${icon(w.info.icon)}${esc(w.info.name)}</button>`).join("")}<button class="btn ghost block" data-x>Cancel</button></div>`;
    d.onclick = (e) => {
      const b = e.target.closest("button");
      if (!b && e.target !== d) return;
      d.remove();
      resolve(b && b.dataset.i != null ? list[+b.dataset.i].provider : null);
    };
    document.body.appendChild(d);
  });
}
function noWallet() { // on phones an injected wallet only exists inside a wallet's own browser, so offer to go there
  if (!isMobile(navigator.userAgent)) { toast("No wallet found. Install OKX Wallet, MetaMask or Rabby in this browser."); return; }
  const d = document.createElement("div"); d.className = "wallets";
  d.innerHTML = `<div><h3>Open in a wallet</h3><p class="muted" style="font-size:13.5px;margin:0 0 12px">This browser has no wallet. Open Circ inside OKX Wallet's browser, or open this page in the browser of the wallet you use.</p>
    <a class="btn hub block" style="display:block;text-align:center;text-decoration:none;margin-bottom:8px" href="${esc(okxWalletLink(location.href))}" rel="noopener">Open in OKX Wallet</a><button class="btn ghost block">Close</button></div>`;
  d.onclick = (e) => { if (e.target === d || e.target.closest("button") || e.target.closest("a")) d.remove(); };
  document.body.appendChild(d);
}
function forget() { state.signer = null; state.account = null; $("#connect").textContent = "Connect"; }
let walletProvider = null;
async function connect() {
  const eth = await chooseWallet();
  if (!eth) { if (!announced.size && !window.ethereum) noWallet(); return null; }
  await eth.request({ method: "eth_requestAccounts" });
  if (Number(await eth.request({ method: "eth_chainId" })) !== CHAIN_ID) {
    try {
      await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0xc4" }] });
    } catch (e) {
      if (e.code !== 4902) throw e;
      await eth.request({ method: "wallet_addEthereumChain", params: [{
        chainId: "0xc4", chainName: "X Layer", nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
        rpcUrls: [RPC], blockExplorerUrls: [EXPLORER] }] });
    }
  }
  if (walletProvider !== eth && eth.on) {
    eth.on("accountsChanged", () => { forget(); route(); });
    eth.on("chainChanged", () => { forget(); toast("Network changed: reconnect on X Layer to continue."); route(); });
  }
  walletProvider = eth;
  state.signer = await new E.BrowserProvider(eth).getSigner();
  state.account = await state.signer.getAddress();
  $("#connect").textContent = short(state.account);
  return state.signer;
}
async function signer() { return state.signer || connect(); }
function confetti() { // a token just went LIVE. Canvas only, no library; skipped for people who ask for reduced motion.
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const cv = document.createElement("canvas");
  cv.id = "confetti";
  cv.style.cssText = "position:fixed;inset:0;width:100%;height:100%;pointer-events:none;z-index:9999";
  cv.width = innerWidth; cv.height = innerHeight;
  document.body.appendChild(cv);
  const g = cv.getContext("2d"), colors = ["#F4F6F9", "#A7AEB6", "#6B9E7D", "#C99A4E", "#C2635A"];
  const bits = Array.from({ length: 180 }, () => ({
    x: innerWidth / 2 + (Math.random() - .5) * innerWidth * .3, y: innerHeight * .35,
    vx: (Math.random() - .5) * 13, vy: -Math.random() * 13 - 3, w: 5 + Math.random() * 5, h: 8 + Math.random() * 6,
    r: Math.random() * 6, vr: (Math.random() - .5) * .35, c: colors[Math.floor(Math.random() * colors.length)],
  }));
  const start = performance.now();
  (function frame(t) {
    const age = t - start;
    if (age > 3800) return cv.remove();
    g.clearRect(0, 0, cv.width, cv.height);
    g.globalAlpha = Math.min(1, (3800 - age) / 800);
    for (const b of bits) {
      b.vy += .24; b.vx *= .99; b.x += b.vx; b.y += b.vy; b.r += b.vr;
      g.save(); g.translate(b.x, b.y); g.rotate(b.r); g.fillStyle = b.c; g.fillRect(-b.w / 2, -b.h / 2, b.w, b.h); g.restore();
    }
    requestAnimationFrame(frame);
  })(start);
}

async function sendTx(label, fn) {
  try {
    const s = await signer(); if (!s) return;
    toast(`${label}: confirm in your wallet`);
    const tx = await fn(s);
    toast(`${label}: sent ${short(tx.hash)}`);
    const r = await tx.wait();
    toast(`${label}: ${r.status === 1 ? "confirmed" : "reverted"}`, 6000);
    if (r.status === 1 && /launch/i.test(label)) confetti();
    route();
  } catch (e) {
    toast(`${label}: ${e.shortMessage || e.reason || e.message}`.slice(0, 180), 7000);
  }
}

// ---------------------------------------------------------------- views
function setBanner() {
  const b = $("#banner");
  if (CFG.staging) {
    b.hidden = false; b.classList.add("staging");
    b.firstElementChild.textContent = "STAGING: tiny test curves on the CIRC-TEST pad, not production. Transactions are real and cost real OKB.";
  } else b.hidden = true;
  $("#foot-pad").innerHTML = `CurvePad <a class="mono" href="${EXPLORER}/address/${state.pad?.addr || INSTANCES[state.inst].pad}" target="_blank" rel="noopener">${short(INSTANCES[state.inst].pad)}</a>`;
}

function traceHtml(cfg, mcUsdNow, qUsd, done) {
  const lo = cfg.p0 * state.pad.totalTokens * qUsd, hi = cfg.pEnd * state.pad.totalTokens * qUsd;
  const x = Math.max(0, Math.min(1, (mcUsdNow - lo) / (hi - lo)));
  return `<div class="trace">
    <div class="rail"><div class="lit" style="width:${x * 100}%"></div>
      <div class="pad l"></div><div class="pad r ${done ? "done" : ""}"></div>
      <div class="dot" style="left:${x * 100}%"></div>
      <div class="lab c mono" style="left:${x * 100}%">${usd(mcUsdNow)}</div>
      <div class="lab l">launch ${usd(lo)}</div><div class="lab r">tape-out ${usd(hi)}</div>
    </div></div>`;
}

const safeImage = (uri, token) => safeImageCore(uri, token, HIDE);
function ipfsImg(rel) { // walks the gateway list on error, then removes itself so the initials show (handler at the end of this file)
  return `<img src="${esc(IPFS_GATEWAYS[0] + rel)}" data-rel="${esc(rel)}" data-g="0" alt="" loading="lazy" referrerpolicy="no-referrer">`;
}
function avatar(L, cls = "") {
  const img = safeImage(L.imageURI, L.token);
  const fallback = `<span>${initials(L.symbol)}</span>`;
  return `<div class="av ${cls}" style="background:${hue(L.token)}">${img ? ipfsImg(img) : ""}${fallback}</div>`;
}
function devPill(L) {
  if (!L.dev) return `<span class="pill" title="The launching wallet isn't known yet">Dev holds –</span>`;
  return `<span class="pill ${L.dev.high ? "dev-high" : ""}" title="Share of supply in the wallet that launched this token. Tokens it moved elsewhere don't count.">Dev holds ${L.dev.pct.toFixed(L.dev.pct < 10 ? 2 : 1)}%</span>`;
}
const CHANGE_WINDOWS = [["5M", 300], ["30M", 1800], ["1H", 3600], ["24H", 86400]];
const changes = (L) => CHANGE_WINDOWS.map(([label, sec]) => ({ label, ...formatChange(priceChange(L.prices, Date.now() / 1000, sec, L.price)) }));
function pills(L) {
  return `<span class="pill ${STATUS_CLS[L.status]}">${STATUS[L.status]}</span>` +
    (isBem(L.quote) ? `<span class="pill vol" title="BEM-quoted: the graduation target is fixed in BEM, so its USD value moves with BEM's price">BEM · volatile quote</span>` : "");
}

async function viewFloor() {
  const p = state.pad, w = p.cfg[p.wokb.toLowerCase()], bq = p.cfg[p.bem.toLowerCase()];
  const okb = state.prices.okbUsd, bemU = state.prices.bemUsd;
  const L = state.launches;
  const grad = L.filter((x) => x.status === 2).length;
  $("#app").innerHTML = `
  <section class="hero">
    <div>
      <div class="eyebrow">Circ Launchpad · X Layer</div>
      <h1>Every token is <em>wired</em> to a circuit.</h1>
      <p class="lede">Launch a bonding-curve token from a TapeOut Circuit you hold. Half of every fee flows to that
      Circuit's Container, forever. When the curve fills, it tapes out into a Uniswap v4 pool whose liquidity is locked for good.</p>
      <div class="cta"><a class="btn hub" href="#/launch">Launch from a Circuit</a><a class="btn ghost" href="#wafer">Browse the wafer</a></div>
    </div>
    <div class="spec">
      <h3>Curve spec · read from CurvePad</h3>
      <dl>
        <dt>Supply per launch</dt><dd>${num(p.totalTokens, 0)}</dd>
        <dt>Sold on the curve</dt><dd>${num(units(w.cs, 18), 1)} (${(units(w.cs, 18) / p.totalTokens * 100).toFixed(1)}%)</dd>
        <dt>Launch market cap</dt><dd>${usd(w.p0 * p.totalTokens * okb)}</dd>
        <dt>Tape-out market cap</dt><dd>${usd(w.pEnd * p.totalTokens * okb)}</dd>
        <dt>Tape-out raise (WOKB)</dt><dd>${num(units(w.raise, 18), 2)} WOKB · ${usd(units(w.raise, 18) * okb)}</dd>
        <dt>Tape-out raise (BEM)</dt><dd>${num(units(bq.raise, 8), 2)} BEM · ${usd(units(bq.raise, 8) * bemU)}</dd>
        <dt>Anti-snipe guard</dt><dd>${p.guard} blocks · ${(units(p.maxEarly, 18) / p.totalTokens * 100).toFixed(1)}%/block</dd>
        <dt>Locked LP at tape-out</dt><dd>${num(units(w.lp, 18), 1)} tokens</dd>
      </dl>
      <div class="src">CurvePad ${p.addr} · OKB $${okb.toFixed(2)} from the USD₮0/WOKB pool</div>
    </div>
  </section>
  ${traceHtml(w, w.p0 * p.totalTokens * okb * 1.0001, okb, false).replace('class="trace"', 'class="trace" style="margin:8px 0 4px"')}
  <div class="section-h" id="wafer"><h2>The wafer <span class="muted mono" style="font-size:13px;font-weight:400">${L.length} launches · ${grad} taped out${state.readFailed ? ` · ${state.readFailed} couldn't be read` : ""}</span></h2></div>
  ${kingCard()}
  <div class="stat-strip">
    <div><b>${L.filter((x) => x.status === 0).length}</b><span>on the curve</span></div>
    <div><b>${L.filter((x) => floorStage(x) === "near").length}</b><span>close to the gate</span></div>
    <div><b>${grad}</b><span>on Uniswap</span></div>
  </div>
  <div class="floor-tools">
    <input id="floor-q" type="search" placeholder="Search name, ticker or Nand number" aria-label="Search tokens" value="${esc(floor.q)}">
    <div class="seg-tabs" role="tablist" aria-label="Filter">${FLOOR_FILTERS.map(([id, l]) => `<button data-filter="${id}" class="${floor.filter === id ? "on" : ""}">${l}</button>`).join("")}</div>
    <div class="seg-tabs" role="tablist" aria-label="View">${FLOOR_VIEWS.map(([id, l]) => `<button data-view="${id}" class="${floor.view === id ? "on" : ""}">${l}</button>`).join("")}</div>
  </div>
  <div id="floor-view">${floorView()}</div>`;
}

// ---------------------------------------------------------------- fab floor views: the same real launches, drawn five ways
const FLOOR_VIEWS = [["wafer", "Wafer"], ["table", "Table"], ["board", "Board"], ["race", "Race"]];
const FLOOR_FILTERS = [["all", "All"], ["live", "On the curve"], ["near", "Close to the gate"], ["uni", "On Uniswap"]];
const floor = { view: (() => { try { const v = localStorage.getItem("circ.view"); return ["table", "board", "race"].includes(v) ? v : "wafer"; } catch { return "wafer"; } })(), q: "", filter: "all", sort: "age", desc: true, col: "new" };
const FLOOR_SORTS = {
  age: (x) => x.ts || 0, mc: (x) => x.mcUsd, curve: (x) => (x.status ? 100 : x.progress),
  ch5: (x) => priceChange(x.prices, Date.now() / 1000, 300, x.price), ch1h: (x) => priceChange(x.prices, Date.now() / 1000, 3600, x.price),
};
const curvePct = (x) => (x.status ? "100" : x.progress.toFixed(1));
const chgCell = (x, i) => { const c = changes(x)[i]; return `<span class="chg ${c.cls}">${c.text}</span>`; };

function kingCard() {
  const k = kingOfTheHill(state.launches, Date.now() / 1000);
  if (!k) return `<div class="king empty"><span class="king-tag">King of the hill</span><span class="muted">No token on the hill yet. The crown goes to the one closest to tape-out or trading hardest on its way there.</span></div>`;
  const x = k.L, sym = x.cfg.sym, vol = k.volume * units(x.cfg.raise, x.cfg.dec);
  return `<a class="king" href="#/t/${x.token}">${avatar(x)}
    <div class="king-main"><span class="king-tag">King of the hill</span><b>${esc(x.name)} <span class="muted">$${esc(x.symbol)}</span></b>
      <div class="bar"><div style="width:${x.status ? 100 : x.progress}%"></div></div>
      <small class="mono muted">${curvePct(x)}% to tape-out · ${circuitLabel(x)}</small></div>
    <div class="king-nums"><span class="mono">${usd(x.mcUsd)}</span>${chgCell(x, 2)}<small class="mono muted">${num(vol, 3)} ${sym} in 1H</small></div></a>`;
}

function floorView() {
  const L = state.launches;
  if (!L.length) return `<div class="empty-state"><b>The wafer is clean.</b>No launches yet.</div>`;
  const list = filterLaunches(L, floor.q, floor.filter);
  if (!list.length) return `<div class="empty-state"><b>Nothing matches${floor.q ? ` "${esc(floor.q)}"` : " this filter"}.</b>Try a ticker or a Nand number.</div>`;
  return { table: floorTable, board: floorBoard, race: floorRace }[floor.view]?.(list) || floorWafer(list);
}

function floorWafer(L) {
  const cells = [];
  let k = 0;
  for (let r = 0; r < 8; r++) for (let c = 0; c < 8; c++) {
    const dx = c - 3.5, dy = r - 3.5, inside = dx * dx + dy * dy <= 17.5;
    if (!inside) { cells.push(`<div class="die out"></div>`); continue; }
    const x = L[k++];
    if (!x) { cells.push(`<div class="die empty"></div>`); continue; }
    const cls = ["die", "live", x.status === 2 ? "grad" : x.status === 1 ? "complete" : "", isBem(x.quote) ? "bem" : ""].join(" ");
    cells.push(`<a class="${cls}" href="#/t/${x.token}" title="${esc(x.symbol)} · ${x.progress.toFixed(1)}% · ${usd(x.mcUsd)}${x.dev ? ` · Dev holds ${x.dev.pct.toFixed(1)}%` : ""}">
      ${x.status === 2 ? "" : `<div class="fill" style="height:${Math.max(4, x.progress)}%"></div>`}<span class="sym">${esc(x.symbol.slice(0, 5))}</span></a>`);
  }
  const rows = L.map((x) => `<a class="row" href="#/t/${x.token}">
      <div class="tok">${avatar(x)}<div><b>${esc(x.name)}</b><small>$${esc(x.symbol)} · ${circuitLabel(x)}</small></div></div>
      <div class="mono">${usd(x.mcUsd)}<div class="muted" style="font-size:12px">${num(x.mcQuote, 2)} ${x.cfg.sym}</div><div class="bar mini" title="Curve sold: ${curvePct(x)}%"><div style="width:${x.status ? 100 : x.progress}%"></div></div></div>
      <div class="chgs">${changes(x).map((c) => `<div class="chg ${c.cls}" data-l="${c.label}">${c.text}</div>`).join("")}</div>
      <div class="status-cell">${pills(x)}${devPill(x)}</div>
      <div class="mono muted" style="font-size:12px">${x.ts ? ago(x.ts) : ""}</div></a>`).join("");
  return `<div class="legend" style="margin-bottom:14px"><span><i style="background:var(--orange)"></i>trading (fill = curve sold)</span><span><i style="background:var(--yellow)"></i>complete</span>
    <span><i style="background:var(--green)"></i>taped out</span><span><i style="background:transparent;box-shadow:inset 0 0 0 1.5px var(--blue)"></i>BEM · volatile quote</span></div>
  <div class="wafer-wrap">
    <div class="wafer"><div class="grid">${cells.join("")}</div></div>
    <div><div class="list"><div class="row head"><div>Token</div><div>Market cap</div><div class="chgs">${CHANGE_WINDOWS.map(([l]) => `<div class="chg">${l}</div>`).join("")}</div><div>Status · Dev</div><div>Age</div></div>${rows}</div></div>
  </div>`;
}

function floorTable(L) {
  const sorted = sortBy(L, FLOOR_SORTS[floor.sort], floor.desc);
  const head = (id, label, cls = "") => `<button class="${cls}" data-sort="${id}" aria-sort="${floor.sort === id ? (floor.desc ? "descending" : "ascending") : "none"}">${label}${floor.sort === id ? (floor.desc ? " ↓" : " ↑") : ""}</button>`;
  return `<div class="list f-table"><div class="f-row f-head"><div>Token</div>${head("age", "Age", "c-age")}${head("mc", "Market cap", "r")}${head("ch5", "5M", "r")}${head("ch1h", "1H", "r")}${head("curve", "Curve", "c-curve")}<div class="c-status">Status</div></div>
    ${sorted.map((x) => `<a class="f-row" href="#/t/${x.token}"><div class="tok">${avatar(x)}<div><b>${esc(x.symbol)}</b><small>${esc(x.name)} · ${circuitLabel(x)}</small></div></div>
      <div class="c-age mono muted">${x.ts ? ago(x.ts) : ""}</div><div class="r mono">${usd(x.mcUsd)}</div><div class="r">${chgCell(x, 0)}</div><div class="r">${chgCell(x, 2)}</div>
      <div class="c-curve"><div class="bar"><div style="width:${x.status ? 100 : x.progress}%"></div></div><small class="mono muted">${curvePct(x)}%</small></div>
      <div class="c-status">${pills(x)}</div></a>`).join("")}</div>`;
}

function floorBoard(L) {
  const cols = [["new", "Just launched", "Under half the curve sold"], ["near", "Close to the gate", "Half sold or more, about to tape out"], ["uni", "On Uniswap", "Taped out, liquidity locked"]];
  if (!floor.colPicked) floor.col = cols.map(([id]) => id).find((id) => L.some((x) => floorStage(x) === id)) || "new"; // on a phone, open a column that has tokens
  const card = (x) => `<a class="b-card" href="#/t/${x.token}"><div class="tok">${avatar(x)}<div><b>${esc(x.symbol)}</b><small>${esc(x.name)} · ${circuitLabel(x)}</small></div></div>
    <div class="b-nums"><span class="mono">${usd(x.mcUsd)}</span>${chgCell(x, 2)}</div><div class="bar"><div style="width:${x.status ? 100 : x.progress}%"></div></div></a>`;
  return `<div class="seg-tabs b-tabs">${cols.map(([id, t]) => `<button data-col="${id}" class="${floor.col === id ? "on" : ""}">${t}</button>`).join("")}</div>
  <div class="board">${cols.map(([id, title, hint]) => { const c = L.filter((x) => floorStage(x) === id);
    return `<section class="b-col ${floor.col === id ? "on" : ""}"><h3>${title} <span class="muted mono">${c.length}</span></h3><p class="muted">${hint}</p>${c.map(card).join("") || `<div class="muted b-none">None right now.</div>`}</section>`; }).join("")}</div>`;
}

function floorRace(L) {
  const racing = sortBy(L.filter((x) => x.status !== 2), (x) => x.progress, true), done = L.filter((x) => x.status === 2);
  const lane = (x) => { const pct = x.status ? 100 : x.progress;
    return `<a class="lane" href="#/t/${x.token}"><span class="who"><b>${esc(x.symbol)}</b><small class="muted">${circuitLabel(x)}</small></span>
      <span class="road" aria-label="${pct.toFixed(1)} percent to the flag"><span class="run" style="width:${pct}%"></span><span class="flag"></span><span class="racer" style="left:${pct}%">${avatar(x)}</span></span>
      <span class="mono r">${usd(x.mcUsd)}<small class="muted">${curvePct(x)}%</small></span></a>`; };
  return `<div class="race-head"><h3>The race to Uniswap</h3><p class="muted">Every buy moves a token forward. At the flag it tapes out into a locked Uniswap v4 pool.</p></div>
  <div class="track">${racing.map(lane).join("") || `<div class="muted b-none">Nobody on the track right now.</div>`}</div>
  ${done.length ? `<h3 class="g-sec">Finished</h3><div class="track done">${done.map(lane).join("")}</div>` : ""}`;
}

function showFloorView() { const v = $("#floor-view"); if (v) v.innerHTML = floorView(); }
function setSegment(attr, value) { document.querySelectorAll(`[${attr}]`).forEach((b) => b.classList.toggle("on", b.getAttribute(attr) === value)); }
document.addEventListener("input", (e) => { if (e.target.id === "floor-q") { floor.q = e.target.value; showFloorView(); } });
document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-view],[data-filter],[data-sort],[data-col],[data-frame]");
  if (!t) return;
  if (t.dataset.view) { floor.view = t.dataset.view; try { localStorage.setItem("circ.view", floor.view); } catch {} setSegment("data-view", floor.view); }
  else if (t.dataset.filter) { floor.filter = t.dataset.filter; setSegment("data-filter", floor.filter); }
  else if (t.dataset.sort) { floor.desc = floor.sort === t.dataset.sort ? !floor.desc : true; floor.sort = t.dataset.sort; }
  else if (t.dataset.col) { floor.col = t.dataset.col; floor.colPicked = true; }
  else if (t.dataset.frame) { const c = $("#price-chart"); const L = state.launches.find((x) => x.token === c?.dataset.token); if (L) c.innerHTML = priceChart(L, t.dataset.frame); return; }
  showFloorView();
});

// ---------------------------------------------------------------- token page: price chart
function priceChart(L, frame = "24H") {
  const w = CHANGE_WINDOWS.find(([l]) => l === frame) || CHANGE_WINDOWS[3], W = 600, H = 180;
  const line = chartLine(L.prices, Date.now() / 1000, w[1], L.price, W, H);
  const c = formatChange(priceChange(L.prices, Date.now() / 1000, w[1], L.price));
  return `<h3>Price <small class="chg ${c.cls}">${c.text} in ${w[0]}</small></h3>
    ${line ? `<svg class="p-chart ${c.cls}" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Price over the last ${w[0]}"><polyline points="${line}"/></svg>` : `<div class="muted b-none">No price history yet.</div>`}
    <div class="seg-tabs">${CHANGE_WINDOWS.map(([l]) => `<button data-frame="${l}" class="${l === w[0] ? "on" : ""}">${l}</button>`).join("")}</div>`;
}

function circuitLabel(x) {
  const n = x.circuitNft?.toLowerCase() === A.NANDOUT.toLowerCase() ? "Nandout" : short(x.circuitNft);
  return `${n} #${x.circuitId}`;
}

function curveSvg(L) {
  // MC along the curve: price(s) = k / (vT0 - s)^2, s = tokens sold
  const cfg = L.cfg, qUsd = quoteUsd(L.quote), T = state.pad.totalTokens;
  const vT0 = units(cfg.vT0, 18), cs = units(cfg.cs, 18), k = units(cfg.vQ0, cfg.dec) * vT0;
  const W = 640, H = 220, P = 34, N = 80;
  const mc = (s) => (k / ((vT0 - s) ** 2)) * T * qUsd;
  const hi = mc(cs), lo = mc(0);
  const X = (s) => P + (s / cs) * (W - 2 * P), Y = (m) => H - P - ((m - lo) / (hi - lo)) * (H - 2 * P);
  let d = "";
  for (let i = 0; i <= N; i++) { const s = (cs * i) / N; d += (i ? "L" : "M") + X(s).toFixed(1) + " " + Y(mc(s)).toFixed(1); }
  const sold = Math.min(cs, cs - units(L.tokensLeft, 18));
  let lit = "";
  for (let i = 0; i <= N; i++) { const s = (sold * i) / N; lit += (i ? "L" : "M") + X(s).toFixed(1) + " " + Y(mc(s)).toFixed(1); }
  const cx = X(sold), cy = Y(mc(sold));
  return `<svg class="curve" viewBox="0 0 ${W} ${H}" role="img" aria-label="Bonding curve: market cap against tokens sold">
    <defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#7C838C"/><stop offset="1" stop-color="#F4F6F9"/></linearGradient></defs>
    <g stroke="rgba(255,255,255,.06)">${[0, .25, .5, .75, 1].map((f) => `<line x1="${P}" x2="${W - P}" y1="${P + f * (H - 2 * P)}" y2="${P + f * (H - 2 * P)}"/>`).join("")}</g>
    <path d="${d}" fill="none" stroke="#2A2B2E" stroke-width="2"/>
    <path d="${lit}" fill="none" stroke="url(#g)" stroke-width="2.5"/>
    <circle cx="${cx}" cy="${cy}" r="5" fill="#F4F6F9"/><circle cx="${cx}" cy="${cy}" r="11" fill="none" stroke="rgba(255,255,255,.25)"/>
    <g font-family="IBM Plex Mono" font-size="11" fill="#8B929A">
      <text x="${P}" y="${H - 10}">0</text><text x="${W - P}" y="${H - 10}" text-anchor="end">${num(cs, 0)} sold → tape-out</text>
      <text x="${P}" y="${Y(lo) - 8}">${usd(lo)}</text><text x="${W - P}" y="${P - 10}" text-anchor="end">${usd(hi)}</text>
    </g></svg>`;
}

async function viewToken(addr) {
  let L = state.launches.find((x) => x.token.toLowerCase() === addr.toLowerCase());
  if (!L) L = await readLaunch({ token: addr, trades: [], block: 0 }).catch(() => null);
  if (!L) { $("#app").innerHTML = `<div class="empty-state" style="margin-top:40px"><b>Not a Circ launch</b>${esc(addr)}</div>`; return; }
  const cfg = L.cfg, qUsd = quoteUsd(L.quote), qd = cfg.dec, sym = cfg.sym;
  const head = await rp.getBlockNumber();
  const guardLeft = guardBlocksLeft(L.launchBlock, state.pad.guard, head);
  const trades = (INDEX?.launches?.[L.token.toLowerCase()]?.trades || L.trades || []).slice().reverse();
  const grad = INDEX?.launches?.[L.token.toLowerCase()]?.graduated;

  $("#app").innerHTML = `
  <div class="tp-head">${avatar(L)}
    <div><h1>${esc(L.name)} <span class="muted" style="font-weight:400">$${esc(L.symbol)}</span></h1>
    <div class="meta">${pills(L)}${devPill(L)}${changes(L).map((c) => `<span class="pill chg ${c.cls}">${c.label} ${c.text}</span>`).join("")}<span class="pill">${circuitLabel(L)}</span>
      <a class="pill" href="${EXPLORER}/token/${L.token}" target="_blank" rel="noopener">${short(L.token)} ↗</a></div></div>
  </div>
  ${isBem(L.quote) ? `<div class="note vol">Volatile quote: this launch is priced in BEM. Its tape-out target is fixed at ${num(units(cfg.raise, 8), 2)} BEM, so the USD value of the target (and of every price here) moves with BEM.</div>` : ""}
  <div class="cols">
    <div>
      <div class="card"><div class="stats">
        <div><label>Market cap</label><b>${usd(L.mcUsd)}</b><small>${num(L.mcQuote, 3)} ${sym}</small></div>
        <div><label>Price</label><b>${L.price.toPrecision(3)}</b><small>${sym} per token${L.status === 2 ? " · v4 pool" : ""}</small></div>
        <div><label>Raised</label>${L.status === 2
          ? `<b>${Number(units(cfg.raise, qd).toPrecision(3))} ${sym}</b><small>raised, moved to the Uniswap pool</small>`
          : `<b>${num(units(L.realQuote, qd), 3)}</b><small>of ${num(units(cfg.raise, qd), 2)} ${sym}</small>`}</div>
        <div><label>Curve sold</label><b>${L.status ? "100" : L.progress.toFixed(2)}%</b><small>${num(units(L.tokensLeft, 18), 2)} left</small></div>
      </div></div>
      <div class="card" id="price-chart" data-token="${L.token}">${priceChart(L)}</div>
      <div class="card"><h3>Bonding curve</h3>${curveSvg(L)}</div>
      <div class="card"><h3>Trades on the curve <small>${trades.length ? "latest first" : ""}</small></h3>
        <div class="tape">${trades.length ? trades.slice(0, 30).map((t) => `<div class="t">
          <span class="${t.buy ? "b" : "s"}">${t.buy ? "BUY" : "SELL"}</span>
          <span>${num(units(BigInt(t.t), 18), 2)}</span><span>${num(units(BigInt(t.q), qd), 5)} ${sym}</span>
          <a class="hide-m" href="${EXPLORER}/address/${t.who}" target="_blank" rel="noopener">${short(t.who)}</a>
          <a href="${EXPLORER}/tx/${t.tx}" target="_blank" rel="noopener">${ago(t.ts)} ↗</a></div>`).join("")
          : `<div class="muted">No curve trades yet.</div>`}</div></div>
    </div>
    <div>
      <div class="card" id="tradebox"></div>
      <div class="card" id="creator"></div>
    </div>
  </div>`;

  // trade / graduate / taped-out box
  const box = $("#tradebox");
  if (L.status === 0) renderTrade(box, L, guardLeft);
  else if (L.status === 1) {
    box.innerHTML = `<h3>Curve complete</h3><p class="muted" style="margin-top:0">Every curve token is sold. Anyone can tape it out:
      graduation opens the Uniswap v4 pool at the curve's final price and locks the liquidity. The Circ keeper does this automatically.</p>
      <button class="btn hub block" id="gradbtn">Tape out now</button>`;
    $("#gradbtn").onclick = () => sendTx("Tape out", (s) => C(state.pad.addr, ABI.pad, s).graduate(L.token));
  } else {
    renderPoolTrade(box, L, grad);
  }
  renderCreator($("#creator"), L);
}

function renderTrade(box, L, guardLeft) {
  const cfg = L.cfg, sym = cfg.sym, qd = cfg.dec, wokbQ = !isBem(L.quote);
  let side = "buy";
  box.innerHTML = `<div class="trade-tabs"><button class="buy on" data-s="buy">Buy</button><button class="sell" data-s="sell">Sell</button></div>
    <div class="field"><label><span id="inlab">You pay</span><span id="bal"></span></label><input id="amt" inputmode="decimal" placeholder="0.0"></div>
    <div class="quick" id="quick"></div>
    <dl class="kv" id="pv"><dt>You receive</dt><dd>–</dd></dl>
    ${guardLeft > 0 ? `<div class="note warn" id="guard-note"></div>` : ""}
    <button class="btn hub block" id="go">Connect wallet</button>
    <div class="note">${Number(state.pad.feeBps) / 100}% fee on every trade: ${state.pad.split[0] / 100}% to this launch's Container, ${state.pad.split[1] / 100}% protocol, ${state.pad.split[2] / 100}% sink. Slippage limit 1%.</div>`;
  const amt = $("#amt", box), pv = $("#pv", box), go = $("#go", box);
  const quick = () => $("#quick", box).innerHTML = (side === "buy"
    ? (wokbQ ? ["0.01", "0.1", "0.5", "1"] : ["1", "5", "10", "25"]).map((v) => `<button data-v="${v}">${v} ${wokbQ ? "OKB" : "BEM"}</button>`)
    : ["25", "50", "100"].map((v) => `<button data-p="${v}">${v}%</button>`)).join("");
  // `last` is what the button will send. It is cleared on every keystroke, and a slow preview for an older amount is
  // discarded (seq), so the button can never send anything but the amount on screen.
  let last = null, seq = 0;
  async function preview() {
    const mine = ++seq, v = amt.value.trim(); last = null;
    if (!v || isNaN(+v) || +v <= 0) { pv.innerHTML = `<dt>You receive</dt><dd>–</dd>`; return; }
    try {
      if (side === "buy") {
        const q = E.parseUnits(v, qd);
        const pad = state.pad.contract;
        const [c, head, early] = await Promise.all([pad.curves(L.token), rp.getBlockNumber(), pad.earlyBlock(L.token)]);
        const guarded = guardBlocksLeft(Number(c.launchBlock), state.pad.guard, head) > 0;
        const r = previewCurveBuy({ vQuote: c.vQuote, vToken: c.vToken, tokensLeft: c.tokensLeft, quoteIn: q, feeBps: state.pad.feeBps,
          guarded, maxEarly: state.pad.maxEarly, soldThisBlock: Number(early.blockNumber) >= head ? early.sold : 0n });
        if (mine !== seq) return;
        if (r.out === 0n) { pv.innerHTML = `<dt>Preview</dt><dd>${guarded ? "this block's cap is used up, try again" : "amount too small"}</dd>`; return; }
        // While guarded we send the full amount: the contract applies the cap at the block it lands in and refunds the rest.
        last = { q: guarded ? q : r.used, min: r.minOut, guarded };
        pv.innerHTML = `<dt>You receive</dt><dd>${r.capped ? "up to " : ""}${num(units(r.out, 18), 2)} ${esc(L.symbol)}</dd>
          ${r.used < q ? `<dt>${r.capped ? "Used (block cap)" : "Used (curve fills)"}</dt><dd>${num(units(r.used, qd), 6)} ${sym}</dd>
          <dt>Refunded</dt><dd>${num(units(q - r.used, qd), 6)} ${sym}</dd>` : ""}
          <dt>Fee</dt><dd>${num(units(r.fee, qd), 6)} ${sym}</dd>`;
      } else {
        const t = E.parseUnits(v, 18);
        const out = await state.pad.contract.previewSell(L.token, t);
        if (mine !== seq) return;
        last = { t, min: (out * 99n) / 100n };
        pv.innerHTML = `<dt>You receive</dt><dd>${num(units(out, qd), 6)} ${sym}${wokbQ ? " (as WOKB)" : ""}</dd>`;
      }
    } catch (e) { if (mine === seq) pv.innerHTML = `<dt>Preview</dt><dd>${esc(e.shortMessage || "unavailable")}</dd>`; }
  }
  async function balances() {
    if (!state.account) { go.textContent = "Connect wallet"; return; }
    go.textContent = side === "buy" ? `Buy ${L.symbol}` : `Sell ${L.symbol}`;
    const b = side === "buy"
      ? (wokbQ ? await rp.getBalance(state.account) : await C(L.quote, ABI.erc20).balanceOf(state.account))
      : await C(L.token, ABI.erc20).balanceOf(state.account);
    box._bal = b;
    $("#bal", box).textContent = "balance " + num(units(b, side === "buy" ? qd : 18), 4);
  }
  box.querySelectorAll(".trade-tabs button").forEach((b) => b.onclick = () => {
    side = b.dataset.s; box.querySelectorAll(".trade-tabs button").forEach((x) => x.classList.toggle("on", x === b));
    $("#inlab", box).textContent = side === "buy" ? `You pay (${wokbQ ? "OKB" : "BEM"})` : `You sell (${L.symbol})`;
    amt.value = ""; quick(); preview(); balances();
  });
  $("#quick", box).onclick = (e) => {
    const b = e.target.closest("button"); if (!b) return;
    if (b.dataset.v) amt.value = b.dataset.v;
    else if (box._bal) amt.value = E.formatUnits((box._bal * BigInt(b.dataset.p)) / 100n, 18);
    preview();
  };
  amt.oninput = () => { last = null; seq++; clearTimeout(amt._t); amt._t = setTimeout(preview, 250); };
  $("#inlab", box).textContent = `You pay (${wokbQ ? "OKB" : "BEM"})`;
  quick(); balances();
  // The guard is judged by the block a buy lands in, so the countdown and the quote have to stay live.
  const guardNote = $("#guard-note", box);
  const showGuard = (left) => { guardNote.textContent = `Anti-snipe guard: ${left} more block${left === 1 ? "" : "s"}. Buys are capped at ${num(units(state.pad.maxEarly, 18), 1)} tokens per block across all buyers, and the rest is refunded. The guard may end before your transaction lands: the cap then no longer applies, and your full amount is spent at the live price.`; };
  const guardEnded = () => { guardNote?.remove(); if (amt.value.trim()) { last = null; seq++; preview(); } };
  if (guardNote) {
    showGuard(guardLeft);
    const tick = setInterval(async () => {
      if (!guardNote.isConnected) return clearInterval(tick);
      try {
        const left = guardBlocksLeft(L.launchBlock, state.pad.guard, await rp.getBlockNumber());
        if (left > 0) showGuard(left); else { clearInterval(tick); guardEnded(); }
      } catch {} // the next tick tries again
    }, 3000);
  }
  go.onclick = async () => {
    if (!state.account) { await connect(); balances(); return; }
    if (!last) { toast(amt.value.trim() ? "Updating the quote, try again in a moment" : "Enter an amount"); return; }
    if (side === "buy" && last.guarded && guardBlocksLeft(L.launchBlock, state.pad.guard, await rp.getBlockNumber()) <= 0) {
      guardEnded(); toast("The anti-snipe guard just ended, so the quote changed. Check it and press Buy again.", 6000); return;
    }
    const order = last; // fixed for this click, whatever the input does while the wallet is open
    const deadline = Math.floor(Date.now() / 1000) + 1200;
    if (side === "buy") {
      if (wokbQ) sendTx("Buy", (s) => C(state.pad.addr, ABI.pad, s).buyWithOKB(L.token, order.min, deadline, { value: order.q }));
      else sendTx("Buy", async (s) => {
        const t = C(L.quote, ABI.erc20, s);
        if ((await t.allowance(state.account, state.pad.addr)) < order.q) {
          toast("Signature 1 of 2: approve BEM");
          await (await t.approve(state.pad.addr, order.q)).wait();
          toast("Signature 2 of 2: buy");
        }
        return C(state.pad.addr, ABI.pad, s).buy(L.token, order.q, order.min, deadline);
      });
    } else sendTx("Sell", async (s) => {
      const t = C(L.token, ABI.erc20, s);
      if ((await t.allowance(state.account, state.pad.addr)) < order.t) {
        toast("Signature 1 of 2: approve the token");
        await (await t.approve(state.pad.addr, order.t)).wait();
        toast("Signature 2 of 2: sell");
      }
      return C(state.pad.addr, ABI.pad, s).sell(L.token, order.t, order.min, deadline);
    });
  };
}

// Container withdraw fee: TapeOut charges it per execute; read it live from the Container's fee revert (0xafd49700).
async function containerState(container, holder) { // "none" | "unpaid" | "open" | "unknown", plus the per-execute fee
  if ((await rp.getCode(container)) === "0x") return { state: "none", fee: null };
  try {
    const data = new E.Interface(ABI.container).encodeFunctionData("execute", [E.ZeroAddress, 0, "0x", 0]);
    await rp.call({ to: container, from: holder, data });
    return { state: "open", fee: 0n };
  } catch (e) {
    return parseContainerRevert(e?.data || e?.info?.error?.data || e?.revert?.data);
  }
}

// Fees a locked position has earned but nobody has collected yet. Read from v4's fee growth, so no transaction is needed.
async function uncollectedLpFees(L, positionId) {
  const p = state.pad, sv = C(A.STATE_VIEW, ABI.stateView), g = C(p.graduator, ABI.graduator);
  const [lo, hi, posm] = await Promise.all([g.TICK_LOWER(), g.TICK_UPPER(), C(p.locker, ABI.locker).positionManager()]);
  const salt = E.zeroPadValue(E.toBeHex(positionId), 32);
  const [[now0, now1], [liq, last0, last1], key] = await Promise.all([
    sv.getFeeGrowthInside(L.poolId, lo, hi), sv.getPositionInfo(L.poolId, posm, lo, hi, salt), g.poolKey(L.token, L.quote)]);
  const fee0 = uncollectedFee(liq, now0, last0), fee1 = uncollectedFee(liq, now1, last1);
  const tokenIs0 = key.currency0.toLowerCase() === L.token.toLowerCase();
  return { token: tokenIs0 ? fee0 : fee1, quote: tokenIs0 ? fee1 : fee0 };
}

async function renderCreator(el, L) {
  el.innerHTML = `<h3>Creator fees <small>${circuitLabel(L)}</small></h3><div class="muted skel">loading</div>`;
  const p = state.pad, lockerC = C(p.locker, ABI.locker);
  const [holder, openFee] = await Promise.all([C(L.circuitNft, ABI.nft).ownerOf(L.circuitId), C(A.OPENER, ABI.opener).FEE().catch(() => null)]);
  const cs = await containerState(L.container, holder);
  const opened = cs.state === "open";
  const assets = [{ a: L.quote, sym: L.cfg.sym, dec: L.cfg.dec }, { a: L.token, sym: L.symbol, dec: 18 }];
  const rows = await Promise.all(assets.map(async (x) => {
    const [pa, la, cb] = await Promise.all([p.contract.accrued(x.a, L.container), lockerC.accrued(x.a, L.container), C(x.a, ABI.erc20).balanceOf(L.container)]);
    return { ...x, claim: pa + la, pa, la, cb };
  }));
  const positionId = INDEX?.launches?.[L.token.toLowerCase()]?.graduated?.positionId;
  const lp = L.status === 2 && positionId != null ? await uncollectedLpFees(L, positionId).catch(() => null) : null;
  const q = rows[0], t = rows[1];
  const claimOkb = units(q.claim, q.dec) * (isBem(L.quote) ? state.prices.bemUsd / state.prices.okbUsd : 1);
  const feeOkb = cs.fee != null ? units(cs.fee, 18) : null;
  const openOkb = openFee != null ? units(openFee, 18) : null;
  const recDirect = recommendDirect({ claimOkb, opened, openOkb, feeOkb });
  const isHolder = state.account && state.account.toLowerCase() === holder.toLowerCase();
  const containerLabel = { open: "opened", none: "not opened", unpaid: "deployed, open fee not paid", unknown: "status unknown" }[cs.state];
  const lpOwed = lp && (lp.token > 0n || lp.quote > 0n);
  const withdrawable = opened ? rows.filter((r) => r.cb > 0n) : [];
  el.innerHTML = `<h3>Creator fees <small>${circuitLabel(L)}</small></h3>
    <dl class="kv">
      ${rows.map((r) => `<dt>Claimable ${esc(r.sym)}</dt><dd>${num(units(r.claim, r.dec), 6)}</dd>`).join("")}
      <dt>Container</dt><dd><a href="${EXPLORER}/address/${L.container}" target="_blank" rel="noopener">${short(L.container)}</a> · ${containerLabel}</dd>
      ${rows.map((r) => `<dt>Container balance ${esc(r.sym)}</dt><dd>${num(units(r.cb, r.dec), 6)}</dd>`).join("")}
      <dt>Container withdraw fee</dt><dd>${feeOkb != null ? feeOkb + " OKB / withdraw" : opened ? "unknown" : `open first: ${openOkb ?? "?"} OKB once`}</dd>
      <dt>Holder</dt><dd>${short(holder)}${isHolder ? " (you)" : ""}</dd>
    </dl>
    ${lp ? `<div class="route"><h4>LP fees from the pool</h4>
      <p>Earned but not yet collected: ${num(units(lp.quote, q.dec), 6)} ${esc(q.sym)} and ${num(units(lp.token, 18), 4)} ${esc(t.sym)} (whole pool share, before the split). Collecting adds the creator share to Claimable above. Anyone can collect.</p>
      <button class="btn block" id="lp-collect" ${lpOwed ? "" : "disabled"}>${lpOwed ? "Collect LP fees" : "Nothing to collect yet"}</button></div>` : ""}
    <div class="route ${recDirect ? "rec" : ""}"><h4>Claim to your wallet ${recDirect ? '<span class="tag">RECOMMENDED</span>' : ""}</h4>
      <p>Direct holder claim. Gas only, paid now to the Circuit's current holder.${recDirect ? " Best for small amounts: the Container's fees would eat a large share." : ""}</p>
      <button class="btn block" id="cl-direct" ${isHolder ? "" : "disabled"}>${isHolder ? "Claim to wallet" : "Holder only"}</button></div>
    <div class="route ${recDirect ? "" : "rec"}"><h4>Send to the Container ${recDirect ? "" : '<span class="tag">RECOMMENDED</span>'}</h4>
      <p>Fees stay with the Circuit NFT (they move with it on sale). Withdrawing later costs ${feeOkb != null ? feeOkb + " OKB per withdraw" : "the TapeOut withdraw fee"}${opened ? "" : ` plus a one-time ${openOkb ?? "?"} OKB open`}.</p>
      <button class="btn block" id="cl-cont" ${isHolder ? "" : "disabled"}>${isHolder ? "Claim to Container" : "Holder only"}</button>
      ${opened ? "" : `<button class="btn block" id="ct-open" style="margin-top:8px" ${openFee != null ? "" : "disabled"}>Open the Container (${openOkb ?? "?"} OKB, anyone can pay)</button>`}
      ${withdrawable.map((r, i) => `<button class="btn block" data-wd="${i}" style="margin-top:8px" ${isHolder ? "" : "disabled"}>${isHolder ? `Withdraw ${num(units(r.cb, r.dec), 6)} ${esc(r.sym)} to wallet (${feeOkb ?? "?"} OKB fee)` : "Holder only"}</button>`).join("")}
    </div>
    <div class="note">Fees arrive as ${isBem(L.quote) ? "BEM" : "WOKB (wrapped OKB)"} plus the launch token, not native OKB.</div>`;
  const claim = (toHolder) => sendTx(toHolder ? "Claim to wallet" : "Claim to Container", async (s) => {
    // One transaction per vault and asset, each confirmed before the next, so the signature count on screen is true.
    const jobs = [];
    for (const r of rows) {
      if (r.pa > 0n) jobs.push([C(p.addr, ABI.pad, s), r]);
      if (r.la > 0n) jobs.push([C(p.locker, ABI.locker, s), r]);
    }
    if (!jobs.length) throw new Error("nothing to claim");
    let tx;
    for (let i = 0; i < jobs.length; i++) {
      toast(`Signature ${i + 1} of ${jobs.length}: claim ${jobs[i][1].sym}`);
      if (tx) await tx.wait();
      tx = await jobs[i][0].claimCreator(L.container, jobs[i][1].a, toHolder);
    }
    return tx;
  });
  if (isHolder) { $("#cl-direct", el).onclick = () => claim(true); $("#cl-cont", el).onclick = () => claim(false); }
  const col = $("#lp-collect", el);
  if (col && lpOwed) col.onclick = () => sendTx("Collect LP fees", (s) => C(p.locker, ABI.locker, s).collect(positionId));
  const op = $("#ct-open", el);
  if (op && openFee != null) op.onclick = () => sendTx("Open Container", (s) => C(A.OPENER, ABI.opener, s).open(L.circuitNft, L.circuitId, { value: openFee }));
  if (isHolder) el.querySelectorAll("[data-wd]").forEach((b) => b.onclick = () => {
    const r = withdrawable[+b.dataset.wd];
    const xfer = new E.Interface(["function transfer(address,uint256)"]).encodeFunctionData("transfer", [state.account, r.cb]);
    sendTx(`Withdraw ${r.sym}`, async (s) => {
      const now = await containerState(L.container, state.account); // the fee is TapeOut's and can change: read it at send time
      if (now.state !== "open" || now.fee == null) throw new Error("the Container isn't ready to withdraw");
      return C(L.container, ABI.container, s).execute(r.a, 0, xfer, 0, { value: now.fee });
    });
  });
}

// ---- taped-out tokens trade in their v4 pool through Universal Router 2.1.2. OKB launches pay and receive native OKB.
function renderPoolTrade(box, L, grad) {
  const cfg = L.cfg, qd = cfg.dec, okbQ = !isBem(L.quote), qName = okbQ ? "OKB" : "BEM", z = E.AbiCoder.defaultAbiCoder();
  let side = "buy", last = null, seq = 0;
  box.innerHTML = `<h3>Trade <small>Uniswap v4 pool · taped out</small></h3>
    <div class="trade-tabs"><button class="buy on" data-s="buy">Buy</button><button class="sell" data-s="sell">Sell</button></div>
    <div class="field"><label><span id="inlab">You pay (${qName})</span><span id="bal"></span></label><input id="amt" inputmode="decimal" placeholder="0.0"></div>
    <dl class="kv" id="pv"><dt>You receive</dt><dd>–</dd></dl>
    <button class="btn hub block" id="go">${state.account ? "Buy " + esc(L.symbol) : "Connect wallet"}</button>
    <div class="note">Swaps go through Uniswap's Universal Router into this launch's locked-liquidity pool. Slippage limit 1%.</div>
    <dl class="kv"><dt>Pool</dt><dd>${L.poolId ? short(L.poolId) : "–"}</dd><dt>Locked position</dt><dd>${grad ? "#" + grad.positionId : "–"}</dd>
      <dt>Hook</dt><dd><a href="${EXPLORER}/address/${state.pad.hook}" target="_blank" rel="noopener">${short(state.pad.hook)}</a></dd>
      <dt>Locker</dt><dd><a href="${EXPLORER}/address/${state.pad.locker}" target="_blank" rel="noopener">${short(state.pad.locker)}</a></dd></dl>
    ${grad ? `<a class="btn block" href="${EXPLORER}/tx/${grad.tx}" target="_blank" rel="noopener">Graduation tx ↗</a>` : ""}`;
  const amt = $("#amt", box), pv = $("#pv", box), go = $("#go", box);
  const dirs = () => side === "buy" ? { tokenIn: L.quote, tokenOut: L.token, decIn: qd, decOut: 18, outName: L.symbol } : { tokenIn: L.token, tokenOut: L.quote, decIn: 18, decOut: qd, outName: qName };
  async function preview() {
    const mine = ++seq, v = amt.value.trim(); last = null;
    if (!v || !(+v > 0)) { pv.innerHTML = `<dt>You receive</dt><dd>–</dd>`; return; }
    try {
      const d = dirs(), amountIn = E.parseUnits(v, d.decIn);
      const key = await C(state.pad.graduator, ABI.graduator).poolKey(L.token, L.quote);
      const k = [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks];
      const zeroForOne = d.tokenIn.toLowerCase() === key.currency0.toLowerCase();
      const [out] = await C(A.QUOTER, ABI.quoter).quoteExactInputSingle.staticCall([k, zeroForOne, amountIn, "0x"]);
      if (mine !== seq) return;
      last = { ...d, key, amountIn, minOut: (out * 99n) / 100n };
      pv.innerHTML = `<dt>You receive</dt><dd>~${num(units(out, d.decOut), 6)} ${esc(d.outName)}</dd><dt>Minimum</dt><dd>${num(units(last.minOut, d.decOut), 6)} ${esc(d.outName)}</dd>`;
    } catch (e) { if (mine === seq) pv.innerHTML = `<dt>Preview</dt><dd>${esc(e.shortMessage || "unavailable")}</dd>`; }
  }
  async function balances() {
    if (!state.account) return;
    const b = side === "buy" ? (okbQ ? await rp.getBalance(state.account) : await C(L.quote, ABI.erc20).balanceOf(state.account)) : await C(L.token, ABI.erc20).balanceOf(state.account);
    $("#bal", box).textContent = "balance " + num(units(b, side === "buy" ? qd : 18), 4);
    go.textContent = (side === "buy" ? "Buy " : "Sell ") + L.symbol;
  }
  box.querySelectorAll(".trade-tabs button").forEach((b) => b.onclick = () => {
    side = b.dataset.s; box.querySelectorAll(".trade-tabs button").forEach((x) => x.classList.toggle("on", x === b));
    $("#inlab", box).textContent = side === "buy" ? `You pay (${qName})` : `You sell (${L.symbol})`;
    amt.value = ""; last = null; seq++; pv.innerHTML = `<dt>You receive</dt><dd>–</dd>`; balances();
  });
  amt.oninput = () => { last = null; seq++; clearTimeout(amt._t); amt._t = setTimeout(preview, 250); };
  balances();
  go.onclick = async () => {
    if (!state.account) { await connect(); balances(); return; }
    if (!last) { toast(amt.value.trim() ? "Updating the quote, try again in a moment" : "Enter an amount"); return; }
    const o = last, native = okbQ ? (side === "buy" ? "in" : "out") : null;
    sendTx(side === "buy" ? "Buy" : "Sell", async (s) => {
      const payingNative = native === "in";
      if (!payingNative) { // the router pulls ERC-20s through Permit2: token -> Permit2, then Permit2 -> router, each only if needed
        const t = C(o.tokenIn, ABI.erc20, s), pm = C(A.PERMIT2, ABI.permit2, s), expiry = Math.floor(Date.now() / 1000) + 1800;
        const needT = (await t.allowance(state.account, A.PERMIT2)) < o.amountIn;
        const [allowed, exp] = await pm.allowance(state.account, o.tokenIn, A.UR);
        const needP = allowed < o.amountIn || Number(exp) < Date.now() / 1000 + 60;
        const total = (needT ? 1 : 0) + (needP ? 1 : 0) + 1; let n = 1;
        if (needT) { toast(`Signature ${n++} of ${total}: allow Permit2`); await (await t.approve(A.PERMIT2, o.amountIn)).wait(); }
        if (needP) { toast(`Signature ${n++} of ${total}: allow the router`); await (await pm.approve(o.tokenIn, A.UR, o.amountIn, expiry)).wait(); }
        toast(`Signature ${n} of ${total}: swap`);
      }
      const c = encodeSwap(z, { key: o.key, tokenIn: o.tokenIn, tokenOut: o.tokenOut, amountIn: o.amountIn, minOut: o.minOut, native });
      return C(A.UR, ABI.ur, s).execute(c.commands, c.inputs, Math.floor(Date.now() / 1000) + 1200, { value: c.value });
    });
  };
}

// The contract counts bytes, not characters (limits read from CurvePad; pre-v3 pads have none, so 64/16 applies here too).
function nameLimitError(name, sym) {
  if (byteLength(name) > state.pad.maxName) return `Name is too long: ${byteLength(name)} of ${state.pad.maxName} bytes (emoji and non-Latin letters count as several)`;
  if (byteLength(sym) > state.pad.maxSymbol) return `Ticker is too long: ${byteLength(sym)} of ${state.pad.maxSymbol} bytes`;
  return null;
}

async function viewLaunchAdvanced() {
  const p = state.pad;
  const opt = (q) => { const c = p.cfg[q.toLowerCase()]; const u = quoteUsd(q); return { c, u }; };
  const b = opt(p.bem);
  $("#app").innerHTML = `
  <div class="tp-head"><div><div class="eyebrow"><a href="#/launch" style="text-decoration:none">← Launch</a> · Advanced</div><h1>Launch from any TapeOut Circuit</h1>
    <p class="lede" style="margin:10px 0 0">You must hold the TapeOut Circuit. The token's Container is that Circuit's ERC-6551 account: it earns 50% of every fee, forever, and moves with the NFT.</p></div></div>
  <div class="cols">
    <div class="card"><div class="form">
      <div class="two">
        <div class="field"><label>Circuit collection</label><input id="nft" class="mono" value="${A.NANDOUT}" style="font-size:13px"></div>
        <div class="field"><label>Circuit ID</label><input id="cid" inputmode="numeric" placeholder="e.g. 1"></div>
      </div>
      <div id="circ-check" class="note">Enter a Circuit to check provenance and ownership on chain.</div>
      <div class="two">
        <div class="field"><label>Token name</label><input id="name" placeholder="Circuit Token" maxlength="64"></div>
        <div class="field"><label>Symbol</label><input id="sym" placeholder="CIRC" maxlength="16" style="text-transform:uppercase"></div>
      </div>
      <div class="field"><label>Quote asset</label><select id="quote">
        <option value="${p.wokb}">OKB / WOKB (default)</option><option value="${p.bem}">BEM · volatile quote</option></select></div>
      <div id="vol" class="note vol" hidden>BEM is a volatile quote: the tape-out target is fixed in BEM (${num(units(b.c.raise, 8), 2)} BEM, ≈ ${usd(units(b.c.raise, 8) * b.u)} today), so the USD market caps move with BEM's price.</div>
      <div class="field"><label>Dev-buy (optional)</label><input id="dev" inputmode="decimal" placeholder="0.0"></div>
      <button class="btn hub block" id="launch">Connect wallet</button>
    </div></div>
    <div class="card"><h3>What you get <small>from CurvePad</small></h3><dl class="kv" id="spec"></dl>
      <div class="note">Nothing is sent until you press Launch and sign in your wallet.</div></div>
  </div>`;
  const spec = () => {
    const q = $("#quote").value || p.wokb, { c, u } = opt(q), T = p.totalTokens;
    $("#vol").hidden = !isBem(q);
    $("#spec").innerHTML = `<dt>Supply</dt><dd>${num(T, 0)}</dd><dt>On the curve</dt><dd>${num(units(c.cs, 18), 1)}</dd>
      <dt>Launch MC</dt><dd>${usd(c.p0 * T * u)}</dd><dt>Tape-out MC</dt><dd>${usd(c.pEnd * T * u)}</dd>
      <dt>Tape-out raise</dt><dd>${num(units(c.raise, c.dec), 2)} ${c.sym}</dd><dt>LP locked at tape-out</dt><dd>${num(units(c.lp, 18), 1)} tokens</dd>
      <dt>Anti-snipe</dt><dd>${p.guard} blocks, ${num(units(p.maxEarly, 18), 1)}/block</dd>`;
  };
  $("#quote").onchange = spec; spec();
  if (state.account) $("#launch").textContent = "Launch";
  const check = async () => {
    const nft = $("#nft").value.trim(), id = $("#cid").value.trim(), el = $("#circ-check");
    if (!E.isAddress(nft) || id === "") return;
    try {
      const [cpu, owner] = await Promise.all([C(p.factory, ABI.factory).isCPU(nft), C(nft, ABI.nft).ownerOf(id)]);
      const cont = await C(p.registry, ABI.registry).account(p.containerImpl, E.ZeroHash, CHAIN_ID, nft, id);
      const mine = state.account && owner.toLowerCase() === state.account.toLowerCase();
      el.className = "note " + (cpu && mine ? "ok" : "warn");
      el.innerHTML = `${cpu ? "TapeOut provenance ✓" : "Not a TapeOut processor ✗"} · holder ${short(owner)}${mine ? " (you)" : state.account ? " (not you)" : ""} · Container ${short(cont)}`;
    } catch (e) { el.className = "note warn"; el.textContent = "Circuit not found: " + (e.shortMessage || e.message).slice(0, 80); }
  };
  $("#nft").onchange = check; $("#cid").oninput = () => { clearTimeout(check._t); check._t = setTimeout(check, 300); };
  $("#launch").onclick = async () => {
    if (!state.account) { await connect(); $("#launch").textContent = "Launch"; check(); return; }
    const nft = $("#nft").value.trim(), id = $("#cid").value.trim(), name = $("#name").value.trim(), sym = $("#sym").value.trim().toUpperCase();
    const q = $("#quote").value, dev = $("#dev").value.trim();
    if (!E.isAddress(nft) || !id || !name || !sym) { toast("Fill in Circuit, name and symbol"); return; }
    const lim = nameLimitError(name, sym);
    if (lim) { toast(lim); return; }
    const c = p.cfg[q.toLowerCase()];
    sendTx("Launch", async (s) => {
      const pad = C(p.addr, ABI.pad, s);
      if (!isBem(q)) return pad.createLaunch(nft, id, name, sym, "", q, 0, 0, { value: dev ? E.parseUnits(dev, 18) : 0n });
      const amt = dev ? E.parseUnits(dev, c.dec) : 0n;
      if (amt > 0n) { const t = C(q, ABI.erc20, s); if ((await t.allowance(state.account, p.addr)) < amt) await (await t.approve(p.addr, amt)).wait(); }
      return pad.createLaunch(nft, id, name, sym, "", q, amt, 0);
    });
  };
}


// ---------------------------------------------------------------- launch flow: Pick a Nand -> (mint) -> details -> confirm
const ONE_NAND = "0x00000002000003"; // a Nand: one NAND gate, NAND(in0, in1), nIn=2, nOut=1
const flow = { step: 1, sel: null, name: "", sym: "", img: null, imageURI: "", quote: null, dev: "" };

// Centre-crop to a square (max 1024 px). Square uploads pass through untouched (keeps GIF animation).
async function squareCrop(file) {
  const bmp = await createImageBitmap(file);
  if (bmp.width === bmp.height && bmp.width <= 1024) { bmp.close?.(); return file; }
  const side = Math.min(bmp.width, bmp.height), out = Math.min(side, 1024);
  const c = document.createElement("canvas"); c.width = c.height = out;
  c.getContext("2d").drawImage(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side, 0, 0, out, out);
  bmp.close?.();
  const type = file.type === "image/jpeg" ? "image/jpeg" : "image/png";
  return new Promise((res, rej) => c.toBlob((b) => b ? res(b) : rej(new Error("crop failed")), type, 0.92));
}

async function nandoutFacts() {
  const n = C(A.NANDOUT, ABI.nandout);
  // tapeout does `circuitId = ++nextId`, so nextId() is the last minted id.
  const [tAddr, lastId, tapeFee] = await Promise.all([n.transistors(), n.nextId(), n.TAPEOUT_FEE()]);
  const t = C(tAddr, ABI.transistors);
  const [price, protoFee, cap, minted] = await Promise.all([t.mintPrice(), t.protocolFee(), t.supplyCap(), t.minted()]);
  const held = state.account ? await t.balanceOf(state.account, 0) : 0n; // spare NAND transistors skip the mint tx
  const mintCost = (held > 0n ? 0n : price + protoFee) + tapeFee;
  return { tAddr, lastId: Number(lastId), nextMintId: nextNandId(lastId), tapeFee, price, protoFee, cap, minted, held, mintCost, open: minted + 1n <= cap };
}

async function ownersOf(ids) { // one eth_call per 150 ids through Multicall3
  const iface = new E.Interface(ABI.nandout), mc = C(A.MULTICALL3, ABI.multicall), out = {};
  for (let i = 0; i < ids.length; i += 150) {
    const chunk = ids.slice(i, i + 150);
    const res = await mc.aggregate3(chunk.map((id) => ({ target: A.NANDOUT, allowFailure: true, callData: iface.encodeFunctionData("ownerOf", [id]) })));
    res.forEach((r, j) => { if (r.success) out[chunk[j]] = iface.decodeFunctionResult("ownerOf", r.returnData)[0]; });
  }
  return out;
}

async function launchedNandIds(ids) { // CurvePad.isLaunched(Nandout, id): permanent, one launch per Circuit (SPEC A8)
  const iface = new E.Interface(ABI.pad), mc = C(A.MULTICALL3, ABI.multicall), s = new Set();
  for (let i = 0; i < ids.length; i += 150) {
    const chunk = ids.slice(i, i + 150);
    const res = await mc.aggregate3(chunk.map((id) => ({ target: state.pad.addr, allowFailure: true,
      callData: iface.encodeFunctionData("isLaunched", [A.NANDOUT, id]) })));
    res.forEach((r, j) => { if (r.success && iface.decodeFunctionResult("isLaunched", r.returnData)[0]) s.add(chunk[j]); });
  }
  return s;
}

function stepsBar() {
  const names = ["Pick a Nand", "Token", "Confirm"];
  const cur = flow.step;
  return `<div class="steps">${names.map((n, i) => `<span class="${i + 1 === cur ? "on" : i + 1 < cur ? "done" : ""}">${i + 1 < cur ? "✓ " : ""}${i + 1} · ${n}</span>`).join("")}</div>`;
}

async function viewLaunch() {
  if (flow.step === 1) return stepPick();
  if (flow.step === 2) return stepDetails();
  return stepConfirm();
}

async function stepPick() {
  $("#app").innerHTML = `<div class="flow">${stepsBar()}<h2>Pick a Nand</h2>
    <p class="sub">Your token is wired to one Nandout circuit. Half of every fee goes to that Nand's Container, forever.</p>
    <div id="nandlist" class="muted mono">Reading Nandout…</div></div>`;
  const f = await nandoutFacts();
  const okb = state.prices.okbUsd;
  let rows = [];
  if (state.account) {
    const ids = nandIds(f.lastId);
    const owners = await ownersOf(ids);
    const me = state.account.toLowerCase();
    const mine = ids.filter((id) => owners[id]?.toLowerCase() === me);
    const launched = await launchedNandIds(mine);
    rows = mine
      .map((id) => ({ id, status: launched.has(id) ? "Launched" : "Owned" }))
      .sort((a, b) => (a.status === "Launched") - (b.status === "Launched") || a.id - b.id);
  }
  const mintRow = f.open ? `<button class="nand mint ${flow.sel?.kind === "mint" ? "sel" : ""}" data-k="mint">
      <span class="mk">${flow.sel?.kind === "mint" ? "✓" : ""}</span><span class="n">+ Mint</span>
      <span class="info">the next Nand (#${f.nextMintId}) · ~${E.formatEther(f.mintCost)} OKB + gas (${usd(units(f.mintCost, 18) * okb)})</span>
      <span class="st">Available</span></button>` : "";
  const rowHtml = (r) => {
    const on = flow.sel?.kind === "owned" && flow.sel.id === r.id, dis = r.status === "Launched";
    return `<button class="nand ${on ? "sel" : ""}" data-k="owned" data-id="${r.id}" ${dis ? "disabled" : ""}>
      <span class="mk">${on ? "✓" : ""}</span><span class="n">#${r.id}</span><span class="info"></span>
      <span class="st ${r.status === "Owned" ? "owned" : ""}">${r.status}</span></button>`;
  };
  const list = $("#nandlist");
  list.className = "";
  list.innerHTML = `${rows.length > 12 ? `<div class="jump"><input id="jump" inputmode="numeric" placeholder="Jump to #"></div>` : ""}
    <div class="nands">${mintRow}${rows.map(rowHtml).join("")}</div>
    ${!state.account ? `<p class="muted" style="margin:14px 0">Connect your wallet to see the Nands you hold.</p>`
      : rows.length ? "" : `<p class="muted" style="margin:14px 0">You don't hold a Nand yet. Mint one above.</p>`}
    <div class="pinned"><button class="btn hub block" id="cont" ${flow.sel || !state.account ? "" : "disabled"}>${state.account ? "Continue" : "Connect wallet"}</button></div>
    <details class="adv"><summary>Advanced: launch from another TapeOut circuit</summary>
      <p class="muted" style="font-size:13px">Any TapeOut processor's circuit works if you hold it. <a href="#/launch/advanced">Open the manual circuit form →</a></p></details>`;
  list.querySelector(".nands").onclick = (e) => {
    const b = e.target.closest(".nand"); if (!b || b.disabled) return;
    flow.sel = b.dataset.k === "mint" ? { kind: "mint", facts: f } : { kind: "owned", id: Number(b.dataset.id) };
    list.querySelectorAll(".nand").forEach((x) => { const on = x === b; x.classList.toggle("sel", on); x.querySelector(".mk").textContent = on ? "✓" : ""; });
    $("#cont").disabled = false;
  };
  const j = $("#jump");
  if (j) j.oninput = () => {
    const v = j.value.replace(/\D/g, "");
    list.querySelectorAll(".nand[data-id]").forEach((x) => { x.hidden = v !== "" && !x.dataset.id.startsWith(v); });
  };
  $("#cont").onclick = async () => {
    if (!state.account) { await connect(); return route(); }
    if (!flow.sel) return;
    flow.step = 2; // minting happens in the final run, as signatures 1-2 of one progress bar
    route();
  };
}

async function stepDetails() {
  const p = state.pad;
  flow.quote = flow.quote || p.wokb;
  const b = p.cfg[p.bem.toLowerCase()];
  $("#app").innerHTML = `<div class="flow">${stepsBar()}<h2>Token</h2>
    <p class="sub">Wired to <b class="mono" style="color:var(--ink)">${flow.sel.kind === "mint" ? "the next Nand (minted when you launch)" : "Nand #" + flow.sel.id}</b>. <button id="change" class="linklike muted">Change</button></p>
    <div class="form">
      <div class="imgpick"><div class="prev" id="prev"></div>
        <div><label class="btn" for="img">Choose image</label><input type="file" id="img" accept="image/png,image/jpeg,image/webp,image/gif" hidden>
        <div class="muted" style="font-size:12px;margin-top:6px" id="imgstat">PNG, JPG, WebP or GIF, max 2 MB. Cropped to a square and pinned to IPFS.</div></div></div>
      <div class="two">
        <div class="field"><label>Name</label><input id="name" maxlength="64" placeholder="My Token" value="${esc(flow.name)}"></div>
        <div class="field"><label>Ticker</label><input id="sym" maxlength="16" placeholder="TICKER" style="text-transform:uppercase" value="${esc(flow.sym)}"></div>
      </div>
      <div><div class="muted mono" style="font-size:11.5px;margin-bottom:6px">QUOTE</div><div class="qopts">
        <button class="qopt" data-q="${p.wokb}"><b>OKB</b><small>default · paid as WOKB</small></button>
        <button class="qopt" data-q="${p.bem}"><b>BEM</b><small class="mono" style="color:var(--blue-ink)">volatile quote</small></button></div></div>
      <div id="vol" class="note vol" hidden>BEM is a volatile quote: the tape-out target is fixed at ${num(units(b.raise, 8), 2)} BEM (≈ ${usd(units(b.raise, 8) * state.prices.bemUsd)} today), so market caps in USD move with BEM.</div>
      <div class="field"><label><span>Dev buy (optional)</span><span id="devu"></span></label><input id="dev" inputmode="decimal" placeholder="0.0" value="${esc(flow.dev)}"></div>
    </div>
    <div class="pinned"><button class="btn hub block" id="next">Review</button><button class="btn ghost block" id="back" style="margin-top:8px">Back</button></div></div>`;
  const prev = $("#prev");
  const paint = () => { prev.style.backgroundImage = flow.img ? `url(${flow.img})` : ""; prev.textContent = flow.img ? "" : ($("#sym").value || "?").slice(0, 4).toUpperCase(); prev.style.background = flow.img ? "" : "var(--panel-2)"; if (flow.img) prev.style.backgroundImage = `url(${flow.img})`; };
  const qsel = () => {
    document.querySelectorAll(".qopt").forEach((x) => x.classList.toggle("on", x.dataset.q === flow.quote));
    $("#vol").hidden = !isBem(flow.quote);
    $("#devu").textContent = isBem(flow.quote) ? "BEM" : "OKB";
  };
  document.querySelectorAll(".qopt").forEach((x) => x.onclick = () => { flow.quote = x.dataset.q; qsel(); });
  $("#img").onchange = async (e) => {
    const file = e.target.files[0]; if (!file) return;
    const stat = $("#imgstat");
    if (!/^image\/(png|jpeg|webp|gif)$/.test(file.type)) { toast("PNG, JPG, WebP or GIF only"); return; }
    if (file.size > 2 * 1024 * 1024) { toast("Max 2 MB"); return; }
    try {
      stat.textContent = "Cropping…";
      const blob = await squareCrop(file);
      flow.img = URL.createObjectURL(blob); flow.imageURI = ""; paint();
      stat.textContent = "Uploading to IPFS…";
      const fd = new FormData(); fd.append("file", blob, "logo");
      const r = await fetch(PIN_ENDPOINT, { method: "POST", body: fd });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || !safeImage(j.uri)) throw new Error(j.error || `upload failed (${r.status})`);
      flow.imageURI = j.uri;
      stat.textContent = "Pinned ✓ " + j.uri.slice(0, 22) + "…";
    } catch (err) { flow.imageURI = ""; stat.textContent = "Logo not uploaded: " + (err.message || err).toString().slice(0, 80) + ". The initials avatar will be used."; }
  };
  $("#sym").oninput = paint;
  $("#change").onclick = () => { flow.step = 1; route(); };
  $("#back").onclick = () => { flow.step = 1; route(); };
  $("#next").onclick = () => {
    if (flow.img && !flow.imageURI && !confirm("The logo hasn't finished uploading. Continue with the initials avatar?")) return;
    flow.name = $("#name").value.trim(); flow.sym = $("#sym").value.trim().toUpperCase(); flow.dev = $("#dev").value.trim();
    if (!flow.name || !flow.sym) { toast("Name and ticker are required"); return; }
    const lim = nameLimitError(flow.name, flow.sym);
    if (lim) { toast(lim); return; }
    if (flow.dev && !(+flow.dev >= 0)) { toast("Dev buy must be a number"); return; }
    flow.step = 3; route();
  };
  qsel(); paint();
}

async function stepConfirm() {
  const p = state.pad;
  flow.quote = flow.quote || p.wokb;
  const c = p.cfg[flow.quote.toLowerCase()], qU = quoteUsd(flow.quote), T = p.totalTokens;
  const bem = isBem(flow.quote), dev = flow.dev ? +flow.dev : 0, minting = flow.sel.kind === "mint";
  const devWei = dev ? E.parseUnits(flow.dev, c.dec) : 0n;
  let devOut = 0n; // dev-buy preview on a fresh curve: tokensOut = vT0 - vQ0*vT0/(vQ0 + net), net = 99% of gross
  if (devWei > 0n) { const net = devWei - devWei / 100n; devOut = c.vT0 - (c.vQ0 * c.vT0) / (c.vQ0 + net); if (devOut > c.cs) devOut = c.cs; }
  const f = minting ? await nandoutFacts() : null;
  const gp = (await rp.getFeeData()).gasPrice || 0n;
  const gasOkb = units(gp * (900000n + (minting ? 450000n : 0n)), 18); // createLaunch ≈ 760k gas (+ dev buy); mint+tapeout ≈ 300k
  const mintOkb = minting ? units(f.mintCost, 18) : 0;
  const totalOkb = (bem ? 0 : dev) + mintOkb + gasOkb;
  // Every signature this run needs, in order. A BEM dev buy needs an approve first unless one is already in place.
  const needApprove = bem && devWei > 0n && state.account && (await C(flow.quote, ABI.erc20).allowance(state.account, p.addr)) < devWei;
  const sigs = [
    ...(minting && f.held === 0n ? [{ id: "buy", t: "Buy 1 NAND transistor" }] : []),
    ...(minting ? [{ id: "tape", t: "Tape out your Nand" }] : []),
    ...(needApprove ? [{ id: "approve", t: "Approve BEM for the dev buy" }] : []),
    { id: "launch", t: `Launch $${flow.sym}` },
  ];
  const L = { token: "0x" + "0".repeat(40), symbol: flow.sym, imageURI: flow.imageURI };
  $("#app").innerHTML = `<div class="flow">${stepsBar()}<h2>Confirm launch</h2>
    <div class="sheet">
      <div class="warnline"><span class="pill" style="color:var(--red);border-color:rgba(194,99,90,.45)">Irreversible</span>${bem ? '<span class="pill vol">BEM · volatile quote</span>' : ""}</div>
      <div class="tp-head" style="padding:0 0 6px;gap:14px">${flow.img ? `<div class="av" style="background:var(--panel-2)"><img src="${esc(flow.img)}" alt=""></div>` : avatar(L)}
        <div><div style="font-size:20px;color:var(--ink);font-weight:600">${esc(flow.name)} <span class="muted">$${esc(flow.sym)}</span></div>
        <div class="muted mono" style="font-size:12.5px">${minting ? "wired to the next Nand (minted first)" : "wired to Nand #" + flow.sel.id}</div></div></div>
      <div class="note warn"><b>Each Circuit can launch one token, ever. This uses it up.</b></div>
      <dl class="kv">
        <dt>Quote</dt><dd>${bem ? "BEM (volatile)" : "OKB (WOKB)"}</dd>
        <dt>Launch market cap</dt><dd>${usd(c.p0 * T * qU)}</dd>
        <dt>Tape-out at</dt><dd>${num(units(c.raise, c.dec), 2)} ${c.sym} raised · ${usd(c.pEnd * T * qU)} MC</dd>
        ${minting ? `<dt>Mint the Nand</dt><dd>${E.formatEther(f.mintCost)} OKB</dd>` : ""}
        <dt>Dev buy</dt><dd>${dev ? `${esc(flow.dev)} ${bem ? "BEM" : "OKB"} → ~${num(units(devOut, 18), 2)} ${esc(flow.sym)}` : "none"}</dd>
        ${dev ? `<dt>Shown publicly</dt><dd>Dev holds ${(units(devOut, 18) / T * 100).toFixed(2)}%</dd>` : ""}
        <dt>Logo</dt><dd>${flow.imageURI ? "pinned to IPFS" : "initials avatar"}</dd>
        <dt>Network fees (est.)</dt><dd>~${gasOkb.toPrecision(2)} OKB</dd>
        <dt><b style="color:var(--ink)">Total cost</b></dt><dd><b style="color:var(--ink)">${bem && dev ? `${esc(flow.dev)} BEM + ` : ""}~${totalOkb.toPrecision(3)} OKB · ${usd(totalOkb * state.prices.okbUsd + (bem ? dev * state.prices.bemUsd : 0))}</b></dd>
      </dl>
      <div class="run" id="run">${sigs.map((g, k) => `<div class="sig" data-k="${g.id}"><span class="dotk">${k + 1}</span><span>Signature ${k + 1} of ${sigs.length}: ${esc(g.t)}</span><span class="st mono"></span></div>`).join("")}
        <div class="bar" style="margin-top:10px"><div id="runbar" style="width:0%"></div></div></div>
      <label class="check"><input type="checkbox" id="ack"><span>I understand this can't be undone and uses up this Circuit's one launch.</span></label>
      <button class="btn hub block" id="go" disabled>${minting ? `Mint Nand & launch ${esc(flow.sym)}` : `Launch ${esc(flow.sym)}`}</button>
      <button class="btn ghost block" id="back" style="margin-top:8px">Back</button>
      <div id="runlog" class="mono muted" style="font-size:12px;margin-top:10px"></div>
    </div></div>`;
  $("#ack").onchange = (e) => { $("#go").disabled = !e.target.checked; };
  $("#back").onclick = () => { flow.step = 2; route(); };
  const done = new Set();
  const mark = (sig, st, txt) => {
    const el = document.querySelector(`.sig[data-k="${sig}"]`); if (!el) return;
    el.className = "sig " + st; el.querySelector(".st").textContent = txt || "";
    if (st === "done") done.add(sig);
    $("#runbar").style.width = `${((done.size + (st === "done" ? 0 : 0.5)) / sigs.length) * 100}%`;
  };
  let current = null; // the signature in progress, for the failure mark
  const step = (sig, txt) => { current = sig; mark(sig, "on", txt); };
  $("#go").onclick = async () => {
    const go = $("#go"); go.disabled = true; $("#back").disabled = true;
    const log = (m) => { $("#runlog").innerHTML += esc(m) + "<br>"; };
    try {
      const s = await signer();
      // Read what is still to do on every press: a retry must never buy or tape out again.
      if (flow.sel.kind === "mint") {
        const g = await nandoutFacts();
        if (g.held === 0n) {
          step("buy", "confirm in wallet");
          const tx = await C(g.tAddr, ABI.transistors, s).mint(0, 1, { value: g.price + g.protoFee });
          step("buy", "pending " + short(tx.hash)); await tx.wait();
        }
        mark("buy", "done", "✓");
        step("tape", "confirm in wallet");
        const expected = g.nextMintId;
        const tx2 = await C(A.NANDOUT, ABI.nandout, s).tapeout(ONE_NAND, 2, 1, { value: g.tapeFee });
        step("tape", "pending " + short(tx2.hash));
        const r = await tx2.wait();
        const ni = new E.Interface(ABI.nandout);
        const ev = r.logs.map((l) => { try { return ni.parseLog(l); } catch { return null; } }).find((e) => e?.name === "TapedOut");
        if (!ev) throw new Error("TapedOut event not found");
        const id = Number(ev.args.circuitId); // sequential: if someone minted first, this is simply the next one
        flow.sel = { kind: "owned", id };
        mark("tape", "done", `✓ Nand #${id}`);
        if (id !== expected) log(`Someone minted #${expected} first; your Nand is #${id}.`);
      }
      const id = flow.sel.id;
      const owner = await C(A.NANDOUT, ABI.nandout).ownerOf(id);
      if (owner.toLowerCase() !== state.account.toLowerCase()) throw new Error(`you no longer hold Nand #${id}`);
      if (await p.contract.isLaunched(A.NANDOUT, id)) throw new Error(`Nand #${id} has already launched a token`);
      const pad = C(p.addr, ABI.pad, s);
      const uri = safeImage(flow.imageURI) ? flow.imageURI : "";
      let tx3;
      if (!bem) {
        step("launch", "confirm in wallet");
        tx3 = await pad.createLaunch(A.NANDOUT, id, flow.name, flow.sym, uri, flow.quote, 0, 0, { value: devWei });
      } else {
        if (devWei > 0n) {
          const t = C(flow.quote, ABI.erc20, s);
          if ((await t.allowance(state.account, p.addr)) < devWei) {
            step("approve", "confirm in wallet");
            const ax = await t.approve(p.addr, devWei);
            step("approve", "pending " + short(ax.hash)); await ax.wait();
          }
          mark("approve", "done", "✓");
        }
        step("launch", "confirm in wallet");
        tx3 = await pad.createLaunch(A.NANDOUT, id, flow.name, flow.sym, uri, flow.quote, devWei, 0);
      }
      step("launch", "pending " + short(tx3.hash));
      const r3 = await tx3.wait();
      const ev3 = r3.logs.map((l) => { try { return new E.Interface(ABI.pad).parseLog(l); } catch { return null; } }).find((e) => e?.name === "LaunchCreated");
      mark("launch", "done", "✓ launched");
      toast(`$${flow.sym} is LIVE`, 6000);
      confetti();
      if (ev3) { Object.assign(flow, { step: 1, sel: null, name: "", sym: "", img: null, imageURI: "", dev: "" }); location.hash = "#/t/" + ev3.args.token; }
    } catch (e) {
      if (current) mark(current, "err", "failed");
      log("error: " + (e.shortMessage || e.reason || e.message).slice(0, 180));
      go.disabled = false; $("#back").disabled = false; go.textContent = "Retry";
      if (flow.sel.kind === "owned" && minting) log(`Your Nand #${flow.sel.id} is minted. Retry continues with the launch only.`);
    }
  };
}

async function viewCreator() {
  $("#app").innerHTML = `
  <div class="tp-head"><div><div class="eyebrow">Creator fees</div><h1>Your Circuit's earnings</h1>
  <p class="lede" style="margin:10px 0 0">Pick a launch to see what its Container has earned, the Container's withdraw fee next to its balance, and the cheapest way to take it.</p></div></div>
  <div class="cols"><div class="card"><div class="list" id="mine"></div></div><div class="card" id="creator"><div class="muted">Select a launch.</div></div></div>`;
  const L = state.launches;
  const mine = state.account ? await Promise.all(L.map(async (x) => {
    try { return (await C(x.circuitNft, ABI.nft).ownerOf(x.circuitId)).toLowerCase() === state.account.toLowerCase(); } catch { return false; }
  })) : L.map(() => true);
  const list = L.filter((_, i) => mine[i]);
  $("#mine").innerHTML = list.length ? list.map((x) => `<a class="row" role="button" tabindex="0" data-t="${x.token}" style="grid-template-columns:1fr auto;cursor:pointer">
    <div class="tok">${avatar(x)}<div><b>${esc(x.name)}</b><small>${circuitLabel(x)}</small></div></div>${pills(x)}</a>`).join("")
    : `<div class="empty-state"><b>No launches ${state.account ? "for your Circuits" : "yet"}</b>${state.account ? "" : "Connect to filter by the Circuits you hold."}</div>`;
  $("#mine").onclick = (e) => { const r = e.target.closest("[data-t]"); if (r) renderCreator($("#creator"), L.find((x) => x.token === r.dataset.t)); };
}

// ---------------------------------------------------------------- router
let booted = false;
let HIDE = new Set();
async function loadHideList() { // moderation: token addresses whose logo is replaced by the initials avatar
  try { const r = await fetch(`hidelist.json?t=${Date.now()}`, { cache: "no-store" }); if (r.ok) HIDE = new Set((await r.json()).map((a) => String(a).toLowerCase())); } catch {}
}
async function boot() {
  setBanner();
  await loadHideList(); // before any logo renders, or a hidden logo could flash
  $("#app").innerHTML = `<div style="padding:80px 0" class="muted mono" id="loading">Loading…</div>`;
  const slow = setTimeout(() => { const l = $("#loading"); if (l) l.textContent = "Still loading. The X Layer network is responding slowly."; }, 5000);
  try {
    await loadPad();
    await loadPrices();
    await loadLaunches();
    booted = true;
  } finally { clearTimeout(slow); }
}
async function route() {
  try {
    if (!booted) await boot();
    else { await loadLaunches(); }
    setBanner();
    const h = location.hash.replace(/^#/, "") || "/";
    document.querySelectorAll("nav.links a").forEach((a) => a.classList.toggle("on",
      (a.dataset.nav === "floor" && h === "/") || (a.dataset.nav !== "floor" && h.startsWith("/" + a.dataset.nav))));
    if (h.startsWith("/t/")) await viewToken(h.slice(3));
    else if (h.startsWith("/launch/advanced")) await viewLaunchAdvanced();
    else if (h.startsWith("/launch")) await viewLaunch();
    else if (h.startsWith("/creator")) await viewCreator();
    else await viewFloor();
  } catch (e) {
    console.error(e);
    $("#app").innerHTML = `<div class="empty-state" style="margin-top:40px"><b>Couldn't read the chain</b>${esc(e.shortMessage || e.message)}<br><br><button class="btn" data-reload>Retry</button></div>`;
  }
}
document.addEventListener("click", (e) => { if (e.target.closest("[data-reload]")) location.reload(); });
// Logo gateways: "error" doesn't bubble, so listen in the capture phase.
document.addEventListener("error", (e) => {
  const img = e.target;
  if (!(img instanceof HTMLImageElement) || !img.dataset.rel) return;
  const g = +img.dataset.g + 1;
  if (g < IPFS_GATEWAYS.length) { img.dataset.g = g; img.src = IPFS_GATEWAYS[g] + img.dataset.rel; } else img.remove();
}, true);
$("#connect").onclick = () => connect().then(() => route()).catch((e) => toast(e.shortMessage || e.message));
window.addEventListener("hashchange", () => { if (location.hash !== "#wafer") route(); });
route();
