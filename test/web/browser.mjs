// Real-browser test of a deployed site, in headless Chromium, with a mock injected wallet (no private keys, nothing is ever
// sent: the mock rejects every transaction and records what would have been signed).
// Usage: node test/web/browser.mjs [url] [screenshot dir] [staging]
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";

const URL_ = process.argv[2] || "https://circ.getsarf.xyz/";
const SHOTS = process.argv[3];
const HOLDER = "0x934d315C0a9C0866D393B722C1805F2B6b20b816"; // public address with Nands; used read-only
const STAGING = process.argv[4] === "staging";
const PAD = STAGING ? "0x8f2bbd9da778071a8b6e9c2d3fec3f3a6850e6ba" : "0x4b9eb3ee0a25ffe62e159080f392551a99493cc7";
const TEST_TOKEN = "0x1868b87ec03130ea1389e0c81395c957e353f0d3";
const lastNand = async () => { const r = await fetch("https://rpc.xlayer.tech", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: "0x8A60B4A4BCf4066F5E5F9A406fE09c5e4f52a58E", data: "0x61b8ce8c" }, "latest"] }) }); return Number((await r.json()).result); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
const check = (name, ok, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${name}${extra ? "  (" + extra + ")" : ""}`); if (!ok) failed++; };

const chrome = spawn("chromium", ["--headless=old", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--disable-extensions", "--remote-debugging-port=9333", "about:blank"], { stdio: "ignore" });
const cleanup = () => { try { chrome.kill("SIGKILL"); } catch {} };
process.on("exit", cleanup);

async function open() {
  for (let i = 0; i < 60; i++) { try { const r = await fetch("http://127.0.0.1:9333/json/version"); if (r.ok) break; } catch {} await sleep(1000); }
  const t = await (await fetch("http://127.0.0.1:9333/json/new?about:blank", { method: "PUT" })).json();
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0; const pending = new Map(), problems = [];
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
    if (d.method === "Runtime.exceptionThrown") problems.push("exception: " + (d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text).slice(0, 200));
    if (d.method === "Log.entryAdded" && d.params.entry.level === "error") problems.push(d.params.entry.text.slice(0, 200) + " " + (d.params.entry.url || "").slice(0, 80));
  };
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await send("Page.enable"); await send("Runtime.enable"); await send("Log.enable");
  const ev = async (expr) => { const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }); if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description || "eval failed"); return r.result?.result?.value; };
  const until = async (expr, ms = 60000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (await ev(`!!(${expr})`)) return true; await sleep(500); } return false; };
  const shot = async (name) => { if (!SHOTS) return; const r = await send("Page.captureScreenshot", { format: "png" }); writeFileSync(`${SHOTS}/${name}.png`, Buffer.from(r.result.data, "base64")); };
  return { send, ev, until, shot, problems };
}
const WALLET = `(() => {
  window.__tx = []; window.__csp = [];
  document.addEventListener("securitypolicyviolation", (e) => window.__csp.push(e.violatedDirective + " " + e.blockedURI));
  const rpc = (method, params) => fetch("https://rpc.xlayer.tech", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((r) => r.json()).then((j) => { if (j.error) throw j.error; return j.result; });
  const provider = { on() {}, removeListener() {}, request: async ({ method, params }) => {
    if (method === "eth_requestAccounts") window.__prompts = (window.__prompts || 0) + 1;
    if (method === "eth_requestAccounts" || method === "eth_accounts") return ["${HOLDER}"];
    if (method === "eth_chainId") return "0xc4";
    if (method === "eth_sendTransaction") { window.__tx.push(params[0]); throw Object.assign(new Error("User rejected"), { code: 4001 }); }
    return rpc(method, params || []);
  } };
  const announce = () => { for (const [uuid, name] of [["a", "Mock OKX Wallet"], ["b", "Mock Rabby"]]) window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail: { info: { uuid, name, icon: "data:image/gif;base64,R0lGODlhAQABAAAAACw=", rdns: "mock." + uuid }, provider } })); };
  window.addEventListener("eip6963:requestProvider", announce); announce();
})();`;
const go = async (p, hash) => { await p.send("Page.navigate", { url: URL_ + hash }); await sleep(1500); };
const text = (s = "body") => `(document.querySelector(${JSON.stringify(s)})?.innerText || "")`;

for (const [label, w, h, mobile] of [["desktop", 1280, 1400, false], ["phone", 390, 1400, true]]) {
  const p = await open();
  await p.send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile });
  await p.send("Page.addScriptToEvaluateOnNewDocument", { source: WALLET });
  await go(p, "#/");
  await p.ev(`localStorage.removeItem("circ.wallet")`); // the browser profile is shared between runs
  await p.send("Page.reload");
  await sleep(1500);
  check(`${label}: home loads production data`, await p.until(`${text()}.includes("Tape-out raise (WOKB)")`));
  check(`${label}: homepage note replaces the old label`, (await p.ev(text("#app"))).includes("A launchpad on X Layer, built on TapeOut World primitives.") && !/Circ Launchpad · X Layer/i.test(await p.ev(text("#app"))));
  check(`${label}: no 'fair' wording`, !/fair/i.test(await p.ev(text())));
  console.log("INFO  " + label + ": page load " + await p.ev(`(() => { const r = performance.getEntriesByType("resource").filter((e) => /xlayer/.test(e.name)); return r.length + " RPC requests, finished at " + Math.round(Math.max(...r.map((e) => e.responseEnd))) + " ms"; })()`));
  check(`${label}: spec is read from the expected CurvePad`, (await p.ev(text())).toLowerCase().includes(PAD));
  check(`${label}: real logo loaded`, await p.until(`(() => { const i = document.querySelector(".brand img"); return i.complete && i.naturalWidth > 0; })()`, 15000));
  check(`${label}: no pink in the UI`, !(await p.ev(`getComputedStyle(document.documentElement).getPropertyValue("--hub")`)).toLowerCase().includes("ea3680"));
  const foot = await p.ev(text("footer"));
  check(`${label}: footer has the copyright and not the old line`, foot.includes("Syketex Technologies") && !/non-custodial|read from the chain|\(196\)/.test(foot));
  if (STAGING) {
    check(`${label}: every token row has 5M, 30M, 1H and 24H`, await p.ev(`[...document.querySelectorAll("a.row")].every((r) => r.querySelectorAll(".chg").length === 4)`));
    check(`${label}: a dumped token shows a red change`, await p.ev(`document.querySelectorAll("a.row .chg.down").length > 0`), await p.ev(`[...document.querySelectorAll("a.row")].map((r) => [...r.querySelectorAll(".chg")].map((c) => c.innerText).join(" ")).join(" | ")`));
  }
  if (STAGING) {
    for (const v of ["table", "board", "race"]) {
      await p.ev(`document.querySelector('[data-view="${v}"]').click()`);
      await sleep(150);
      check(`${label}: ${v} view shows real tokens`, /DOUG|FRUST/.test(await p.ev(text("#floor-view"))));
      check(`${label}: ${v} view has no sideways scrolling`, await p.ev(`document.documentElement.scrollWidth <= innerWidth`));
      await p.ev(`document.querySelector(".floor-tools").scrollIntoView({ block: "start" }); scrollBy(0, -70)`);
      await sleep(150);
      await p.shot(`${label}-view-${v}`);
    }
    await p.ev(`document.querySelector('[data-view="table"]').click()`);
    await p.ev(`document.querySelector('[data-sort="age"]').click()`);
    await sleep(100);
    const oldest = await p.ev(`document.querySelector("a.f-row b").innerText`);
    check(`${label}: table sorts`, oldest === "CIRCTEST", oldest);
    await p.ev(`document.querySelector('[data-view="wafer"]').click()`);
    const search = async (q) => { await p.ev(`(() => { const i = document.querySelector("#floor-q"); i.value = ${JSON.stringify(q)}; i.dispatchEvent(new Event("input", { bubbles: true })); })()`); await sleep(100); return p.ev(text("#floor-view")); };
    const hit = await search("doug");
    check(`${label}: search finds a token, keeps the box`, /DOUG/.test(hit) && !/CIRCTEST/.test(hit) && await p.ev(`!!document.querySelector("#floor-q")`));
    check(`${label}: search by Nand number`, /DOUG/.test(await search("nand 13")));
    check(`${label}: search with no match says so`, /Nothing matches/.test(await search("zzzzz")));
    await search("");
    await p.ev(`document.querySelector('[data-filter="uni"]').click()`);
    await sleep(100);
    check(`${label}: On Uniswap filter applies`, /DOUG/.test(await p.ev(text("#floor-view"))));
    await p.ev(`document.querySelector('[data-filter="all"]').click()`);
    await sleep(100);
  }
  check(`${label}: progress line is gone from the homepage`, !(await p.ev(`document.querySelector(".trace")`)));
  if (STAGING) check(`${label}: ticker shows a launch`, /NEW/.test(await p.ev(`document.querySelector("#ticker")?.textContent || ""`)));
  check(`${label}: no gallery button`, !(await p.ev(`document.querySelector('[data-view="gallery"]')`)));
  check(`${label}: king of the hill is on the floor`, /King of the hill/i.test(await p.ev(text("#app"))));
  if (STAGING) { // every TEST token is on Uniswap, so draw the card with one put back on the curve, in this page only
    const crowned = await p.ev(`(() => { const x = state.launches[0]; x.status = 0; x.progress = 72; document.querySelector("#app .king").outerHTML = kingCard(); return document.querySelector("a.king b").innerText; })()`);
    check(`${label}: king card shows a token on the curve`, crowned.length > 0, crowned);
    await p.ev(`document.querySelector(".king").scrollIntoView({ block: "center" })`);
    await sleep(150);
    await p.shot(`${label}-king`);
    await p.ev(`viewFloor()`);
    await sleep(100);
  }
  check(`${label}: only the kept sort and filter buttons exist`, await p.ev(`document.querySelectorAll("#sort-list [data-order]").length === 7 && document.querySelectorAll("[data-filter]").length === 3 && !document.querySelector('[data-filter="near"], [data-filter="live"]') && !!document.querySelector('[data-filter="watch"]')`));
  if (STAGING) {
    await p.ev(`localStorage.removeItem("circ.watch")`);
    const firstAfter = async (order) => { await p.ev(`document.querySelector("#sort-btn").click()`); await p.ev(`document.querySelector('#sort-list [data-order="${order}"]').click()`); await sleep(120); return p.ev(`document.querySelector("#floor-view a.row small").innerText.split(" ")[0].slice(1)`); };
    const sym = (e) => p.ev(`(() => { const a = [...state.launches].sort((x, y) => ${e}); return a[0].symbol; })()`);
    await p.ev(`document.querySelector("#sort-btn").click()`);
    check(`${label}: sort menu opens`, await p.ev(`!document.querySelector("#sort-list").hidden`));
    check(`${label}: sort menu stays inside the screen`, await p.ev(`document.querySelector("#sort-list").getBoundingClientRect().right <= innerWidth`));
    await p.ev(`document.querySelector("#sort-list").scrollIntoView({ block: "center" })`);
    await sleep(150);
    await p.shot(`${label}-sort-menu`);
    await p.ev(`document.body.click()`);
    check(`${label}: tapping elsewhere closes the sort menu`, await p.ev(`document.querySelector("#sort-list").hidden`));
    check(`${label}: sort: newly launched`, (await firstAfter("new")) === await sym("y.block - x.block"));
    check(`${label}: sort: oldest first`, (await firstAfter("old")) === await sym("x.block - y.block"));
    const hi = await firstAfter("mc-high"), lo = await firstAfter("mc-low");
    check(`${label}: sort: highest and lowest market cap`, hi === await sym("y.mcUsd - x.mcUsd") && lo === await sym("x.mcUsd - y.mcUsd"), `${hi} / ${lo}`);
    for (const o of ["near", "up", "down"]) check(`${label}: sort: ${o} still lists every token`, (await firstAfter(o)) && await p.ev(`document.querySelectorAll("#floor-view a.row:not(.head)").length === state.launches.length`));
    await firstAfter("new");
    const opened = await p.ev(`(() => { const before = location.hash; document.querySelector("[data-star]").click(); return location.hash === before; })()`);
    check(`${label}: starring doesn't open the token`, opened);
    await p.ev(`document.querySelector('[data-filter="watch"]').click()`);
    await sleep(100);
    check(`${label}: watchlist shows only the starred token`, await p.ev(`document.querySelectorAll("#floor-view a.row").length === 1`));
    check(`${label}: watchlist survives in this browser`, await p.ev(`JSON.parse(localStorage.getItem("circ.watch")).length === 1`));
    await p.ev(`document.querySelector("#floor-view [data-star]").click()`);
    await sleep(100);
    check(`${label}: unstarring empties it, with a hint`, /watchlist is empty/.test(await p.ev(text("#floor-view"))));
    await p.ev(`document.querySelector('[data-filter="all"]').click()`);
    await sleep(100);
    check(`${label}: latest-trades ticker shows real trades`, /BUY|SELL/.test(await p.ev(text("#ticker"))));
    await p.ev(`window.dispatchEvent(new KeyboardEvent("x")); document.dispatchEvent(new KeyboardEvent("keydown", { key: "/", bubbles: true }))`);
    check(`${label}: "/" focuses search`, await p.ev(`document.activeElement?.id === "floor-q"`));
    await p.ev(`document.activeElement.blur()`);
  }
  await p.ev(`confetti()`);
  check(`${label}: confetti runs`, await p.ev(`!!document.querySelector("#confetti")`));
  await sleep(700);
  await p.shot(`${label}-confetti`);
  check(`${label}: confetti clears itself`, await p.until(`!document.querySelector("#confetti")`, 8000));
  await p.ev(`document.querySelector("a.row")?.scrollIntoView({ block: "center" })`);
  await sleep(300);
  await p.shot(`${label}-rows`);
  check(`${label}: no sideways scrolling`, await p.ev(`document.documentElement.scrollWidth <= innerWidth`));
  check(`${label}: no instance switch or preview wording`, !/Preview data/i.test(await p.ev(text())) && !(await p.ev(`document.querySelector("#inst")`)) && !/\bMainnet\b/.test(await p.ev(text("header"))));
  check(`${label}: banner matches the site`, STAGING ? (await p.ev(text("#banner"))).includes("STAGING") : await p.ev(`document.querySelector("#banner").hidden`));
  check(`${label}: nothing wider than the screen`, await p.ev(`document.documentElement.scrollWidth <= innerWidth`), await p.ev(`document.documentElement.scrollWidth + " vs " + innerWidth`));
  check(`${label}: Connect button fully on screen`, await p.ev(`(() => { const r = document.querySelector("#connect").getBoundingClientRect(); return r.right <= innerWidth && r.left >= 0; })()`));
  check(`${label}: nav reaches Launch and Creator fees`, await p.ev(`[...document.querySelectorAll("nav.links a")].filter((a) => a.getBoundingClientRect().width > 0).length === 3`));
  await p.shot(`${label}-home`);

  await go(p, "#/launch");
  await p.until(`document.querySelector(".nand.mint")`);
  check(`${label}: Connect is pressable with nothing selected (M8)`, await p.ev(`!document.querySelector("#cont").disabled`));
  await p.ev(`document.querySelector("#connect").click()`);
  check(`${label}: wallet chooser lists both injected wallets (EIP-6963)`, await p.until(`document.querySelectorAll(".wallets button.w").length === 2`, 15000));
  await p.shot(`${label}-chooser`);
  await p.ev(`document.querySelector(".wallets button.w").click()`);
  check(`${label}: holder's Nands are listed`, await p.until(`document.querySelectorAll(".nand[data-id]").length >= 11`), await p.ev(`document.querySelectorAll(".nand[data-id]").length + " rows"`));
  const next = (await lastNand()) + 1;
  const list = await p.ev(text("#nandlist"));
  check(`${label}: holder's #11 is listed, next mint is #${next} (H1)`, list.includes("#11") && list.includes(`next Nand (#${next})`), list.split("\n").slice(0, 3).join(" | ").slice(0, 110));
  await p.shot(`${label}-picker`);
  await p.ev(`document.querySelector('.nand[data-id="4"]').click(); document.querySelector("#cont").click()`);
  await p.until(`document.querySelector("#name")`);
  await p.ev(`(() => { const set = (id, v) => { const e = document.querySelector(id); e.value = v; e.dispatchEvent(new Event("input", { bubbles: true })); }; set("#name", "Browser Test"); set("#sym", "BT"); document.querySelector("#next").click(); })()`);
  check(`${label}: confirm sheet warns one launch per Circuit`, await p.until(`${text()}.includes("Each Circuit can launch one token, ever. This uses it up.")`));
  check(`${label}: no "mainnet" label on the confirm sheet`, !/mainnet/i.test(await p.ev(text())));
  await p.shot(`${label}-confirm`);
  await p.ev(`(() => { const a = document.querySelector("#ack"); a.checked = true; a.dispatchEvent(new Event("change", { bubbles: true })); document.querySelector("#go").click(); })()`);
  await p.until(`window.__tx.length > 0`, 30000);
  const tx = await p.ev(`window.__tx[0] || null`);
  check(`${label}: launch would go to the expected CurvePad, and the mock wallet rejected it`, tx && tx.to?.toLowerCase() === PAD, tx ? tx.to : "no tx");
  check(`${label}: rejection shown, retry offered`, await p.until(`${text("#runlog")}.includes("error")`, 10000));

  if (STAGING) { // token pages need a launch, so they are tested where one exists
  await go(p, "#/t/" + TEST_TOKEN);
  check(`${label}: token page shows Dev holds`, await p.until(`${text()}.includes("Dev holds")`), (await p.ev(`[...document.querySelectorAll(".pill")].map((x) => x.innerText).join(" | ")`)).slice(0, 90));
  check(`${label}: taped-out token has an in-app swap box (H6)`, await p.until(`document.querySelector("#tradebox .trade-tabs")`));
  check(`${label}: creator panel shows Container and withdraw options (H5)`, await p.until(`${text("#creator")}.includes("Container balance")`, 40000));
  await p.ev(`(() => { const e = document.querySelector("#amt"); e.value = "0.001"; e.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  check(`${label}: pool quote works through the Quoter`, await p.until(`${text("#pv")}.includes("Minimum")`, 30000), (await p.ev(text("#pv"))).replace(/\n/g, " ").slice(0, 80));
  const logo = await p.until(`(() => { const i = document.querySelector(".tp-head .av img"); return i && i.complete && i.naturalWidth > 0; })()`, 40000);
  console.log(`${logo ? "PASS" : "INFO"}  ${label}: IPFS logo ${logo ? "loaded" : "didn't load from the gateways from this server (initials shown)"}`);
  check(`${label}: token page has the price chart`, await p.until(`!!document.querySelector("#price-chart polyline")`, 15000));
  const page = await p.ev(text("#app"));
  check(`${label}: token page has the bonding curve, without its removed text, wire or progress line`, /Bonding curve/.test(page) && !/x·y=k|Signal to the gate/.test(page) && !(await p.ev(`document.querySelector("#app .trace, svg.wire")`)));
  const tp = await p.ev(text("#app"));
  check(`${label}: token details shown, fee card gone`, /Token details/.test(tp) && !/Where the/.test(tp));
  check(`${label}: copy buttons use the icon`, await p.ev(`[...document.querySelectorAll(".copy, .copy-ca")].every((b) => b.querySelector("svg.ic") && !/copy/i.test(b.innerText))`));
  await p.ev(`(() => { window.__fetch = fetch; window.fetch = async (u, o) => { const r = await window.__fetch(u, o); if (!/data\\/index-/.test(String(u))) return r; const d = await r.json(); const L = d.launches[location.hash.slice(4).toLowerCase()]; if (L) L.trades.push({ b: 1, i: 0, ts: Math.floor(Date.now() / 1000), tx: "0x" + "ab".repeat(32), who: "0x" + "11".repeat(20), buy: true, q: "1000000000000000", t: "123450000000000000000000000", fee: "0" }); return new Response(JSON.stringify(d)); }; })()`);
  check(`${label}: a new trade appears without a refresh`, await p.until(`${text("#tape-card")}.includes("123.45M")`, 15000));
  await p.ev(`(window.fetch = window.__fetch, 0)`);
  check(`${label}: contract address can be copied`, await p.ev(`document.querySelector(".copy-ca").dataset.copy.toLowerCase() === location.hash.slice(4).toLowerCase()`));
  await p.ev(`scrollTo(0, 0)`);
  await sleep(300);
  check(`${label}: trade button visible only on a phone`, await p.ev(`getComputedStyle(document.querySelector(".trade-dock")).display`) === (label === "phone" ? "block" : "none"));
  if (label === "phone") {
    check(`${label}: trade button stays inside the screen`, await p.ev(`document.querySelector(".trade-dock").getBoundingClientRect().right <= innerWidth`));
    await p.ev(`document.querySelector("#tradebox").scrollIntoView()`);
    await sleep(300);
    check(`${label}: trade button gets out of the way of the panel`, await p.ev(`getComputedStyle(document.querySelector(".trade-dock")).display`) === "none");
  }
  check(`${label}: trade panel has 25%, 50% and Max`, (await p.ev(`[...document.querySelectorAll("#tradebox .quick.pct button")].map((b) => b.innerText).join()`)) === "25%,50%,Max");
  await p.until(`/balance \\d/.test(document.querySelector("#tradebox #bal")?.innerText || "")`, 15000);
  const balOkb = Number((await p.ev(`document.querySelector("#tradebox #bal").innerText`)).replace(/[^0-9.]/g, ""));
  await p.ev(`document.querySelector('#tradebox .quick.pct [data-p="100"]').click()`);
  const maxBuy = Number(await p.ev(`document.querySelector("#tradebox #amt").value`));
  check(`${label}: Max buy keeps gas back`, maxBuy > 0 && Math.abs(balOkb - 0.0002 - maxBuy) < 0.0001, `balance ${balOkb}, Max ${maxBuy}`);
  await p.ev(`document.querySelector('#tradebox .quick.pct [data-p="50"]').click()`);
  const halfBuy = Number(await p.ev(`document.querySelector("#tradebox #amt").value`));
  check(`${label}: 50% is half of Max`, Math.abs(halfBuy - maxBuy / 2) < 0.00001, String(halfBuy));
  await p.until(`/You receive/.test(document.querySelector("#tradebox #pv")?.innerText || "")`, 15000);
  await p.ev(`document.querySelector('#tradebox .trade-tabs .sell').click()`);
  await p.until(`/balance \\d/.test(document.querySelector("#tradebox #bal")?.innerText || "")`, 15000);
  await sleep(1500);
  const sellBal = Number((await p.ev(`document.querySelector("#tradebox #bal").innerText`)).replace(/[^0-9.]/g, ""));
  await p.ev(`document.querySelector('#tradebox .quick.pct [data-p="100"]').click()`);
  const maxSell = await p.ev(`document.querySelector("#tradebox #amt").value`);
  check(`${label}: Max sell uses the token balance`, sellBal > 0 ? Number(maxSell) > 0 : maxSell === "", `balance ${sellBal}, Max ${maxSell || "none"}`);
  await p.ev(`document.querySelector('#tradebox .trade-tabs .buy').click()`);
  await p.ev(`document.querySelector('[data-frame="5M"]').click()`);
  await sleep(100);
  check(`${label}: chart window switches`, (await p.ev(text("#price-chart"))).includes("in 5M"));
  await p.ev(`document.querySelector("#price-chart")?.scrollIntoView({ block: "start" })`);
  await sleep(200);
  await p.shot(`${label}-chart`);
  await p.shot(`${label}-token`);
  }
  const csp = await p.ev(`window.__csp`);
  check(`${label}: no CSP violations`, csp.length === 0, csp.slice(0, 3).join("; "));
  // The public RPC's rate-limit replies show up as CORS errors; reads retry them, so they aren't failures. Count them anyway.
  const rpcLimited = p.problems.filter((x) => /rpc\.xlayer\.tech/.test(x)).length;
  if (rpcLimited) console.log(`INFO  ${label}: ${rpcLimited} RPC request(s) rate-limited or dropped, then retried`);
  const bad = p.problems.filter((x) => !/429|Too Many|ERR_|Failed to load resource|rpc\.xlayer\.tech/.test(x));
  check(`${label}: no uncaught page errors`, bad.length === 0, bad.slice(0, 2).join(" || "));
  // Wallet: stays connected across a reload with no prompt, menu with copy and disconnect
  await p.send("Page.reload");
  check(`${label}: still connected after a reload`, await p.until(`document.querySelector("#connect")?.innerText?.startsWith("0x")`, 20000));
  check(`${label}: the reload asked the wallet nothing`, !(await p.ev(`window.__prompts || 0`)));
  await p.until(`${text()}.length > 200`);
  await p.ev(`document.querySelector("#connect").click()`);
  check(`${label}: tapping the wallet opens the menu`, await p.ev(`!!document.querySelector("#wallet-menu")`));
  check(`${label}: menu has the copy icon with the full address`, await p.ev(`document.querySelector("#wallet-menu [data-copy] svg.ic") && document.querySelector("#wallet-menu [data-copy]").dataset.copy.length === 42`));
  check(`${label}: menu stays inside the screen`, await p.ev(`(() => { const r = document.querySelector("#wallet-menu").getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth; })()`));
  await p.shot(`${label}-wallet-menu`);
  await p.ev(`document.body.click()`);
  check(`${label}: tapping elsewhere closes the menu`, await p.ev(`!document.querySelector("#wallet-menu")`));
  await p.ev(`document.querySelector("#connect").click(); document.querySelector("#wm-off").click()`);
  check(`${label}: Disconnect works`, await p.until(`document.querySelector("#connect")?.innerText === "Connect"`, 5000));
  check(`${label}: Disconnect forgets the wallet`, await p.ev(`localStorage.getItem("circ.wallet") === null`));
  await p.send("Page.reload");
  await sleep(3500);
  check(`${label}: stays disconnected after a reload`, await p.ev(`document.querySelector("#connect").innerText === "Connect"`));
  await p.send("Page.close").catch(() => {});
}

// Phone browser with no wallet at all
{
  const p = await open();
  await p.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 900, deviceScaleFactor: 1, mobile: true });
  await p.send("Emulation.setUserAgentOverride", { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148" });
  await go(p, "#/");
  await p.until(`${text()}.includes("Tape-out raise (WOKB)")`);
  await p.ev(`document.querySelector("#connect").click()`);
  check("no wallet on a phone: offers Open in OKX Wallet", await p.until(`[...document.querySelectorAll(".wallets a")].some((a) => a.href.startsWith("https://web3.okx.com/download?deeplink=") && a.innerText.includes("Open in OKX Wallet"))`, 15000));
  await p.shot("phone-no-wallet");
}
console.log(failed ? `\n${failed} FAILED` : "\nALL PASSED");
cleanup();
process.exit(failed ? 1 : 0);
