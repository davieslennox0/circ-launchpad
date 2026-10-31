/* Circ Launchpad by Sarf: static front end. No backend keys, no private keys.
 * Every curve number (constants, progress, targets, prices) is read live from the chain.
 * /data/index-*.json (keyless indexer) is only a list of launch addresses and recent trades; it is re-checked on chain
 * and the page scans forward past its head itself. Transactions are built only when the user presses a button and are
 * signed in the user's own wallet. */
"use strict";
const E = ethers;

const CHAIN_ID = 196;
const RPC = "https://rpc.xlayer.tech";
const EXPLORER = "https://www.oklink.com/x-layer";
const INSTANCES = {
  prod: { pad: "0x45E97E81d50D0c77170D9cb622f9d255768E4827", label: "Mainnet" },
  test: { pad: "0xa66D7020a374BCC3e6424B9075E481617C669057", label: "CIRC-TEST" },
};
const A = {
  USDT0_WOKB_POOL: "0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082",
  BEM_WOKB_POOL: "0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A",
  OPENER: "0x536adD8F30f03b69f6fbF29d425A816A0dC50106",
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
    "function quoteConfig(address) view returns (tuple(uint128 vQuote0,uint128 vToken0,uint128 curveSupply,uint128 lpTokens))",
    "function curves(address) view returns (address quote,uint128 vQuote,uint128 vToken,uint128 realQuote,uint128 tokensLeft,address container,address circuitNft,uint256 circuitId,uint64 launchBlock,uint8 status)",
    "function earlyBlock(address) view returns (uint64 blockNumber,uint192 sold)",
    "function previewBuy(address,uint256) view returns (uint256 tokensOut,uint256 quoteUsed)",
    "function previewSell(address,uint256) view returns (uint256)",
    "function accrued(address,address) view returns (uint256)",
    "function createLaunch(address,uint256,string,string,address,uint256,uint256) payable returns (address)",
    "function buyWithOKB(address,uint256,uint256) payable returns (uint256)",
    "function buy(address,uint256,uint256,uint256) returns (uint256)",
    "function sell(address,uint256,uint256,uint256) returns (uint256)",
    "function graduate(address)",
    "function claimCreator(address,address,bool)",
    "event LaunchCreated(address indexed token,address indexed quote,address indexed circuitNft,uint256 circuitId,address container,address creator)",
  ],
  locker: ["function accrued(address,address) view returns (uint256)", "function claimCreator(address,address,bool)"],
  erc20: [
    "function name() view returns (string)", "function symbol() view returns (string)",
    "function decimals() view returns (uint8)", "function balanceOf(address) view returns (uint256)",
    "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)",
  ],
  nft: ["function ownerOf(uint256) view returns (address)", "function name() view returns (string)"],
  registry: ["function account(address,bytes32,uint256,address,uint256) view returns (address)"],
  factory: ["function isCPU(address) view returns (bool)"],
  opener: ["function FEE() view returns (uint256)", "function open(address,uint256) payable"],
  pool: ["function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)", "function token0() view returns (address)"],
  graduator: ["function poolKey(address,address) view returns (tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks))"],
  stateView: ["function getSlot0(bytes32) view returns (uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)",
    "function getLiquidity(bytes32) view returns (uint128)"],
  container: ["function execute(address,uint256,bytes,uint8) payable returns (bytes)"],
};

const rp = new E.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true, batchMaxCount: 1 });
const C = (addr, abi, runner = rp) => new E.Contract(addr, abi, runner);
const $ = (s, el = document) => el.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const short = (a) => a ? a.slice(0, 6) + "…" + a.slice(-4) : "";
const STATUS = ["Trading", "Complete", "Taped out"];
const STATUS_CLS = ["trading", "complete", "grad"];

const state = {
  inst: localGet("circ.inst") || "prod",
  account: null, signer: null,
  pad: null,       // on-chain pad facts
  prices: null,    // {okbUsd, bemUsd}
  launches: [],    // [{token, ...curve}]
  head: 0,
};

function localGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function localSet(k, v) { try { localStorage.setItem(k, v); } catch {} }

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
function hue(addr) { // stable avatar colour from the token address, drawn from the logo palette
  const pal = ["#EA3680", "#FF7F27", "#22B14C", "#3F48CC", "#880015", "#b8a800"];
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
  const [wokb, bem, locker, hook, protocol, sink, registry, containerImpl, factory, guard, maxEarly, total, graduator] =
    await Promise.all([pad.wokb(), pad.bem(), pad.locker(), pad.hook(), pad.protocol(), pad.sink(), pad.registry(),
      pad.containerImpl(), pad.circuitFactory(), pad.GUARD_BLOCKS(), pad.MAX_EARLY_BUY(), pad.TOTAL_SUPPLY(), pad.graduator()]);
  const [cw, cb] = await Promise.all([pad.quoteConfig(wokb), pad.quoteConfig(bem)]);
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
    addr: inst.pad, contract: pad, graduator, wokb, bem, locker, hook, protocol, sink, registry, containerImpl, factory,
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
    const r = await fetch(`/data/index-${state.inst}.json?t=${Date.now()}`, { cache: "no-store" });
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
        if (!known.has(t)) known.set(t, { token: ev.args.token, block: lg.blockNumber, ts: Date.now() / 1000, trades: [], creator: ev.args.creator });
      }
    } catch {}
  }
  const list = await Promise.all([...known.values()].map((L) => readLaunch(L).catch(() => null)));
  state.launches = list.filter(Boolean).sort((a, b) => b.block - a.block);
}

async function readLaunch(L) {
  const c = await state.pad.contract.curves(L.token);
  if (c.quote === E.ZeroAddress) return null;
  const tok = C(L.token, ABI.erc20);
  const [name, symbol] = await Promise.all([tok.name(), tok.symbol()]);
  const cfg = state.pad.cfg[c.quote.toLowerCase()];
  const sold = cfg.cs - c.tokensLeft;
  let price = units(c.vQuote, cfg.dec) / units(c.vToken, 18);
  let poolId = null;
  if (Number(c.status) === 2) { // taped out: live price from the Uniswap v4 pool, not the closed curve
    const key = await C(state.pad.graduator, ABI.graduator).poolKey(L.token, c.quote);
    poolId = E.keccak256(E.AbiCoder.defaultAbiCoder().encode(["tuple(address,address,uint24,int24,address)"],
      [[key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]]));
    const { sqrtPriceX96 } = await C(A.STATE_VIEW, ABI.stateView).getSlot0(poolId);
    const r = (Number(sqrtPriceX96) / 2 ** 96) ** 2; // raw currency1 per raw currency0
    const tokenIs0 = key.currency0.toLowerCase() === L.token.toLowerCase();
    const raw = tokenIs0 ? r : 1 / r;                 // raw quote per raw token
    price = raw * 10 ** (18 - cfg.dec);
  }
  const qUsd = quoteUsd(c.quote);
  return {
    ...L, token: L.token, name, symbol, quote: c.quote, cfg,
    vQuote: c.vQuote, vToken: c.vToken, realQuote: c.realQuote, tokensLeft: c.tokensLeft,
    container: c.container, circuitNft: c.circuitNft, circuitId: c.circuitId, launchBlock: Number(c.launchBlock),
    status: Number(c.status), poolId,
    progress: Number((sold * 10000n) / cfg.cs) / 100,
    price, mcQuote: price * state.pad.totalTokens, mcUsd: price * state.pad.totalTokens * qUsd,
    raisedUsd: units(c.realQuote, cfg.dec) * qUsd,
  };
}

