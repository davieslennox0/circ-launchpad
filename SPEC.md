# Circ Launchpad — Spec

The build spec as given by the project owner on 2026-10-29. Amendments the owner made later come first. Where an amendment
conflicts with the original text below, the amendment wins.

## Amendments

**A1. Curve targets (2026-10-29, replaces the "target raise" line in 5.2).**
Launch market cap ≈ $4,000, graduation market cap ≈ $69,000 (market cap = price × 1B), solved together with
`curveSupply + lpTokens == 1e27` at recon-time prices. If both can't be hit, prioritise graduation. Report R in USD at GATE 1.
Both targets are hit exactly; see `script/solve_constants.py` and `script/CurveConstants.sol`.

**A2. GATE 0 decisions (2026-10-29).**
1. Creators open their Container themselves (v1). There is also a fallback claim path: the Circuit NFT's current holder
   may route accrued creator fees to their own wallet instead of the Container. It is holder-gated via `ownerOf` at claim
   time (`FeeVault.claimCreator(container, asset, toHolder)`). It covers a future TapeOut upgrade breaking Container withdrawals.
2. BEM ships as specced. Fork tests cover the 8-decimal BEM lifecycle end to end. **BEM on X Layer is a LayerZero OFT whose
   peers and config are controlled by the TapeOut 3-of-5 Safe `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138`** (the same Safe
   that can upgrade the TapeOut factory and Container beacon).
