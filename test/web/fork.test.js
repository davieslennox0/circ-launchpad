// Real-chain test of the frontend's logic on an anvil fork of X Layer: the same core.js the site runs, with real Nandout,
// TapeOut, Uniswap v4 and Universal Router. Needs E2E_RPC (anvil) and CIRC_PAD (a CIRC-TEST pad deployed there); skipped otherwise.
const test = require("node:test");
const assert = require("node:assert");
const E = require("../../web/vendor/ethers-6.13.4.umd.min.js");
const core = require("../../web/core.js");

const RPC = process.env.E2E_RPC, PAD = process.env.CIRC_PAD;
const A = { WOKB: "0xe538905cf8410324e03A5A23C1c177a474D59b2b", NANDOUT: "0x8A60B4A4BCf4066F5E5F9A406fE09c5e4f52a58E", OPENER: "0x536adD8F30f03b69f6fbF29d425A816A0dC50106",
  UR: "0x1cd182C94fcF42277B80DBB9060F88024809E61E", PERMIT2: "0x000000000022D473030F116dDEE9F6B43aC78BA3", QUOTER: "0x8928074CA1b241D8Ec02815881c1Af11E8bC5219", SV: "0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990" };

test("frontend logic against real contracts", { skip: !RPC || !PAD }, async (t) => {
  const rp = new E.JsonRpcProvider(RPC, 196, { staticNetwork: true, batchMaxCount: 1 });
  rp.pollingInterval = 100;
  const user = E.Wallet.createRandom().connect(rp);
  await rp.send("anvil_setBalance", [user.address, E.toBeHex(E.parseEther("1000"))]);
  let nonce = await rp.getTransactionCount(user.address);
  const ov = (o = {}) => ({ nonce: nonce++, ...o });
  const sent = async (p) => { const r = await (await p).wait(); assert.equal(r.status, 1); return r; };

  const pad = new E.Contract(PAD, [
    "function createLaunch(address,uint256,string,string,string,address,uint256,uint256) payable returns (address)",
    "function curves(address) view returns (address quote,uint128 vQuote,uint128 vToken,uint128 realQuote,uint128 tokensLeft,address container,address circuitNft,uint256 circuitId,uint64 launchBlock,uint8 status)",
    "function buyWithOKB(address,uint256,uint256) payable returns (uint256)", "function previewBuy(address,uint256) view returns (uint256,uint256)",
    "function graduate(address)", "function graduator() view returns (address)", "function locker() view returns (address)",
    "function MAX_EARLY_BUY() view returns (uint256)", "function GUARD_BLOCKS() view returns (uint256)", "function earlyBlock(address) view returns (uint64 blockNumber,uint192 sold)",
    "function claimCreator(address,address,bool)", "function accrued(address,address) view returns (uint256)",
    "function isLaunched(address,uint256) view returns (bool)",
    "event LaunchCreated(address indexed token,address indexed quote,address indexed circuitNft,uint256 circuitId,address container,address creator,string imageURI)",
    "event Graduated(address indexed token,bytes32 indexed poolId,uint256 positionId,uint256 raised,uint256 lpTokens)"], user);
  const nand = new E.Contract(A.NANDOUT, ["function nextId() view returns (uint256)", "function transistors() view returns (address)", "function TAPEOUT_FEE() view returns (uint256)", "function ownerOf(uint256) view returns (address)",
    "function tapeout(bytes,uint32,uint32) payable returns (uint256)", "event TapedOut(uint256 indexed circuitId, address indexed author, uint32 gateCount, uint32 nState)"], user);
  const trans = new E.Contract(await nand.transistors(), ["function mintPrice() view returns (uint256)", "function protocolFee() view returns (uint256)", "function mint(uint256,uint256) payable"], user);
  const erc = (a) => new E.Contract(a, ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"], user);

  let id, token, container, poolId, positionId, key;

  await t.test("H1: nextId() is the LAST minted id; a mint gets nextNandId()", async () => {
    const last = await nand.nextId();
    assert.ok(core.nandIds(last).includes(Number(last)), "the latest Nand is in the list");
    assert.equal(await nand.ownerOf(last) !== E.ZeroAddress, true, "the id nextId() returns exists");
    await assert.rejects(nand.ownerOf(core.nextNandId(last)), "the next id does not exist yet");
    await sent(trans.mint(0, 1, ov({ value: (await trans.mintPrice()) + (await trans.protocolFee()) })));
    const r = await sent(nand.tapeout("0x00000002000003", 2, 1, ov({ value: await nand.TAPEOUT_FEE() })));
    id = Number(r.logs.map((l) => { try { return nand.interface.parseLog(l); } catch { return null; } }).find((e) => e?.name === "TapedOut").args.circuitId);
    assert.equal(id, core.nextNandId(last));
  });

  await t.test("launch: imageURI round-trips and passes safeImage", async () => {
    const uri = "ipfs://bafkreifgwgniocoza3oetpvyllyxb2tlbnvn7sgywmnbwxcb4tcnkc6qsu";
    const r = await sent(pad.createLaunch(A.NANDOUT, id, "Web Test", "WEB", uri, A.WOKB, 0, 0, ov()));
    const ev = r.logs.map((l) => { try { return pad.interface.parseLog(l); } catch { return null; } }).find((e) => e?.name === "LaunchCreated");
    token = ev.args.token; container = ev.args.container;
    assert.ok(core.safeImage(ev.args.imageURI, token, new Set()));
    assert.equal(await pad.isLaunched(A.NANDOUT, id), true);
  });

  await t.test("H3: previewCurveBuy matches what the contract does inside the guard", async () => {
    const c = await pad.curves(token), maxEarly = await pad.MAX_EARLY_BUY(), q = E.parseEther("0.05");
    const head = await rp.getBlockNumber();
    assert.ok(head + 1 < Number(c.launchBlock) + Number(await pad.GUARD_BLOCKS()), "still guarded");
    const p = core.previewCurveBuy({ vQuote: c.vQuote, vToken: c.vToken, tokensLeft: c.tokensLeft, quoteIn: q, feeBps: 100n, guarded: true, maxEarly, soldThisBlock: 0n });
    assert.equal(p.capped, true);
    assert.equal(p.out, maxEarly);
    const tb = await erc(token).balanceOf(user.address), ob = await rp.getBalance(user.address);
    await sent(pad.buyWithOKB(token, p.minOut, 2n ** 40n, ov({ value: q })));
    assert.equal((await erc(token).balanceOf(user.address)) - tb, p.out, "tokens exactly as previewed");
    const spent = ob - (await rp.getBalance(user.address));
    assert.ok(spent >= p.used && spent - p.used < E.parseEther("0.01"), "excess refunded: only `used` plus gas spent");
  });

  await t.test("graduate", async () => {
    const c = await pad.curves(token);
    await rp.send("anvil_mine", [E.toBeHex(40)]);
    const [, need] = await pad.previewBuy(token, 2n ** 128n - 1n);
    await sent(pad.buyWithOKB(token, 0, 2n ** 40n, ov({ value: need })));
    const r = await sent(pad.graduate(token, ov()));
    const ev = r.logs.map((l) => { try { return pad.interface.parseLog(l); } catch { return null; } }).find((e) => e?.name === "Graduated");
    poolId = ev.args.poolId; positionId = ev.args.positionId;
    const g = new E.Contract(await pad.graduator(), ["function poolKey(address,address) view returns (tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks))"], rp);
    key = await g.poolKey(token, c.quote);
  });

  const z = E.AbiCoder.defaultAbiCoder();
  const ur = new E.Contract(A.UR, ["function execute(bytes,bytes[],uint256) payable"], user);
  const quote = async (tokenIn, amountIn) => {
    const q = new E.Contract(A.QUOTER, ["function quoteExactInputSingle(tuple(tuple(address,address,uint24,int24,address),bool,uint128,bytes)) returns (uint256,uint256)"], rp);
    const [out] = await q.quoteExactInputSingle.staticCall([[key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks], tokenIn.toLowerCase() === key.currency0.toLowerCase(), amountIn, "0x"]);
    return out;
  };

  await t.test("H6: buy with native OKB through Universal Router", async () => {
    const amountIn = E.parseEther("0.5"), out = await quote(A.WOKB, amountIn), minOut = (out * 99n) / 100n, before = await erc(token).balanceOf(user.address);
    const c = core.encodeSwap(z, { key, tokenIn: A.WOKB, tokenOut: token, amountIn, minOut, native: "in" });
    await sent(ur.execute(c.commands, c.inputs, 2n ** 40n, ov({ value: c.value })));
    assert.equal((await erc(token).balanceOf(user.address)) - before, out, "exactly the quoted tokens");
  });

  await t.test("H6: sell for native OKB through Permit2 + Universal Router", async () => {
    const amountIn = E.parseEther("1000000"), out = await quote(token, amountIn), minOut = (out * 99n) / 100n;
    await sent(erc(token).approve(A.PERMIT2, amountIn, ov()));
    const pm = new E.Contract(A.PERMIT2, ["function approve(address,address,uint160,uint48)"], user);
    await sent(pm.approve(token, A.UR, amountIn, 2n ** 40n, ov()));
    const before = await rp.getBalance(user.address);
    const c = core.encodeSwap(z, { key, tokenIn: token, tokenOut: A.WOKB, amountIn, minOut, native: "out" });
    const r = await sent(ur.execute(c.commands, c.inputs, 2n ** 40n, ov()));
    const gas = r.gasUsed * r.gasPrice;
    assert.equal((await rp.getBalance(user.address)) + gas - before, out, "exactly the quoted amount, as native OKB");
    assert.equal(await erc(A.WOKB).balanceOf(A.UR), 0n, "nothing left in the router");
  });

  await t.test("H4: uncollected LP fees computed client-side equal what collect() pays", async () => {
    const sv = new E.Contract(A.SV, ["function getFeeGrowthInside(bytes32,int24,int24) view returns (uint256,uint256)", "function getPositionInfo(bytes32,address,int24,int24,bytes32) view returns (uint128,uint256,uint256)"], rp);
    const locker = new E.Contract(await pad.locker(), ["function positionManager() view returns (address)", "function collect(uint256)", "event Collected(uint256 indexed positionId,uint256 amount0,uint256 amount1)"], user);
    const posm = await locker.positionManager(), lo = -887200, hi = 887200, salt = E.zeroPadValue(E.toBeHex(positionId), 32);
    const [[n0, n1], [liq, l0, l1]] = await Promise.all([sv.getFeeGrowthInside(poolId, lo, hi), sv.getPositionInfo(poolId, posm, lo, hi, salt)]);
    const f0 = core.uncollectedFee(liq, n0, l0), f1 = core.uncollectedFee(liq, n1, l1);
    assert.ok(f0 > 0n && f1 > 0n, "fees in both currencies");
    const r = await sent(locker.collect(positionId, ov()));
    const ev = r.logs.map((l) => { try { return locker.interface.parseLog(l); } catch { return null; } }).find((e) => e?.name === "Collected");
    assert.equal(ev.args.amount0, f0); assert.equal(ev.args.amount1, f1);
  });

  await t.test("H5/M12: Container: unopened, then open, fee parsed from the revert, then withdraw", async () => {
    const data = new E.Interface(["function execute(address,uint256,bytes,uint8) payable returns (bytes)"]);
    const probe = async () => { try { await rp.call({ to: container, from: user.address, data: data.encodeFunctionData("execute", [E.ZeroAddress, 0, "0x", 0]) }); return { state: "open", fee: 0n }; } catch (e) { return core.parseContainerRevert(e?.data || e?.info?.error?.data || e?.revert?.data); } };
    assert.equal(await rp.getCode(container), "0x", "a fresh Nand's Container has no code");
    const op = new E.Contract(A.OPENER, ["function FEE() view returns (uint256)", "function open(address,uint256) payable"], user);
    await sent(op.open(A.NANDOUT, id, ov({ value: await op.FEE() })));
    const s = await probe();
    assert.equal(s.state, "open"); assert.ok(s.fee > 0n, "fee read from the revert");
    const owed = await pad.accrued(A.WOKB, container);
    assert.ok(owed > 0n);
    await sent(pad.claimCreator(container, A.WOKB, false, ov()));
    assert.equal(await erc(A.WOKB).balanceOf(container), owed);
    const xfer = new E.Interface(["function transfer(address,uint256)"]).encodeFunctionData("transfer", [user.address, owed]);
    const before = await erc(A.WOKB).balanceOf(user.address);
    await sent(new E.Contract(container, data, user).execute(A.WOKB, 0, xfer, 0, ov({ value: s.fee })));
    assert.equal((await erc(A.WOKB).balanceOf(user.address)) - before, owed);
  });
});
