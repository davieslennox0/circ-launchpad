// Frontend logic tests. Run: node --test test/web/
const test = require("node:test");
const assert = require("node:assert/strict");
const C = require("../../web/core.js");

const CID = "bafkreifgwgniocoza3oetpvyllyxb2tlbnvn7sgywmnbwxcb4tcnkc6qsu";
const FEE = 100n;
// Production-shaped curve: v2 WOKB constants.
const V_Q0 = 38393377713177396386n, V_T0 = 1061538461538461538461538462n, CS = 805950034987136158382022685n;
const MAX_EARLY = 5000000n * 10n ** 18n;
const curve = (over = {}) => ({ vQuote: V_Q0, vToken: V_T0, tokensLeft: CS, feeBps: FEE, guarded: false, maxEarly: MAX_EARLY, soldThisBlock: 0n, ...over });

test("H1: nextId() is the last minted id: every Nand is listed and the next mint is one higher", () => {
  assert.deepEqual(C.nandIds(11), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  assert.equal(C.nextNandId(11), 12);
  assert.deepEqual(C.nandIds(0), []);
  assert.equal(C.nextNandId(0), 1);
});

test("H3: a guarded buy above the cap is capped, not sent with an impossible minimum", () => {
  const r = C.previewCurveBuy(curve({ quoteIn: 10n ** 18n, guarded: true })); // 1 OKB, far above the 5M token cap
  assert.equal(r.out, MAX_EARLY);
  assert.equal(r.capped, true);
  assert.ok(r.used < 10n ** 18n, "the rest is refunded");
  assert.ok(r.minOut <= r.out, "the contract's Slippage check must pass");
  // The old bug: 99% of the uncapped preview is above what the cap can ever deliver.
  const uncapped = C.previewCurveBuy(curve({ quoteIn: 10n ** 18n }));
  assert.ok((uncapped.out * 99n) / 100n > MAX_EARLY, "uncapped minimum would revert in the guard");
});

test("H3: the cap is shared across the block", () => {
  const r = C.previewCurveBuy(curve({ quoteIn: 10n ** 18n, guarded: true, soldThisBlock: MAX_EARLY - 1000n }));
  assert.equal(r.out, 1000n);
  const full = C.previewCurveBuy(curve({ quoteIn: 10n ** 18n, guarded: true, soldThisBlock: MAX_EARLY }));
  assert.equal(full.out, 0n);
  assert.equal(full.used, 0n);
});

test("H3: small guarded buys and normal buys are not capped", () => {
  const small = C.previewCurveBuy(curve({ quoteIn: 10n ** 16n, guarded: true }));
  assert.equal(small.capped, false);
  assert.equal(small.used, 10n ** 16n);
  const normal = C.previewCurveBuy(curve({ quoteIn: 10n ** 18n }));
  assert.equal(normal.capped, false);
  assert.equal(normal.minOut, (normal.out * 99n) / 100n);
});

test("buy that fills the curve uses only what it needs, with the fee on top", () => {
  const r = C.previewCurveBuy(curve({ quoteIn: 10n ** 24n }));
  assert.equal(r.out, CS);
  assert.equal(r.fills, true);
  assert.ok(r.used < 10n ** 24n);
  assert.ok(r.used - r.fee > 0n);
  assert.ok(r.fee >= C.feeOn(r.used - r.fee, FEE) - 2n);
});

test("curve math matches the contract's rounding", () => {
  assert.equal(C.feeOn(10000n, FEE), 100n);
  assert.equal(C.feeOn(10001n, FEE), 101n, "fee rounds up");
  assert.equal(C.feeOn(1n, FEE), 1n);
  const g = C.grossForNet(9900n, FEE);
  assert.equal(g, 10000n);
  assert.ok(C.grossForNet(9901n, FEE) - C.feeOn(C.grossForNet(9901n, FEE), FEE) >= 9901n);
  // Buying `out` for quoteForTokens must deliver at least `out`.
  const out = 123456789n * 10n ** 18n;
  const net = C.quoteForTokens(V_Q0, V_T0, out);
  assert.ok(C.tokensOut(V_Q0, V_T0, net) >= out);
});

test("logos: only ipfs:// with a valid CID renders", () => {
  const hide = new Set();
  assert.equal(C.safeImage(`ipfs://${CID}`, null, hide), CID);
  assert.equal(C.safeImage(`ipfs://${CID}/logo.png`, null, hide), `${CID}/logo.png`);
  assert.equal(C.safeImage("ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", null, hide), "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG");
  for (const bad of ["", null, undefined, 5, "https://evil.example/x.png", "javascript:alert(1)", "data:image/png;base64,AAAA",
    "ipfs://", "ipfs://notacid", `ipfs://${CID}/../../etc`, `ipfs://${CID}/a b`, `ipfs://${CID}/"onerror="x`, `IPFS://${CID}`,
    `ipfs://${CID}/` + "a".repeat(300)]) {
    assert.equal(C.safeImage(bad, null, hide), null, String(bad));
  }
});

test("logos: the hide-list swaps a logo for initials, case-insensitively", () => {
  const hide = new Set(["0xabc"]);
  assert.equal(C.safeImage(`ipfs://${CID}`, "0xABC", hide), null);
  assert.equal(C.safeImage(`ipfs://${CID}`, "0xdef", hide), CID);
});

test("text is escaped and initials are safe", () => {
  assert.equal(C.esc(`<img src=x onerror="a('b')">&`), "&lt;img src=x onerror=&quot;a(&#39;b&#39;)&quot;&gt;&amp;");
  assert.equal(C.initials("<b>x"), "BX");
  assert.equal(C.initials("abcd"), "ABC");
  assert.equal(C.initials("🚀"), "?");
  assert.equal(C.initials(""), "?");
});

test("name limits count bytes like the contract", () => {
  assert.equal(C.byteLength("abc"), 3);
  assert.equal(C.byteLength("🚀"), 4);
});

test("creator advice follows docs/FRONTEND_NOTES.md", () => {
  assert.equal(C.recommendDirect({ claimOkb: 0.01, opened: true, openOkb: 0.08, feeOkb: 0.0013 }), true);
  assert.equal(C.recommendDirect({ claimOkb: 0.02, opened: true, openOkb: 0.08, feeOkb: 0.0013 }), false);
  assert.equal(C.recommendDirect({ claimOkb: 0.05, opened: false, openOkb: 0.08, feeOkb: null }), true);
  assert.equal(C.recommendDirect({ claimOkb: 0.5, opened: false, openOkb: 0.08, feeOkb: null }), false);
  assert.equal(C.recommendDirect({ claimOkb: 5, opened: true, openOkb: 0.08, feeOkb: null }), true, "unknown fee: direct is safest");
});

test("M12: Container state comes from its revert, not from having code", () => {
  const w = (n) => n.toString(16).padStart(64, "0");
  const open = C.parseContainerRevert("0xafd49700" + w(0n) + w(1300000000000000n));
  assert.equal(open.state, "open");
  assert.equal(open.fee, 1300000000000000n);
  assert.equal(C.parseContainerRevert("0x34e4a710").state, "unpaid");
  assert.equal(C.parseContainerRevert("0x").state, "unknown");
  assert.equal(C.parseContainerRevert(undefined).state, "unknown");
});

test("uncollected v4 fees handle growth wrapping", () => {
  const Q = 1n << 128n;
  assert.equal(C.uncollectedFee(10n ** 18n, 5n * Q, 4n * Q), 10n ** 18n);
  assert.equal(C.uncollectedFee(0n, 5n * Q, 4n * Q), 0n);
  const wrapped = C.uncollectedFee(1n, 3n * Q, (1n << 256n) - 2n * Q); // growth wrapped past 2^256
  assert.equal(wrapped, 5n);
});

test("Dev holds: percent of supply, highlighted only above 10%", () => {
  const S = 10n ** 27n;
  assert.deepEqual(C.devHolding(S / 10n, S), { pct: 10, high: false });
  assert.deepEqual(C.devHolding(S / 10n + 10n ** 24n, S), { pct: 10.1, high: true });
  assert.deepEqual(C.devHolding(0n, S), { pct: 0, high: false });
  assert.equal(C.devHolding(null, S), null);
  assert.equal(C.devHolding(1n, null), null);
});

test("OKX Wallet link wraps the page twice-encoded, per OKX's universal link format", () => {
  const u = "https://circ.getsarf.xyz/#/launch";
  const link = C.okxWalletLink(u);
  assert.ok(link.startsWith("https://web3.okx.com/download?deeplink="));
  const inner = decodeURIComponent(link.split("deeplink=")[1]);
  assert.ok(inner.startsWith("okx://wallet/dapp/url?dappUrl="));
  assert.equal(decodeURIComponent(inner.split("dappUrl=")[1]), u);
  assert.equal(C.isMobile("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)"), true);
  assert.equal(C.isMobile("Mozilla/5.0 (X11; Linux x86_64) Chrome/120"), false);
});