// ---------------------------------------------------------------- wallet
async function connect() {
  if (!window.ethereum) { toast("No wallet found. Install OKX Wallet or MetaMask."); return null; }
  const bp = new E.BrowserProvider(window.ethereum);
  await bp.send("eth_requestAccounts", []);
  const net = await bp.getNetwork();
  if (Number(net.chainId) !== CHAIN_ID) {
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0xc4" }] });
    } catch (e) {
      if (e.code === 4902) {
        await window.ethereum.request({ method: "wallet_addEthereumChain", params: [{
          chainId: "0xc4", chainName: "X Layer", nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
          rpcUrls: [RPC], blockExplorerUrls: [EXPLORER] }] });
      } else throw e;
    }
  }
  const bp2 = new E.BrowserProvider(window.ethereum);
  state.signer = await bp2.getSigner();
  state.account = await state.signer.getAddress();
  $("#connect").textContent = short(state.account);
  return state.signer;
}
async function signer() { return state.signer || connect(); }
async function sendTx(label, fn) {
  try {
    const s = await signer(); if (!s) return;
    toast(`${label}: confirm in your wallet`);
    const tx = await fn(s);
    toast(`${label}: sent ${short(tx.hash)}`);
    const r = await tx.wait();
    toast(`${label}: ${r.status === 1 ? "confirmed" : "reverted"}`, 6000);
    route();
  } catch (e) {
    toast(`${label}: ${e.shortMessage || e.reason || e.message}`.slice(0, 180), 7000);
  }
}