3. No testnet (v3 isn't on 1952). Mainnet deploy happens only after the anvil fork dry run, with explicit owner go-ahead.
   Before GATE 2: run Slither and fix or justify every finding, and have an independent reviewer (who didn't write the code)
   audit CurvePad, LaunchToken and PositionLocker against this file.

**A3. Code size (2026-10-29).** No size-check bypass. CurvePad deploys two admin-less helpers in its constructor, so the
wiring is immutable and set at deploy time:
- **TokenDeployer** does the CREATE2 deploy of LaunchToken. LaunchToken takes CurvePad as its controller explicitly
  (`markGraduated` is CurvePad-only), and `predictedPool` depends only on the token's own address.
- **Graduator** handles pool get/create, normalisation, the full-range mint and sending the NFT to PositionLocker.
  Only CurvePad can call it, and it holds no funds between calls.

PositionLocker accepts NFTs only from CurvePad's Graduator. CI fails if any runtime is over 24,576 B or any initcode is
over 49,152 B.

**A4. Graduation decoupled from the filling buy (2026-10-29, replaces 6.2 "graduate(token) is internal").**
- The buy that sells the last curve token marks the curve **Complete** and emits `CurveCompleted(token)`. No more buys
  or sells after that.
- `graduate(token)` is permissionless and callable once the curve is Complete. It is retryable: if it reverts (for
  example `NormalizeTooCostly` on a griefed pool), the curve stays Complete and its funds stay in CurvePad.
- Lifecycle: Trading → Complete → Graduated.

**A5. Graduation venue: Uniswap v4 with the Circ hook (2026-10-30, replaces the v3 venue in sections 2 and 6.2,
the pool lock in 6.1, and price normalisation).**
- The pool key is (token, quote, fee 10000, tickSpacing 200, CircHook).
- CircHook has no admin and is immutable. It has only `beforeInitialize` and `beforeAddLiquidity`: no swap hooks, no
  delta flags, and its address doesn't start with `0x91`, so it stays on Uniswap's routing auto-allowlist.
  - `beforeInitialize` reverts unless the sender is Graduator.
  - `beforeAddLiquidity` reverts unless Graduator authorised that exact add. Graduator authorises one add for one pool,
    held in transient storage for that transaction, then mints through the v4 PositionManager, which is the `sender`
    the PoolManager reports.
- Graduator initializes at exactly P_end, mints full range and sends the NFT to PositionLocker. The normalisation swap,
  `NormalizeTooCostly` and the LaunchToken pool lock are deleted, and LaunchToken is a plain fixed-supply ERC-20.
- The Complete status and the permissionless, retryable `graduate()` (A4) stay.
- PositionLocker holds v4 position NFTs with no decrease, burn or transfer path. `collect` runs DECREASE_LIQUIDITY(0) +
  TAKE_PAIR and splits what that call brought in.

**A6. Anti-snipe (2026-10-30, replaces 5.3's per-buy cap).** During GUARD_BLOCKS, MAX_EARLY_BUY caps the total curve
tokens bought per block across all buyers and calls. The dev-buy stays exempt and isn't counted.

**A7. GATE 1 changes (2026-10-30).**
- **Hook:** liquidity adds are gated only until the pool's graduation mint has fully settled. Then Graduator opens the
  pool (`CircHook.openPool`), and anyone may add or remove their own liquidity. The locked graduation position stays
  unremovable: PositionLocker has no path to remove it. The one-shot add authorisation is keyed to the poolId, held in
  transient storage, and consumed inside `beforeAddLiquidity` on first use. A reentrant second add during settlement
  reverts.
- **Anti-snipe:** GUARD_BLOCKS = 30, and the per-block cap is 0.5% of supply (5M tokens).
- **Deploy:** curve `vQuote0` values are regenerated from live on-chain prices at deploy time (`script/LivePrices.sol`)
  and printed. A broadcast must carry the owner-approved values and refuses if live prices have moved them more than 2%.

**A8. One launch per Circuit (2026-11-01).** `createLaunch` records `(circuitNft, circuitId)` on first use and reverts
`AlreadyLaunched` on any later attempt: same or different name/ticker/quote, same or new holder. The flag is permanent
and survives NFT transfers. `isLaunched(circuitNft, circuitId)` exposes it for frontends. Before A8, CurvePad only
blocked an exact CREATE2 collision (same holder, name and ticker), so a Circuit could back several launches paying one
Container. Production was redeployed with A8 before the first launch.

**A9. Token logo URI (2026-11-01).** `createLaunch(circuitNft, circuitId, name, symbol, imageURI, quote, devBuyAmount,
devBuyMinOut)`. `imageURI` (e.g. `ipfs://<CID>`) is at most `MAX_IMAGE_URI` = 256 bytes (`ImageURITooLong`), and is
emitted in `LaunchCreated(..., creator, imageURI)`, never stored. Empty is allowed. Frontends load it through an IPFS
gateway, fall back to a generated initials avatar, and can hide it per token.

---

## 0. Process

Work phase by phase. Stop at every **GATE** and report back before continuing.

## 1. What we're building

A Pump.fun-style launchpad on **X Layer** (chain 196, testnet 1952). Every launch is bound to a **TapeOut Circuit NFT**.

- Launching requires holding a Circuit NFT. Taping out a circuit on TapeOut burns NAND/LATCH components.
- Each token trades first on a **virtual-reserve bonding curve** held inside our contract. No one seeds liquidity at launch: the creator pays gas only, and the protocol needs no capital.
- When the curve sells out, the token **graduates**. The quote raised plus the reserved tokens seed a full-range Uniswap v3 position, which is locked forever.
- Fees are split between:
  - the Circuit's **TapeOut Container**, the creator/agent treasury that moves with the NFT,
  - the protocol treasury,
  - an ecosystem sink, which later buys and burns BEM / components.
- Each launch picks one quote asset: **WOKB (default)** or **BEM (optional)**. No other quote assets.

Non-goals for v1:
- platform token
- cross-chain
- TapeSend
- Processor component launches
- rule circuits via REF
- tape:// frontend

These come later (section 10).

## 2. Locked decisions

| Decision | Value |
| --- | --- |
| Pre-graduation market | Virtual constant-product curve (x · y = k) inside `CurvePad` (one singleton, all launches) |
| Quote assets | WOKB `0xe538905cf8410324e03A5A23C1c177a474D59b2b` (default; accept native OKB and wrap it), BEM (address from recon) |
| Supply | 1,000,000,000 tokens, 18 decimals, fixed, no owner, no mint |
| Split | ~800M sold on the curve, remainder reserved for graduation LP (exact numbers solved in 5.2) |
| Curve trade fee | 1% of quote, on buys and sells |
| Fee split (bps) | Container 5000 / protocol 3000 / sink 2000 — constants, tune later |
| Graduation venue | Canonical Uniswap v3 on X Layer, fee tier 1% (10000, tickSpacing 200), full-range position, locked |
| Tooling | Foundry, Solidity ^0.8.24, OpenZeppelin v5 |

Uniswap v3 X Layer addresses come from `https://developers.uniswap.org/docs/protocols/v3/deployments/v3-xlayer-deployments` (UniswapV3Factory, NonfungiblePositionManager). Do **not** assume Ethereum mainnet addresses. Put them in `script/Addresses.sol` with the source URL in a comment, and verify on a fork that each has code.

## 3. Phase 0 — Recon (no contract code yet)

Write `RECON.md`. Answer each item with evidence: address, ABI snippet, or tx hash.

1. **Uniswap v3 on X Layer.**
   - Confirm the factory and position manager addresses.
   - Check whether v3 exists on testnet 1952. If it doesn't, fork-test against mainnet only.
2. **BEM on X Layer.**
   - Is there a canonical BEM ERC-20 on X Layer? Give its address, its decimals, and whether it is bridged or native.
   - Is there an existing BEM/WOKB pool, and how deep is it? Report current liquidity.
   - If BEM isn't on X Layer, the BEM option is blocked. Report that; don't invent a token.
3. **TapeOut on X Layer.** Start from:
   - https://github.com/trytotapeout/awesome-tapeout
   - tapeout.market
   - the OKLink explorer
   - the user's earlier builds Nandout / Forgeout (GitHub `davieslennox0`)

   Find:
   - Processor Factory and Circuit NFT contract addresses. Is each Processor its own ERC-721 contract?
   - How to derive a Circuit's **Container** from (processor, tokenId).
   - Can a Container **receive ERC-20s** via plain `transfer`, and can the current holder withdraw them? Is there any "opened" or activation requirement?
4. **Current OKB and BEM USD prices.** These are needed to pick curve constants (5.2).

**GATE 0:** report the findings. Escalate if Containers can't receive or withdraw ERC-20s (fee routing would change), or if BEM isn't on X Layer.

## 4. Repo layout

```
src/
  LaunchToken.sol         // fixed-supply ERC-20 + pre-graduation pool lock
  CurvePad.sol            // create, buy, sell, graduate, fee accrual — singleton
  PositionLocker.sol      // holds graduated LP NFTs forever, permissionless collect + split
  interfaces/             // ICircuitNFT, IContainerResolver, Uniswap v3 interfaces
  libraries/CurveMath.sol // pure curve math, unit-tested in isolation
test/
  unit/                   // mocks for Circuit NFT + Container resolver
  fork/                   // X Layer mainnet fork tests against real Uniswap v3
script/
  Addresses.sol
  Deploy.s.sol
RECON.md
SPEC.md
```

## 5. Curve design

### 5.1 State per launch

```solidity
struct Curve {
    address quote;          // WOKB or BEM
    uint128 vQuote;         // virtual + real quote reserve (Q)
    uint128 vToken;         // virtual token reserve (T)
    uint128 realQuote;      // real quote actually held for this curve
    uint128 tokensLeft;     // curve tokens still sellable (starts at CURVE_SUPPLY)
    address container;      // resolved TapeOut Container
    address circuitNft;
    uint256 circuitId;
    uint64  launchBlock;
    bool    graduated;
}
```

### 5.2 Constants and math

Per quote asset there is one immutable `QuoteConfig { vQuote0, vToken0, curveSupply, lpTokens }`, set in the constructor. There is no admin setter.

- Invariant: `k = Q · T`, where Q = vQuote0 + realQuote.
- **Buy** with `quoteIn`:
  1. fee = quoteIn · 1%, net = quoteIn − fee
  2. tokensOut = T − k / (Q + net)
  3. If tokensOut exceeds tokensLeft, cap it at tokensLeft and refund the excess quote. The capped buy is what triggers graduation.
- **Sell** `tokensIn`:
  1. quoteOut = Q − k / (T + tokensIn)
  2. fee = quoteOut · 1%
  3. The user receives quoteOut − fee
- Round in the protocol's favour: tokensOut rounds down, and required quote rounds up.

Solving the constants (do this in a script or test and document it in the PR):

- End state, when all `curveSupply` tokens are sold:
  - T_end = vToken0 − curveSupply
  - Q_end = k / T_end
  - R = Q_end − vQuote0 is the real quote raised.
- Graduation price: P_end = Q_end / T_end.
- `lpTokens = R / P_end = R · T_end / Q_end`. This makes the pool open at exactly the curve's final price.
- Choose vToken0 so that `curveSupply + lpTokens == 1e27` (1B · 1e18). Start from Pump.fun-like ratios (vToken0 ≈ 1.073B, curveSupply 800M), then solve exactly.
- Choose vQuote0 per quote asset so R lands on a target raise in USD (propose about $15k–$30k at current prices from recon; the user decides at GATE 1). R scales linearly with vQuote0 (R ≈ 2.93 · vQuote0 at Pump-like ratios).
- Rounding leaves a few wei of token dust. Burn it at graduation.

### 5.3 Anti-snipe

For the first `GUARD_BLOCKS` after launch (default 5), cap each buy at `MAX_EARLY_BUY` tokens (default 1% of supply). The creator's optional dev-buy inside `createLaunch` is exempt.

## 6. Contracts

### 6.1 LaunchToken

- OpenZeppelin ERC20. The full supply is minted once to `CurvePad` in the constructor. No owner, mint, pause, or blacklist.
- **Pre-graduation pool lock.**
  - The token stores an immutable `predictedPool`, the Uniswap v3 pool address for (token, quote, 10000), computed in its constructor from the factory and init code hash.
  - Until `CurvePad` calls `markGraduated()` (one-time, only CurvePad), `_update` reverts if `from` or `to` is `predictedPool`.
  - This stops anyone from adding token-side liquidity or trading in the v3 pool before graduation.
  - Wallet-to-wallet transfers stay free.

### 6.2 CurvePad

`createLaunch(circuitNft, circuitId, name, symbol, quote, devBuyMinOut) payable returns (token)`

1. Require `quote` is WOKB or BEM. Require `ICircuitNFT(circuitNft).ownerOf(circuitId) == msg.sender`, and that the NFT contract is a genuine TapeOut Processor contract (provenance check per RECON).
2. Resolve and store the Container.
3. Deploy the token with CREATE2 (salt includes msg.sender, circuitNft, circuitId). Initialise the Curve from that quote's QuoteConfig.
4. Optional dev-buy: if `msg.value > 0` (WOKB launches only), wrap it and buy, honouring `devBuyMinOut`. BEM launches take a `devBuyAmount` param via transferFrom instead.
5. Emit `LaunchCreated(token, quote, circuitNft, circuitId, container, creator)`.

Other functions:
- `buy(token, quoteIn, minTokensOut, deadline)`, plus a `buyWithOKB` payable variant for WOKB curves.
- `sell(token, tokensIn, minQuoteOut, deadline)`
- `graduate(token)` is internal, called automatically by the buy that empties the curve:
  1. Mark the curve graduated. No more buys or sells on the curve.
  2. Get or create the v3 pool for (token, quote, 10000).
  3. **Price normalisation.** The pool may already be initialised, by an attacker or by accident.
     - If it isn't initialised, initialise it at the sqrtPriceX96 for P_end (respect token0/token1 ordering).
     - If it is initialised at another price, it can only contain quote-side liquidity, because of the token lock. Move the price to P_end with a swap through the near-empty pool, using contract-held funds and a strict bound on the amount spent.
     - If moving the price would cost more than `MAX_NORMALIZE_COST` (e.g. 0.5% of R), skip graduation into this pool and revert. Write up the case in RECON/PR. Don't silently lose funds.
  4. Call `token.markGraduated()`.
  5. Mint a full-range position (ticks at min/max multiples of 200) with `lpTokens` + R quote, with slippage checks on amounts used.
  6. Send the position NFT to `PositionLocker`, registered with this launch's Container.
  7. Burn leftover token dust. Any leftover quote dust goes to the protocol.
  8. Emit `Graduated(token, pool, positionId, R, lpTokens)`.
- **Fee accrual is pull-based.**
  - Each curve trade adds its fee to `accrued[quote][recipient]` for Container, protocol, and sink, by bps.
  - `claim(quote, recipient)` is permissionless and pushes accrued funds to the recipient.
  - This avoids sending to a Container on every trade.
- Reentrancy guard on every external state-changing function. Use `SafeERC20`. Check deadlines.

### 6.3 PositionLocker

- Accepts LP NFTs only from CurvePad (`onERC721Received` rejects anything else).
- **No** decreaseLiquidity, burn, or NFT transfer out. No owner, no upgradeability.
- `collect(positionId)` is permissionless. It collects all fees and splits both tokens by the same bps: Container / protocol / sink. Remainders go to the protocol. Provide `collectMany(ids)`.

## 7. Tests (must pass before GATE 1)

Unit tests (CurveMath plus mocks):
- Buy then sell round trip loses exactly the fees plus rounding, never more than that, and never gains.
- The curve can't sell more than `curveSupply`. The overshoot buy is capped and the excess refunded.
- With the solved constants, `curveSupply + lpTokens == 1e27` for each QuoteConfig.
- Price is monotonic: every buy raises the price, every sell lowers it.
- The ownership check rejects non-holders and non-TapeOut NFTs.
- Anti-snipe caps early buys and lifts after GUARD_BLOCKS.
- The token has no owner or mint. Pool-lock transfers revert before graduation and succeed after.

Fork tests (X Layer mainnet fork, real Uniswap v3):
- Full lifecycle for WOKB: create, many buys and sells, graduation. The pool price at graduation is within 0.1% of P_end. Position liquidity is non-zero and locked.
- The same lifecycle for BEM, if recon found it.
- Attack: someone pre-creates and initialises the pool at 10x or 0.1x the price and adds quote-only liquidity. Graduation still opens at about P_end, or reverts when the cost exceeds MAX_NORMALIZE_COST. No user funds are lost.
- Invariants (Foundry invariant tests):
  - CurvePad's real quote balance ≥ sum of `realQuote` plus accrued fees.
  - Locked liquidity never decreases.
- Fee accrual and `claim` match the bps exactly. `collect` on the locker splits correctly.
- Gas report for create, buy, sell, graduate, and collect.

**GATE 1:** report test results, gas numbers, and the proposed vQuote0 per quote asset with the target raise in USD.

## 8. Deployment

- `Deploy.s.sol` deploys PositionLocker, then CurvePad, and wires them together.
- Testnet first if v3 exists on 1952. Otherwise dry-run on a local anvil fork of mainnet.
- **Never deploy to mainnet or spend real funds without explicit approval from the user.**
- Keys live in `.env` (gitignored). Never print or commit them.
- Verify contracts on Sourcify, which supports X Layer without an API key, or on OKLink.

**GATE 2:** report the deployment addresses and a sample launch → graduation run on testnet or fork.

## 9. Working rules for Claude Code

- Plan each phase as a short checklist before coding. Commit per logical step.
- Prefer battle-tested libraries (OZ, Uniswap v3 TickMath / LiquidityAmounts / FullMath) over hand-rolled math. Use `FullMath.mulDiv` for any curve products that can overflow.
- If recon contradicts this spec, stop and report. Don't silently redesign.
- Keep LaunchToken minimal. Traders will read it.
- When unsure how a TapeOut or Uniswap contract behaves, test it on a fork instead of assuming.

## 10. Later phases (not v1)

1. **Agent endpoint.** One-call launch for agents, packaged as a skill / MCP tool for OKX.AI agents.
2. **Ecosystem sink.** Swap the sink share into BEM / components and burn it.
3. **Rule circuits via REF.** Replace the hard-coded anti-snipe with a small TapeOut circuit (needs recon on read-call gas).
4. **tape:// launch pages** via the Website Repository / TapeKit.
5. **Processor component launches** on the same curve engine.

## 11. References

- Uniswap v3 X Layer deployments: https://developers.uniswap.org/docs/protocols/v3/deployments/v3-xlayer-deployments
- Uniswap v3 on X Layer governance proposal: https://tally.xyz/gov/uniswap/proposal/67
- X Layer tooling (chain IDs, Sourcify): https://docs.chainstack.com/docs/xlayer-tooling
- TapeOut on X Layer (modules live Sept 19, 2026): https://x.com/i/article/2103048027800027151
- TapeOut ownable computation (Processors, REF): https://x.com/i/article/2103062125312958599
- awesome-tapeout: https://github.com/trytotapeout/awesome-tapeout
- TapeAPI (Container lookup reference, BNB Chain): https://github.com/BruceLanLan/tapeapi
- Pump.fun bonding-curve mechanics (virtual reserves, ~85 SOL graduation): https://madeonsol.com/blog/solana-bonding-curves-explained