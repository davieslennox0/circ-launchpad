# Circ Launchpad — Phase 0 Recon

Date: 2026-10-29. Chain: X Layer mainnet (196). All reads via `https://rpc.xlayer.tech`; behavioural claims tested on an
anvil fork of mainnet at block ~74,530,714 with impersonated accounts. No real transactions sent.

## TL;DR

| # | Question | Answer |
|---|---|---|
| 1 | Uniswap v3 on X Layer | **Yes**, canonical deployment, all addresses have code. Fee tier 10000 → tickSpacing 200 confirmed. Canonical init code hash confirmed. |
| 1 | v3 on testnet 1952 | **No.** Uniswap lists mainnet only; factory address has no code on 1952. → Fork-test against mainnet only. |
| 2 | BEM on X Layer | **Yes**, `0x60e62Efa9405d6873C5deaBD4E6CC91c25363952`, **8 decimals**, LayerZero **OFT bridged from BSC** (not native). No transfer tax. |
| 2 | BEM/WOKB pool | Uniswap v3 1% pool `0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A`, ~**$80k TVL** (2,514 BEM + 220 WOKB). Only 13,308 BEM exist on X Layer in total. |
| 3 | Processor = own ERC-721? | **Yes.** Each processor is its own Circuits clone (ERC-721); provenance = `factory.isCPU(addr)`. |
| 3 | Container derivation | Standard ERC-6551: `registry.account(impl, salt=0, 196, processor, tokenId)`; equals `opener.accountOf(processor, tokenId)`. |
| 3 | Container receives ERC-20 via `transfer`? | **Yes, even before it is opened** (counterfactual address). Verified on fork. |
| 3 | Holder can withdraw? | **Yes, with conditions:** container must be opened once (**0.08 OKB**, `opener.open`, callable by anyone), then each `execute` costs **0.0013 OKB** (`executeBatch` 0.0033 OKB). Only the current NFT holder can execute. |
| 4 | Prices | OKB **$113.23**, BEM **$21.88** (OKX DEX index, 2026-10-29; BEM pool spot agrees). |

**No GATE 0 blockers.** Fee routing as specified works. Three items need a decision from you: see the end of this file.

---

## 1. Uniswap v3 on X Layer

Source: https://developers.uniswap.org/docs/protocols/v3/deployments/v3-xlayer-deployments (fetched 2026-10-29).

| Contract | Address | Code on 196 |
|---|---|---|
| UniswapV3Factory | `0x4B2ab38DBF28D31D467aA8993f6c2585981D6804` | 24,535 B |
| NonfungiblePositionManager | `0x315e413A11AB0df498eF83873012430ca36638Ae` | 24,384 B |
| SwapRouter02 | `0x4f0c28f5926afda16bf2506d5d9e57ea190f9bca` | 24,497 B |
| QuoterV2 | `0xd1b797d92d87b688193a2b976efc8d577d204343` | 8,273 B |
| WOKB (WETH9 of NPM) | `0xe538905cf8410324e03A5A23C1c177a474D59b2b` | 3,474 B |

Cross-checks:
- `NPM.factory()` = the factory above; `NPM.WETH9()` = WOKB. The spec's WOKB address is correct.
- `factory.feeAmountTickSpacing(10000)` = **200**.
- **Pool init code hash is the canonical `0xe34f199b…8b54`**: `CREATE2(factory, keccak(BEM, WOKB, 10000), 0xe34f…)` reproduces the
  live pool `0x2CcF…9f7A` exactly. So `LaunchToken.predictedPool` can use the standard `PoolAddress.computeAddress`.
- Testnet 1952: RPC `https://testrpc.xlayer.tech` answers chain id 1952, but the factory address has no code and Uniswap lists no testnet deployment.
  **Plan: all v3 tests on a mainnet fork; GATE 2 dry run on an anvil fork.**

## 2. BEM on X Layer