// ---------------------------------------------------------------- views
function setBanner() {
  const b = $("#banner");
  if (state.inst === "test") {
    b.hidden = false;
    b.firstElementChild.textContent = "Preview data: you're viewing the CIRC-TEST instance (a tiny 0.099 WOKB test curve used for the end-to-end run). Switch to Mainnet for production.";
  } else b.hidden = true;
  document.querySelectorAll("#inst button").forEach((x) => x.classList.toggle("on", x.dataset.inst === state.inst));
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

function avatar(L, cls = "") {
  return `<div class="av ${cls}" style="background:${hue(L.token)}">${esc(L.symbol.slice(0, 4))}</div>`;
}
function pills(L) {
  return `<span class="pill ${STATUS_CLS[L.status]}">${STATUS[L.status]}</span>` +
    (isBem(L.quote) ? `<span class="pill vol" title="BEM-quoted: the graduation target is fixed in BEM, so its USD value moves with BEM's price">BEM · volatile quote</span>` : "");
}

async function viewFloor() {
  const p = state.pad, w = p.cfg[p.wokb.toLowerCase()], bq = p.cfg[p.bem.toLowerCase()];
  const okb = state.prices.okbUsd, bemU = state.prices.bemUsd;
  const L = state.launches;
  const grad = L.filter((x) => x.status === 2).length;
  const slots = 52; // 8x8 grid clipped to a circle
  const cells = [];
  let k = 0;
  for (let r = 0; r < 8; r++) for (let c = 0; c < 8; c++) {
    const dx = c - 3.5, dy = r - 3.5, inside = dx * dx + dy * dy <= 17.5;
    if (!inside) { cells.push(`<div class="die out"></div>`); continue; }
    const x = L[k++];
    if (!x) { cells.push(`<div class="die empty"></div>`); continue; }
    const cls = ["die", "live", x.status === 2 ? "grad" : x.status === 1 ? "complete" : "", isBem(x.quote) ? "bem" : ""].join(" ");
    cells.push(`<a class="${cls}" href="#/t/${x.token}" title="${esc(x.symbol)} · ${x.progress.toFixed(1)}% · ${usd(x.mcUsd)}">
      ${x.status === 2 ? "" : `<div class="fill" style="height:${Math.max(4, x.progress)}%"></div>`}<span class="sym">${esc(x.symbol.slice(0, 5))}</span></a>`);
  }
  void slots;
  const rows = L.map((x) => `<a class="row" href="#/t/${x.token}">
      <div class="tok">${avatar(x)}<div><b>${esc(x.name)}</b><small>$${esc(x.symbol)} · ${circuitLabel(x)}</small></div></div>
      <div class="mono">${usd(x.mcUsd)}<div class="muted" style="font-size:12px">${num(x.mcQuote, 2)} ${x.cfg.sym}</div></div>
      <div class="hide-m"><div class="bar"><div style="width:${x.status ? 100 : x.progress}%"></div></div><small class="mono muted">${x.status ? "100" : x.progress.toFixed(1)}%</small></div>
      <div class="hide-m">${pills(x)}</div>
      <div class="mono muted" style="font-size:12px">${x.ts ? ago(x.ts) : ""}</div></a>`).join("");

  $("#app").innerHTML = `
  <section class="hero">
    <div>
      <div class="eyebrow">Circ Launchpad · X Layer</div>
      <h1>Every token is <em>wired</em> to a circuit.</h1>
      <p class="lede">Launch a fair bonding-curve token from a TapeOut Circuit you hold. Half of every fee flows to that
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
  <div class="section-h" id="wafer"><h2>The wafer <span class="muted mono" style="font-size:13px;font-weight:400">${L.length} launches · ${grad} taped out</span></h2>
    <div class="legend"><span><i style="background:var(--orange)"></i>trading (fill = curve sold)</span><span><i style="background:var(--yellow)"></i>complete</span>
    <span><i style="background:var(--green)"></i>taped out</span><span><i style="background:transparent;box-shadow:inset 0 0 0 1.5px var(--blue)"></i>BEM · volatile quote</span></div></div>
  <div class="wafer-wrap">
    <div class="wafer"><div class="grid">${cells.join("")}</div></div>
    <div>${L.length ? `<div class="list"><div class="row head"><div>Token</div><div>Market cap</div><div class="hide-m">Curve</div><div class="hide-m">Status</div><div>Age</div></div>${rows}</div>`
      : `<div class="empty-state"><b>The wafer is clean.</b>No launches on ${INSTANCES[state.inst].label} yet. ${state.inst === "prod"
        ? `<br><br><button class="btn" onclick="switchInst('test')">See it with preview data</button>` : ""}</div>`}</div>
  </div>`;
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
    <defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#FF7F27"/><stop offset="1" stop-color="#EA3680"/></linearGradient></defs>
    <g stroke="rgba(255,255,255,.06)">${[0, .25, .5, .75, 1].map((f) => `<line x1="${P}" x2="${W - P}" y1="${P + f * (H - 2 * P)}" y2="${P + f * (H - 2 * P)}"/>`).join("")}</g>
    <path d="${d}" fill="none" stroke="#2A2B2E" stroke-width="2"/>
    <path d="${lit}" fill="none" stroke="url(#g)" stroke-width="2.5"/>
    <circle cx="${cx}" cy="${cy}" r="5" fill="#EA3680"/><circle cx="${cx}" cy="${cy}" r="11" fill="none" stroke="rgba(234,54,128,.35)"/>
    <g font-family="IBM Plex Mono" font-size="11" fill="#8B929A">
      <text x="${P}" y="${H - 10}">0</text><text x="${W - P}" y="${H - 10}" text-anchor="end">${num(cs, 0)} sold → tape-out</text>
      <text x="${P}" y="${Y(lo) - 8}">${usd(lo)}</text><text x="${W - P}" y="${P - 10}" text-anchor="end">${usd(hi)}</text>
    </g></svg>`;
}

async function viewToken(addr) {
  let L = state.launches.find((x) => x.token.toLowerCase() === addr.toLowerCase());
  if (!L) L = await readLaunch({ token: addr, trades: [], block: 0 }).catch(() => null);
  if (!L) { $("#app").innerHTML = `<div class="empty-state" style="margin-top:40px"><b>Not a launch on ${INSTANCES[state.inst].label}</b>${esc(addr)}</div>`; return; }
  const cfg = L.cfg, qUsd = quoteUsd(L.quote), qd = cfg.dec, sym = cfg.sym;
  const head = await rp.getBlockNumber();
  const guardLeft = L.launchBlock + state.pad.guard - head;
  const trades = (INDEX?.launches?.[L.token.toLowerCase()]?.trades || L.trades || []).slice().reverse();
  const grad = INDEX?.launches?.[L.token.toLowerCase()]?.graduated;

  $("#app").innerHTML = `
  <div class="tp-head">${avatar(L)}
    <div><h1>${esc(L.name)} <span class="muted" style="font-weight:400">$${esc(L.symbol)}</span></h1>
    <div class="meta">${pills(L)}<span class="pill">${circuitLabel(L)}</span>
      <a class="pill" href="${EXPLORER}/token/${L.token}" target="_blank" rel="noopener">${short(L.token)} ↗</a></div></div>
  </div>
  ${isBem(L.quote) ? `<div class="note vol">Volatile quote: this launch is priced in BEM. Its tape-out target is fixed at ${num(units(cfg.raise, 8), 2)} BEM, so the USD value of the target (and of every price here) moves with BEM.</div>` : ""}
  ${traceHtml(cfg, L.mcUsd, qUsd, L.status === 2)}
  <div class="cols">
    <div>
      <div class="card"><div class="stats">
        <div><label>Market cap</label><b>${usd(L.mcUsd)}</b><small>${num(L.mcQuote, 3)} ${sym}</small></div>
        <div><label>Price</label><b>${L.price.toPrecision(3)}</b><small>${sym} per token${L.status === 2 ? " · v4 pool" : ""}</small></div>
        <div><label>Raised</label><b>${num(units(L.realQuote, qd), 3)}</b><small>of ${num(units(cfg.raise, qd), 2)} ${sym}${L.status === 2 ? " (moved to LP)" : ""}</small></div>
        <div><label>Curve sold</label><b>${L.status ? "100" : L.progress.toFixed(2)}%</b><small>${num(units(L.tokensLeft, 18), 2)} left</small></div>
      </div></div>
      <div class="card"><h3>Bonding curve <small>x·y=k, virtual reserves read from CurvePad</small></h3>${curveSvg(L)}</div>
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
    box.innerHTML = `<h3>Taped out <small>Uniswap v4 · 1% fee · locked</small></h3>
      <dl class="kv"><dt>Pool</dt><dd>${L.poolId ? short(L.poolId) : "–"}</dd><dt>Locked position</dt><dd>${grad ? "#" + grad.positionId : "–"}</dd>
      <dt>Hook</dt><dd><a href="${EXPLORER}/address/${state.pad.hook}" target="_blank" rel="noopener">${short(state.pad.hook)}</a></dd>
      <dt>Locker</dt><dd><a href="${EXPLORER}/address/${state.pad.locker}" target="_blank" rel="noopener">${short(state.pad.locker)}</a></dd></dl>
      <div class="note">The curve is closed. Trade in the v4 pool through Uniswap's Universal Router or any aggregator that routes Circ hook pools
      (OKX DEX routing is pending their integration). LP fees keep flowing 50/30/20 to the Container, protocol and sink.</div>
      ${grad ? `<a class="btn block" href="${EXPLORER}/tx/${grad.tx}" target="_blank" rel="noopener">Graduation tx ↗</a>` : ""}`;
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
    ${guardLeft > 0 ? `<div class="note warn">Anti-snipe guard: ${guardLeft} more blocks. Buys are capped at ${num(units(state.pad.maxEarly, 18), 1)} tokens per block across all buyers.</div>` : ""}
    <button class="btn hub block" id="go">Connect wallet</button>
    <div class="note">1% fee on every trade: 50% to this launch's Container, 30% protocol, 20% sink. Slippage limit 1%.</div>`;
  const amt = $("#amt", box), pv = $("#pv", box), go = $("#go", box);
  const quick = () => $("#quick", box).innerHTML = (side === "buy"
    ? (wokbQ ? ["0.01", "0.1", "0.5", "1"] : ["1", "5", "10", "25"]).map((v) => `<button data-v="${v}">${v} ${wokbQ ? "OKB" : "BEM"}</button>`)
    : ["25", "50", "100"].map((v) => `<button data-p="${v}">${v}%</button>`)).join("");
  let last = null;
  async function preview() {
    const v = amt.value.trim(); last = null;
    if (!v || isNaN(+v) || +v <= 0) { pv.innerHTML = `<dt>You receive</dt><dd>–</dd>`; return; }
    try {
      if (side === "buy") {
        const q = E.parseUnits(v, qd);
        const [out, used] = await state.pad.contract.previewBuy(L.token, q);
        last = { q: used, min: (out * 99n) / 100n };
        pv.innerHTML = `<dt>You receive</dt><dd>${num(units(out, 18), 2)} ${esc(L.symbol)}</dd>
          ${used < q ? `<dt>Used (curve fills)</dt><dd>${num(units(used, qd), 6)} ${sym}</dd>` : ""}
          <dt>Fee (1%)</dt><dd>${num(units(q, qd) * 0.01, 6)} ${sym}</dd>`;
      } else {
        const t = E.parseUnits(v, 18);
        const out = await state.pad.contract.previewSell(L.token, t);
        last = { t, min: (out * 99n) / 100n };
        pv.innerHTML = `<dt>You receive</dt><dd>${num(units(out, qd), 6)} ${sym}${wokbQ ? " (as WOKB)" : ""}</dd>`;
      }
    } catch (e) { pv.innerHTML = `<dt>Preview</dt><dd>${esc(e.shortMessage || "unavailable")}</dd>`; }
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
  amt.oninput = () => { clearTimeout(amt._t); amt._t = setTimeout(preview, 250); };
  $("#inlab", box).textContent = `You pay (${wokbQ ? "OKB" : "BEM"})`;
  quick(); balances();
  go.onclick = async () => {
    if (!state.account) { await connect(); balances(); return; }
    if (!last) { toast("Enter an amount"); return; }
    const deadline = Math.floor(Date.now() / 1000) + 1200;
    if (side === "buy") {
      if (wokbQ) sendTx("Buy", (s) => C(state.pad.addr, ABI.pad, s).buyWithOKB(L.token, last.min, deadline, { value: last.q }));
      else sendTx("Buy", async (s) => {
        const t = C(L.quote, ABI.erc20, s);
        if ((await t.allowance(state.account, state.pad.addr)) < last.q) await (await t.approve(state.pad.addr, last.q)).wait();
        return C(state.pad.addr, ABI.pad, s).buy(L.token, last.q, last.min, deadline);
      });
    } else sendTx("Sell", async (s) => {
      const t = C(L.token, ABI.erc20, s);
      if ((await t.allowance(state.account, state.pad.addr)) < last.t) await (await t.approve(state.pad.addr, last.t)).wait();
      return C(state.pad.addr, ABI.pad, s).sell(L.token, last.t, last.min, deadline);
    });
  };
}

// Container withdraw fee: TapeOut charges it per execute; read it live from the Container's fee revert (0xafd49700).
async function containerFee(container, holder) {
  try {
    const data = new E.Interface(ABI.container).encodeFunctionData("execute", [E.ZeroAddress, 0, "0x", 0]);
    await rp.call({ to: container, from: holder, data });
    return 0n;
  } catch (e) {
    const d = e?.data || e?.info?.error?.data || "";
    const m = typeof d === "string" && d.match(/^0xafd49700([0-9a-f]{64})([0-9a-f]{64})/i);
    return m ? BigInt("0x" + m[2]) : null;
  }
}

async function renderCreator(el, L) {
  el.innerHTML = `<h3>Creator fees <small>${circuitLabel(L)}</small></h3><div class="muted skel">loading</div>`;
  const p = state.pad, lockerC = C(p.locker, ABI.locker);
  const nft = C(L.circuitNft, ABI.nft);
  const [holder, code, openFee] = await Promise.all([nft.ownerOf(L.circuitId), rp.getCode(L.container), C(A.OPENER, ABI.opener).FEE().catch(() => null)]);
  const opened = code && code !== "0x";
  const fee = opened ? await containerFee(L.container, holder) : null;
  const assets = [{ a: L.quote, sym: L.cfg.sym, dec: L.cfg.dec }, { a: L.token, sym: L.symbol, dec: 18 }];
  const rows = await Promise.all(assets.map(async (x) => {
    const [pa, la, cb] = await Promise.all([p.contract.accrued(x.a, L.container), lockerC.accrued(x.a, L.container), C(x.a, ABI.erc20).balanceOf(L.container)]);
    return { ...x, claim: pa + la, pa, la, cb };
  }));
  const q = rows[0];
  const claimOkb = units(q.claim, q.dec) * (isBem(L.quote) ? state.prices.bemUsd / state.prices.okbUsd : 1);
  const feeOkb = fee != null ? units(fee, 18) : null;
  const openOkb = openFee != null ? units(openFee, 18) : null;
  // FRONTEND_NOTES rule: recommend the direct claim when the value is < 10x the withdraw fee, or the Container is not
  // opened yet and the value is below the open fee.
  const recDirect = (!opened && openOkb != null && claimOkb < openOkb) || (feeOkb != null && claimOkb < 10 * feeOkb) || feeOkb == null;
  const isHolder = state.account && state.account.toLowerCase() === holder.toLowerCase();
  el.innerHTML = `<h3>Creator fees <small>${circuitLabel(L)}</small></h3>
    <dl class="kv">
      ${rows.map((r) => `<dt>Claimable ${esc(r.sym)}</dt><dd>${num(units(r.claim, r.dec), 6)}</dd>`).join("")}
      <dt>Container</dt><dd><a href="${EXPLORER}/address/${L.container}" target="_blank" rel="noopener">${short(L.container)}</a> · ${opened ? "opened" : "not opened"}</dd>
      ${rows.map((r) => `<dt>Container balance ${esc(r.sym)}</dt><dd>${num(units(r.cb, r.dec), 6)}</dd>`).join("")}
      <dt>Container withdraw fee</dt><dd>${feeOkb != null ? feeOkb + " OKB / withdraw" : opened ? "unknown" : `open first: ${openOkb ?? "?"} OKB once`}</dd>
      <dt>Holder</dt><dd>${short(holder)}${isHolder ? " (you)" : ""}</dd>
    </dl>
    <div class="route ${recDirect ? "rec" : ""}"><h4>Claim to your wallet ${recDirect ? '<span class="tag">RECOMMENDED</span>' : ""}</h4>
      <p>Direct holder claim. Gas only, paid now to the Circuit's current holder.${recDirect ? " Best for small amounts: the Container withdraw fee would eat a large share." : ""}</p>
      <button class="btn block" id="cl-direct" ${isHolder ? "" : "disabled"}>${isHolder ? "Claim to wallet" : "Holder only"}</button></div>
    <div class="route ${recDirect ? "" : "rec"}"><h4>Send to the Container ${recDirect ? "" : '<span class="tag">RECOMMENDED</span>'}</h4>
      <p>Fees stay with the Circuit NFT (they move with it on sale). Withdrawing later costs ${feeOkb != null ? feeOkb + " OKB per withdraw" : "the TapeOut withdraw fee"}${opened ? "" : ` plus a one-time ${openOkb ?? "?"} OKB open`}.</p>
      <button class="btn block" id="cl-cont" ${isHolder ? "" : "disabled"}>${isHolder ? "Claim to Container" : "Holder only"}</button></div>
    <div class="note">Fees arrive as ${isBem(L.quote) ? "BEM" : "WOKB (wrapped OKB)"} plus the launch token, not native OKB.</div>`;
  const claim = (toHolder) => sendTx(toHolder ? "Claim to wallet" : "Claim to Container", async (s) => {
    let tx;
    for (const r of rows) {
      if (r.pa > 0n) tx = await C(p.addr, ABI.pad, s).claimCreator(L.container, r.a, toHolder);
      if (r.la > 0n) tx = await C(p.locker, ABI.locker, s).claimCreator(L.container, r.a, toHolder);
    }
    if (!tx) throw new Error("nothing to claim");
    return tx;
  });
  if (isHolder) { $("#cl-direct", el).onclick = () => claim(true); $("#cl-cont", el).onclick = () => claim(false); }
}

async function viewLaunch() {
  const p = state.pad, okb = state.prices.okbUsd;
  const opt = (q) => { const c = p.cfg[q.toLowerCase()]; const u = quoteUsd(q); return { c, u }; };
  const w = opt(p.wokb), b = opt(p.bem);
  $("#app").innerHTML = `
  <div class="tp-head"><div><div class="eyebrow">Launch</div><h1>Wire a token to your Circuit</h1>
    <p class="lede" style="margin:10px 0 0">You must hold the TapeOut Circuit. The token's Container is that Circuit's ERC-6551 account: it earns 50% of every fee, forever, and moves with the NFT.</p></div></div>
  <div class="cols">
    <div class="card"><div class="form">
      <div class="two">
        <div class="field"><label>Circuit collection</label><input id="nft" class="mono" value="${A.NANDOUT}" style="font-size:13px"></div>
        <div class="field"><label>Circuit ID</label><input id="cid" inputmode="numeric" placeholder="e.g. 1"></div>
      </div>
      <div id="circ-check" class="note">Enter a Circuit to check provenance and ownership on chain.</div>
      <div class="two">
        <div class="field"><label>Token name</label><input id="name" placeholder="Circuit Token" maxlength="40"></div>
        <div class="field"><label>Symbol</label><input id="sym" placeholder="CIRC" maxlength="10" style="text-transform:uppercase"></div>
      </div>
      <div class="field"><label>Quote asset</label><select id="quote">
        <option value="${p.wokb}">OKB / WOKB (default)</option><option value="${p.bem}">BEM · volatile quote</option></select></div>
      <div id="vol" class="note vol" hidden>BEM is a volatile quote: the tape-out target is fixed in BEM (${num(units(b.c.raise, 8), 2)} BEM, ≈ ${usd(units(b.c.raise, 8) * b.u)} today), so the USD market caps move with BEM's price.</div>
      <div class="field"><label>Dev-buy (optional, exempt from anti-snipe)</label><input id="dev" inputmode="decimal" placeholder="0.0"></div>
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
    const c = p.cfg[q.toLowerCase()];
    sendTx("Launch", async (s) => {
      const pad = C(p.addr, ABI.pad, s);
      if (!isBem(q)) return pad.createLaunch(nft, id, name, sym, q, 0, 0, { value: dev ? E.parseUnits(dev, 18) : 0n });
      const amt = dev ? E.parseUnits(dev, c.dec) : 0n;
      if (amt > 0n) { const t = C(q, ABI.erc20, s); if ((await t.allowance(state.account, p.addr)) < amt) await (await t.approve(p.addr, amt)).wait(); }
      return pad.createLaunch(nft, id, name, sym, q, amt, 0);
    });
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
  $("#mine").innerHTML = list.length ? list.map((x) => `<a class="row" href="javascript:void 0" data-t="${x.token}" style="grid-template-columns:1fr auto">
    <div class="tok">${avatar(x)}<div><b>${esc(x.name)}</b><small>${circuitLabel(x)}</small></div></div>${pills(x)}</a>`).join("")
    : `<div class="empty-state"><b>No launches ${state.account ? "for your Circuits" : "yet"}</b>${state.account ? "" : "Connect to filter by the Circuits you hold."}</div>`;
  $("#mine").onclick = (e) => { const r = e.target.closest("[data-t]"); if (r) renderCreator($("#creator"), L.find((x) => x.token === r.dataset.t)); };
}

// ---------------------------------------------------------------- router
let booted = false;
async function boot() {
  setBanner();
  $("#app").innerHTML = `<div style="padding:80px 0" class="muted mono">Reading CurvePad on X Layer…</div>`;
  await loadPad();
  await loadPrices();
  await loadLaunches();
  booted = true;
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
    else if (h.startsWith("/launch")) await viewLaunch();
    else if (h.startsWith("/creator")) await viewCreator();
    else await viewFloor();
    if (h === "/" && location.hash === "#wafer") $("#wafer")?.scrollIntoView();
  } catch (e) {
    console.error(e);
    $("#app").innerHTML = `<div class="empty-state" style="margin-top:40px"><b>Couldn't read the chain</b>${esc(e.shortMessage || e.message)}<br><br><button class="btn" onclick="location.reload()">Retry</button></div>`;
  }
}
window.switchInst = (i) => { state.inst = i; localSet("circ.inst", i); booted = false; location.hash = "#/"; route(); };
document.querySelectorAll("#inst button").forEach((b) => b.onclick = () => window.switchInst(b.dataset.inst));
$("#connect").onclick = () => connect().then(() => route()).catch((e) => toast(e.shortMessage || e.message));
window.addEventListener("hashchange", () => { if (location.hash !== "#wafer") route(); });
if (window.ethereum?.on) window.ethereum.on("accountsChanged", () => { state.signer = null; state.account = null; $("#connect").textContent = "Connect"; route(); });
route();
