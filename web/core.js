/* Circ frontend logic with no DOM, wallet or network access, so it can be unit tested (test/web). Loaded before app.js in
 * the browser as window.CircCore; required directly in Node tests. */
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.CircCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  const BPS = 10000n;

  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "");
  const initials = (sym) => esc(String(sym || "?").replace(/[^A-Za-z0-9]/g, "").slice(0, 3).toUpperCase() || "?");

  // ---- logos: only ipfs://<CID> (CIDv1 base32 or CIDv0), optional /path of safe characters. Returns the gateway-relative
  // path, or null for anything else (the caller shows initials). `hide` is the moderation set of lowercase token addresses.
  const CID_RE = /^(b[a-z2-7]{58,}|Qm[1-9A-HJ-NP-Za-km-z]{44})$/;
  const PATH_RE = /^[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*$/;
  function safeImage(uri, token, hide) {
    if (typeof uri !== "string" || !uri.startsWith("ipfs://") || uri.length > 256) return null;
    if (token && hide && hide.has(token.toLowerCase())) return null;
    const [cid, ...rest] = uri.slice(7).split("/");
    if (!CID_RE.test(cid)) return null;
    const path = rest.join("/");
    if (path && (!PATH_RE.test(path) || rest.some((seg) => seg === "." || seg === ".."))) return null; // no gateway escapes
    return cid + (path ? "/" + path : "");
  }

  // ---- Nand ids. Circuits.tapeout does `circuitId = ++nextId`, so nextId() is the LAST minted id, not the next one.
  const nandIds = (lastId) => Array.from({ length: Number(lastId) }, (_, i) => i + 1);
  const nextNandId = (lastId) => Number(lastId) + 1;

  // ---- curve math, mirroring src/libraries/CurveMath.sol exactly (BigInt, same rounding)
  const ceilDiv = (a, b) => (a + b - 1n) / b;
  const feeOn = (q, feeBps) => ceilDiv(q * feeBps, BPS);
  function grossForNet(net, feeBps) {
    let gross = ceilDiv(net * BPS, BPS - feeBps);
    while (gross - feeOn(gross, feeBps) < net) gross++;
    return gross;
  }
  const tokensOut = (q, t, netIn) => t - ceilDiv(q * t, q + netIn);
  const quoteForTokens = (q, t, out) => ceilDiv(q * t, t - out) - q;

  /** What a curve buy of `quoteIn` really does, including the anti-snipe cap that the contract's previewBuy ignores.
   *  guarded: the buy lands inside the guard window. soldThisBlock: curve tokens already bought in the current block.
   *  minOut stays loose while guarded: buyers in the same block share the cap, each block can move the price only about 1%,
   *  and any quote not used is refunded. Outside the guard it is the normal 1% slippage limit. */
  function previewCurveBuy({ vQuote, vToken, tokensLeft, quoteIn, feeBps, guarded, maxEarly, soldThisBlock }) {
    let net = quoteIn - feeOn(quoteIn, feeBps);
    let out = tokensOut(vQuote, vToken, net);
    let used = quoteIn;
    let cap = tokensLeft;
    let capped = false;
    if (guarded) {
      const room = maxEarly > soldThisBlock ? maxEarly - soldThisBlock : 0n;
      if (cap > room) { cap = room; capped = out > room; }
    }
    if (out > cap) {
      out = cap;
      if (out > 0n) {
        net = quoteForTokens(vQuote, vToken, out);
        used = grossForNet(net, feeBps);
      } else { net = 0n; used = 0n; }
    }
    return { out, used, fee: used - net, capped, fills: !capped && out === tokensLeft, minOut: guarded ? out / 2n : (out * 99n) / 100n };
  }

  // ---- creator fees: recommend the direct claim when the Container's costs would eat too much (docs/FRONTEND_NOTES.md)
  function recommendDirect({ claimOkb, opened, openOkb, feeOkb }) {
    if (!opened) return openOkb == null || claimOkb < openOkb;
    return feeOkb == null || claimOkb < 10 * feeOkb;
  }

  /** Reads a Container's state from the revert of a zero-value execute() by its holder. */
  const SEL_FEE_REQUIRED = "0xafd49700"; // (uint256 sent, uint256 required)
  const SEL_NOT_PAID = "0x34e4a710"; // deployed through the registry without paying TapeOut's open fee
  function parseContainerRevert(data) {
    if (typeof data !== "string") return { state: "unknown", fee: null };
    const d = data.toLowerCase();
    if (d.startsWith(SEL_NOT_PAID)) return { state: "unpaid", fee: null };
    if (d.startsWith(SEL_FEE_REQUIRED) && d.length >= 10 + 128) return { state: "open", fee: BigInt("0x" + d.slice(74, 138)) };
    return { state: "unknown", fee: null };
  }

  /** Uncollected fees of a v4 position: liquidity * (growthNow - growthLast) / 2^128, with growth wrapping mod 2^256. */
  function uncollectedFee(liquidity, growthNow, growthLast) {
    const delta = BigInt.asUintN(256, growthNow - growthLast);
    return (liquidity * delta) >> 128n;
  }

  // ---- Universal Router 2.1.x calldata for one swap in a Circ v4 pool (commands V4_SWAP 0x10, WRAP_ETH 0x0b, UNWRAP_WETH 0x0c;
  // v4 actions SWAP_EXACT_IN_SINGLE 0x06, SETTLE 0x0b, SETTLE_ALL 0x0c, TAKE 0x0e, TAKE_ALL 0x0f). MSG_SENDER = address(1) and
  // ADDRESS_THIS = address(2) are the router's recipient sentinels. amount 0 in SETTLE/TAKE means "the open delta".
  const MSG_SENDER = "0x0000000000000000000000000000000000000001";
  const ADDRESS_THIS = "0x0000000000000000000000000000000000000002";
  const SWAP_PARAMS = "tuple(tuple(address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes)";
  /** native: the quote side is WOKB and the user pays or receives native OKB (wrapped/unwrapped inside the tx). */
  function encodeSwap(coder, { key, tokenIn, tokenOut, amountIn, minOut, native }) {
    const k = [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks];
    const zeroForOne = tokenIn.toLowerCase() === key.currency0.toLowerCase();
    const swap = coder.encode([SWAP_PARAMS], [[k, zeroForOne, amountIn, minOut, 0n, "0x"]]);
    const enc = (types, vals) => coder.encode(types, vals);
    const v4 = (actions, params) => coder.encode(["bytes", "bytes[]"], [actions, params]);
    if (native === "in") { // OKB -> token: wrap into the router, settle from the router, send the token to the user
      return { commands: "0x0b10", value: amountIn, inputs: [
        enc(["address", "uint256"], [ADDRESS_THIS, amountIn]),
        v4("0x060b0f", [swap, enc(["address", "uint256", "bool"], [tokenIn, 0n, false]), enc(["address", "uint256"], [tokenOut, minOut])]),
      ] };
    }
    if (native === "out") { // token -> OKB: pull the token via Permit2, take WOKB into the router, unwrap to the user
      return { commands: "0x100c", value: 0n, inputs: [
        v4("0x060c0e", [swap, enc(["address", "uint256"], [tokenIn, amountIn]), enc(["address", "address", "uint256"], [tokenOut, ADDRESS_THIS, 0n])]),
        enc(["address", "uint256"], [MSG_SENDER, minOut]),
      ] };
    }
    return { commands: "0x10", value: 0n, inputs: [ // ERC-20 both ways (BEM launches)
      v4("0x060c0f", [swap, enc(["address", "uint256"], [tokenIn, amountIn]), enc(["address", "uint256"], [tokenOut, minOut])]),
    ] };
  }

  /** Share of supply in the launching wallet, for the "Dev holds X%" label. Above 10% it is highlighted. It reads that one
   *  wallet only: tokens moved to another wallet no longer count. null when the creator isn't known. */
  function devHolding(balance, totalSupply) {
    if (balance == null || !totalSupply) return null;
    const bps = Number((BigInt(balance) * 10000n) / BigInt(totalSupply));
    return { pct: bps / 100, high: bps > 1000 };
  }

  /** Opens a site inside OKX Wallet's dApp browser (web3.okx.com docs: app universal link). */
  function okxWalletLink(url) {
    return "https://web3.okx.com/download?deeplink=" + encodeURIComponent("okx://wallet/dapp/url?dappUrl=" + encodeURIComponent(url));
  }
  const isMobile = (ua) => /Android|iPhone|iPad|iPod|Mobile/i.test(ua || "");

  /** Byte length as the contract counts it (name, symbol and imageURI limits are in bytes). */
  const byteLength = (s) => new TextEncoder().encode(s).length;

  // Blocks left in which a buy sent now is still capped. CurvePad: guarded while block.number < launchBlock + GUARD_BLOCKS,
  // and a transaction sent now lands in head + 1 at the earliest.
  function guardBlocksLeft(launchBlock, guard, head) { return Math.max(0, launchBlock + guard - head - 1); }

  // Change from the price at the start of a window to `current`. points: [[timestamp, price], ...], oldest first.
  // A token younger than the window is measured from its first point, the launch price. Null if there's no history.
  function priceChange(points, nowSec, windowSec, current) {
    if (!points || !points.length || !(current > 0)) return null;
    let anchor = points[0][1];
    for (const [ts, p] of points) { if (ts <= nowSec - windowSec) anchor = p; else break; }
    return anchor > 0 ? (current / anchor - 1) * 100 : null;
  }
  function formatChange(pct) {
    if (pct === null || pct === undefined) return { text: "–", cls: "flat" };
    if (Math.abs(pct) < 0.05) return { text: "0%", cls: "flat" };
    const a = Math.abs(pct);
    const n = a >= 10 ? Math.round(a).toLocaleString("en-US") : String(Number(a.toFixed(1)));
    return { text: (pct > 0 ? "+" : "-") + n + "%", cls: pct > 0 ? "up" : "down" };
  }

  // Fab floor. Stage: just launched, close to the gate (half the curve sold, or complete), or on Uniswap.
  function floorStage(L) { return L.status === 2 ? "uni" : L.status === 1 || L.progress >= 50 ? "near" : "new"; }
  function filterLaunches(list, query, filter) {
    const q = String(query || "").trim().toLowerCase().replace(/^\$/, "");
    return list.filter((L) => {
      if (filter === "live" && L.status === 2) return false;
      if ((filter === "near" || filter === "uni") && floorStage(L) !== filter) return false;
      if (!q) return true;
      const id = String(L.circuitId);
      return String(L.name).toLowerCase().includes(q) || String(L.symbol).toLowerCase().includes(q) || id === q || `nand ${id}` === q || `#${id}` === q || String(L.token).toLowerCase() === q;
    });
  }
  // Sorts a copy. Rows with no value go last in either direction.
  function sortBy(list, value, descending) {
    const dir = descending ? -1 : 1;
    return list.map((L) => [L, value(L)]).sort(([, a], [, b]) => {
      const an = a === null || a === undefined, bn = b === null || b === undefined;
      return an || bn ? an - bn : (a - b) * dir;
    }).map(([L]) => L);
  }
  // Polyline for a price chart: the price at the window's start, what happened inside it, and the current price.
  function chartLine(points, nowSec, windowSec, current, W, H) {
    if (!points || !points.length || !(current > 0)) return null;
    const start = nowSec - windowSec;
    const inside = points.filter(([ts]) => ts > start);
    const before = points.filter(([ts]) => ts <= start).pop();
    const pts = [...(before ? [[start, before[1]]] : []), ...inside, [nowSec, current]];
    const t0 = pts[0][0], span = Math.max(1, nowSec - t0), logs = pts.map(([, p]) => Math.log(p));
    const lo = Math.min(...logs), hi = Math.max(...logs), pad = 8;
    return pts.map(([ts], i) => {
      const x = ((ts - t0) / span) * W;
      const y = hi === lo ? H / 2 : pad + (1 - (logs[i] - lo) / (hi - lo)) * (H - 2 * pad);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(" ");
  }

  return { floorStage, filterLaunches, sortBy, chartLine, priceChange, formatChange, guardBlocksLeft, esc, short, initials, safeImage, nandIds, nextNandId, feeOn, grossForNet, tokensOut, quoteForTokens, previewCurveBuy,
    recommendDirect, parseContainerRevert, uncollectedFee, encodeSwap, devHolding, okxWalletLink, isMobile, byteLength };
});