| Field | Value | Evidence |
|---|---|---|
| Address | `0x60e62Efa9405d6873C5deaBD4E6CC91c25363952` | OKX DEX token search (chain 196), `communityRecognized: true`; 13,138 B code |
| name / symbol / decimals | BEM / BEM / **8** | `eth_call` |
| Total supply on X Layer | 1,330,767,086,100 = **13,307.67 BEM** (~$291k) | `totalSupply()` |
| Type | **LayerZero V2 OFT, bridged.** `endpoint()` = `0x1a44…728c`, `sharedDecimals()` = 6, `token()` = self, `approvalRequired()` = false | `eth_call`, selector dump |
| Canonical home | BSC `0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a`, 8 dp, 448,808 BEM supply, same price | BSC RPC + OKX index |
| Owner | `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138`: **Safe 1.4.1, 3-of-5**. This is the same Safe that owns the TapeOut factory. | `getThreshold`, `getOwners` |
| Transfer tax | **None**: sent 1.00000000 BEM, received 1.00000000 | fork test |

**BEM/WOKB liquidity:** v3 1% pool `0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A` (token0 = BEM). It holds 2,514.36 BEM ($55.0k) + 220.18 WOKB ($24.9k) ≈ **$80k TVL**.
In-range liquidity is 1.18e16. Pools for fee tiers 100, 500 and 3000 do not exist.

**What this means for BEM-quoted launches:**
- A full graduation raises ~612 BEM (see §5). That is **~4.6% of all BEM on X Layer** and **~24% of the BEM in the only pool**.
  The BEM option is viable, but each BEM launch that graduates soaks up a noticeable share of the float, and buyers have to source BEM through a thin pool first.
- **8 decimals.** QuoteConfig, rounding and sqrtPriceX96 work must not assume 18-decimal quotes. Unit tests will cover a mixed 18/8 pair.
- OFT trust: the 3-of-5 Safe controls peers and config. A malicious peer could mint on X Layer. This is the same trust root as the TapeOut factory, so it adds no new party.

## 3. TapeOut on X Layer

### 3.1 Addresses

| What | Address | Evidence |
|---|---|---|
| CircuitFactory (proxy) | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | `cpuCount()` = **398** processors; `isSealed()` = **false** |
| Factory owner | `0xB3D85b42…3138`: Safe 1.4.1, 3-of-5 (was an EOA `0x571d…` in Sept; that EOA is now one of the 5 signers) | `owner()`, `getOwners()` |
| Container opener | `0x536adD8F30f03b69f6fbF29d425A816A0dC50106` | `FEE()` = 0.08 OKB, `registry()`, `implementation()`, `SALT()` = 0, factory = above |
| ERC-6551 registry | `0x000000006551c19487814612e58FE06813775758` | canonical |
| Container impl (beacon proxy) | `0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57` → beacon `0x9b135f58…8f44` → logic `0x6B6fDa1483367e939314070a4f233c1DFD35996B` | bytecode `delegatecall(beacon.implementation())`; beacon owner = same Safe |
| Container fee sink | treasury `0xE2f77062c6060503e0289c6638D1B0A7C76cBB9d`, payments `0x13b8AFa4…4858` | `treasury()`, `payments()` |

### 3.2 Processors and provenance

- Each processor is a separate **Circuits** clone: an ERC-721 (`supportsInterface(0x80ac58cd)` = true), with `factory()` = the factory, paired with an ERC-1155 Transistors clone.
- **Provenance check for `createLaunch`:** `ICircuitFactory(0x1f09…0761).isCPU(circuitNft) == true`. Verified: `isCPU(Nandout 0x8A60…a58E)` = true, `isCPU(WOKB)` = false.
- Trust note: the factory, the Circuits beacon and the Container beacon are all upgradeable by the 3-of-5 Safe (`isSealed() == false`).
  Circ depends on `isCPU`, `ownerOf` and the Container's withdraw logic, and the Safe could change all three. This is the same trust root everyone building on TapeOut accepts.

### 3.3 Container derivation

```
container = IERC6551Registry(0x0000…5758).account(
    0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57,   // implementation
    bytes32(0),                                     // salt
    196,                                            // chainId
    processor,                                      // Circuits ERC-721
    tokenId)
```
Verified: for Nandout #1 this gives `0x550046Eb…Ce54`, which equals `opener.accountOf(proc, 1)` and has `token()` = (196, proc, 1). It is computed
without any external dependency beyond the registry, so CurvePad can resolve it with a single view call (or compute the CREATE2 address locally).
The Container follows the NFT: `owner()` returns the current `ownerOf(tokenId)`.

