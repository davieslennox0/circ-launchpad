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

  /** Byte length as the contract counts it (name, symbol and imageURI limits are in bytes). */
  const byteLength = (s) => new TextEncoder().encode(s).length;

  return { esc, short, initials, safeImage, nandIds, nextNandId, feeOn, grossForNet, tokensOut, quoteForTokens, previewCurveBuy,
    recommendDirect, parseContainerRevert, uncollectedFee, byteLength };
});
