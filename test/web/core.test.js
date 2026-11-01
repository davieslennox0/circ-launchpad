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

test("guard: blocks left match the contract's block.number < launchBlock + GUARD_BLOCKS", () => {
  assert.equal(C.guardBlocksLeft(100, 30, 100), 29);
  assert.equal(C.guardBlocksLeft(100, 30, 128), 1);  // lands in 129: still guarded
  assert.equal(C.guardBlocksLeft(100, 30, 129), 0);  // lands in 130: not guarded
  assert.equal(C.guardBlocksLeft(100, 30, 500), 0);
});

test("price change: anchors at the start of the window, or at launch for a younger token", () => {
  const pts = [[1000, 10], [5000, 20], [9000, 40]];
  assert.equal(C.priceChange(pts, 10000, 300, 40), 0);      // nothing in the last 5 minutes
  assert.equal(C.priceChange(pts, 9100, 300, 20), 0 - 0);   // anchored on the 5000 point
  assert.equal(C.priceChange(pts, 10000, 3600, 40), 100);   // 6400 falls after 5000: 20 -> 40
  assert.equal(C.priceChange(pts, 10000, 86400, 5), -50);   // younger than the window: from launch
  assert.equal(C.priceChange([], 10000, 300, 1), null);
  assert.equal(C.priceChange(null, 10000, 300, 1), null);
  assert.equal(C.priceChange(pts, 10000, 300, 0), null);
});

test("price change: format and colour", () => {
  assert.deepEqual(C.formatChange(2), { text: "+2%", cls: "up" });
  assert.deepEqual(C.formatChange(-57.4), { text: "-57%", cls: "down" });
  assert.deepEqual(C.formatChange(-96.2), { text: "-96%", cls: "down" });
  assert.deepEqual(C.formatChange(0.34), { text: "+0.3%", cls: "up" });
  assert.deepEqual(C.formatChange(1234.6), { text: "+1,235%", cls: "up" });
  assert.deepEqual(C.formatChange(0.01), { text: "0%", cls: "flat" });
  assert.deepEqual(C.formatChange(null), { text: "–", cls: "flat" });
});

test("floor: stages, search and filters", () => {
  const a = { name: "Doug", symbol: "DOUG", circuitId: 13, token: "0xAA", status: 2, progress: 100 };
  const b = { name: "Half", symbol: "HLF", circuitId: 14, token: "0xBB", status: 0, progress: 50 };
  const c = { name: "New one", symbol: "NEW", circuitId: 2, token: "0xCC", status: 0, progress: 3 };
  const d = { name: "Full", symbol: "FUL", circuitId: 3, token: "0xDD", status: 1, progress: 100 };
  const all = [a, b, c, d];
  assert.deepEqual(all.map(C.floorStage), ["uni", "near", "new", "near"]);
  assert.deepEqual(C.filterLaunches(all, "", "uni"), [a]);
  assert.deepEqual(C.filterLaunches(all, "", "near"), [b, d]);
  assert.deepEqual(C.filterLaunches(all, "", "live"), [b, c, d]);
  assert.deepEqual(C.filterLaunches(all, "dou", "all"), [a]);
  assert.deepEqual(C.filterLaunches(all, "$hlf", "all"), [b]);
  assert.deepEqual(C.filterLaunches(all, "nand 2", "all"), [c]);
  assert.deepEqual(C.filterLaunches(all, "13", "all"), [a]);
  assert.deepEqual(C.filterLaunches(all, "0xcc", "all"), [c]);
  assert.deepEqual(C.filterLaunches(all, "doug", "near"), []);
});

test("king of the hill: closest to tape-out, or hot volume on the way there", () => {
  const cfg = { raise: 1000n };
  const now = 10000, hot = [{ ts: 9900, q: "1000" }], old = [{ ts: 100, q: "99999" }];
  const near = { status: 0, progress: 80, cfg, trades: [], block: 1 };
  const busy = { status: 0, progress: 40, cfg, trades: hot, block: 2 };
  const uni = { status: 2, progress: 100, cfg, trades: hot, block: 3 };
  const stale = { status: 0, progress: 60, cfg, trades: old, block: 4 };
  const fresh = { status: 0, progress: 0, cfg, trades: [], block: 5 };
  assert.equal(C.kingOfTheHill([near, stale], now).L, near);             // volume outside the hour doesn't count
  assert.equal(C.kingOfTheHill([stale, busy], now).L, busy); // 40 + 50 beats 60
  assert.equal(C.kingOfTheHill([near, busy], now).L, busy);              // 90 beats 80
  assert.equal(C.kingOfTheHill([uni], now), null);                       // on Uniswap: off the hill
  assert.equal(C.kingOfTheHill([fresh], now), null);                     // untraded launch
  assert.equal(C.kingOfTheHill([], now), null);
  assert.equal(C.kingOfTheHill([{ ...near, status: 1 }, busy], now).L.status, 1); // complete, about to tape out
});

test("activity: last trade, heating up, and the latest trades", () => {
  const now = 10000;
  const quiet = { trades: [{ ts: 100, q: "1" }], prices: [[50, 1], [100, 1]], price: 1 };
  const busy = { trades: [{ ts: 9900, q: "1" }, { ts: 9950, q: "2" }], prices: [[50, 1], [9950, 2]], price: 2 };
  const swapped = { trades: [{ ts: 100, q: "1" }], prices: [[50, 1], [9990, 2]], price: 2 };
  assert.equal(C.lastTradeTs(quiet), 100);
  assert.equal(C.lastTradeTs(swapped), 9990);       // a Uniswap swap counts
  assert.equal(C.lastTradeTs({ prices: [[50, 1]] }), 0); // only the launch price: nothing traded
  assert.ok(C.heat(busy, now) > C.heat(quiet, now));
  assert.equal(C.heat(quiet, now), 0);
  const feed = C.recentActivity([quiet, busy], 2);
  assert.deepEqual(feed.map((a) => a.ts), [9950, 9900]);
  const launched = { ts: 9999, trades: [] };          // launched, nobody has traded yet: it still shows
  const withNew = C.recentActivity([quiet, busy, launched], 2);
  assert.equal(withNew[0].L, launched);
  assert.equal(withNew[0].t, undefined);
  assert.equal(withNew[1].t.ts, 9950);
  assert.equal(C.recentActivity([], 5).length, 0);
});

test("floor: sorting keeps rows without a value last", () => {
  const rows = [{ v: 1 }, { v: null }, { v: 3 }];
  assert.deepEqual(C.sortBy(rows, (r) => r.v, true).map((r) => r.v), [3, 1, null]);
  assert.deepEqual(C.sortBy(rows, (r) => r.v, false).map((r) => r.v), [1, 3, null]);
});

test("chart: starts at the window, ends at the current price, and survives thin data", () => {
  const line = C.chartLine([[100, 1], [900, 4]], 1000, 500, 2, 600, 200).split(" ");
  assert.equal(line.length, 3);
  assert.equal(line[0].split(",")[0], "0.0");
  assert.equal(line[2].split(",")[0], "600.0");
  assert.equal(C.chartLine([[100, 2]], 1000, 500, 2, 600, 200), "0.0,100.0 600.0,100.0"); // flat
  assert.equal(C.chartLine([], 1000, 500, 2, 600, 200), null);
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