### 3.4 Can a Container receive and release ERC-20s? (fork-tested)

| Test | Result | Gas |
|---|---|---|
| WOKB `transfer` to an **opened** container (Nandout #1) | ok | |
| Holder `execute(WOKB, 0, transfer(holder, x), 0)` with no value | **reverts** `0xafd49700(0, 1.3e15)`: fee required | |
| Same with `msg.value = 0.0013 OKB` | ok, funds arrive, fee goes to treasury `0xE2f7…` | 133,823 |
| Holder `executeBatch` (2 calls) with 0.0033 OKB | ok | 113,685 |
| Stranger `execute` | reverts `NotOwner` | |
| WOKB `transfer` to an **unopened, undeployed** container (Nandout #2) | **ok**: balance credited at the counterfactual address | 51,627 |
| `opener.open(proc, 2)` by a **stranger** with 0.08 OKB | **ok**: opening is permissionless | 169,734 |
| Holder `open` again | reverts `AlreadyOpened` | |
| Holder withdraws from #2 after the stranger opened it | ok | 128,767 |
| Stranger deploys #3 directly via the 6551 registry (skipping the opener fee), then holder `execute` | reverts `NotPaid` (from an earlier run) | |
| …then holder `open(proc, 3)` and withdraws | **ok**: a raw deploy cannot brick a container | 96,383 / 111,923 |
| Native OKB `send` to a container | ok | |

**Conclusion:** pushing fees to a Container with plain `transfer` always works, whether or not it is opened. Withdrawal needs a one-time open
(0.08 OKB ≈ $9.06) plus 0.0013 OKB (≈ $0.15) per execute. No escalation needed: the spec's pull-based `claim(quote, recipient)` works unchanged.

## 4. Prices (2026-10-29)

| Asset | USD | Source |
|---|---|---|
| OKB / WOKB | **113.23** | OKX DEX index (`onchainos token search`, chain 196) |
| BEM | **21.88** | OKX DEX index (X Layer and BSC agree within $0.01); v3 pool spot 0.1933 WOKB = $21.88 |

## 5. Curve constants preview (updated targets: launch MC $4k, graduation MC $69k)

Three constraints (P0·1e9 = $4,000; P_end·1e9 = $69,000; curveSupply + lpTokens = 1e27) against three unknowns, so **both targets can be hit exactly**:

- vToken0/T_end = √17.25 = 4.1533
- From `lpTokens = T_end·(1 − T_end/vToken0)`: vToken0·(1 − 1/17.25) = 1e9, so vToken0 = **1,061,538,461.5** tokens
- **curveSupply ≈ 805,950,035**, **lpTokens ≈ 194,049,965** (sum = 1e9)
- These token-side constants are the same for both quote assets. Only vQuote0 differs:

| Quote | vQuote0 | R (raise) | R in USD |
|---|---|---|---|
| WOKB | ≈ 37.50 WOKB | ≈ 118.25 WOKB | **≈ $13,389** |
| BEM | ≈ 194.09 BEM | ≈ 612.01 BEM | **≈ $13,389** |

(R = vQuote0·(√17.25 − 1). The 1% trade fee sits on top of R. Exact wei values are solved and asserted in tests in Phase 1.)

## 6. Decisions for you (GATE 0)

1. **Container opening cost.** Creators must pay 0.08 OKB once (plus 0.0013 per withdraw) to get fees out of their Container. Options:
   (a) leave it to the creator (spec as written; fees accrue safely at the counterfactual address); (b) have `createLaunch` optionally open the
   container when the creator sends ≥ 0.08 OKB extra. **Recommend (a) for v1** and document it in the UI.
2. **BEM option.** It's viable (real, tax-free OFT with a v3 pool), but the X Layer float is thin (13.3k BEM total, ~$80k pool) relative to a ~612 BEM
   graduation. **Recommend shipping BEM** as specced, since the code paths are identical, while showing WOKB as the default in the UI.
3. **No testnet.** v3 isn't on 1952, so GATE 2 is an anvil mainnet-fork dry run only. The first real deploy is mainnet, with your explicit approval.
