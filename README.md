# Circ Launchpad by Sarf

Circ is a launchpad on X Layer (chain 196) for tokens bound to TapeOut Circuit NFTs.

- **Launch:** only a holder of a genuine TapeOut Circuit NFT can launch a token.
  Supply is fixed at 1B, with no owner and no mint.
- **Curve:** each token trades on a virtual constant-product bonding curve held in a single `CurvePad` contract.
  The quote asset is WOKB (native OKB accepted) or BEM.
- **Graduation:** the buy that sells out the curve marks it Complete and emits `CurveCompleted`. Trading closes at
  that point. Anyone can then call `graduate(token)`, which seeds a full-range Uniswap v4 position (1% fee tier) in a
  Circ-hooked pool with the raise and the reserved tokens. The position is locked forever in `PositionLocker`.
  - `CircHook` lets only Circ's Graduator initialize the pool and seed it, so graduation always opens at the curve's
    final price. Once the graduation mint has settled, anyone may add or remove their own liquidity. The hook has no
    swap hooks, so the pool trades like a vanilla v4 pool.
- **Fees:** curve fees (1%) and LP fees are split 50% to the Circuit's TapeOut Container, 30% to the protocol and 20% to
  an ecosystem sink.
  - Fees are pull-based.
  - The Circuit's current holder can route creator fees to the Container, or to their own wallet as a fallback.

| Doc | What's in it |
|---|---|
| [SPEC.md](SPEC.md) | Build spec and owner amendments |
| [RECON.md](RECON.md) | On-chain recon: Uniswap v3 and v4, BEM, TapeOut Containers, prices |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Production addresses, verification, services |

## Curve

| | Value |
|---|---|
| Launch market cap | $4,000 |
| Graduation market cap | $69,000 |
| Curve supply | ≈ 805.95M |
| LP reserve | ≈ 194.05M |
| Raise per launch | ≈ $13.4k (production v3: ≈ 117.18 WOKB or ≈ 616.7 BEM) |

The constants are solved exactly in `script/solve_constants.py` and stored in `script/CurveConstants.sol`. The USD
figures use OKB and BEM prices from 2026-10-29. At deploy time, `script/Deploy.s.sol` re-solves each `vQuote0` from live
on-chain prices and prints the values for approval.

## Layout

```
src/CurvePad.sol         create / buy / sell / graduate, fee accrual (singleton)
src/LaunchToken.sol      fixed-supply ERC-20, no owner, no restrictions
src/CircHook.sol         v4 hook: only Graduator may initialize; adds gated until the graduation mint settles
src/PositionLocker.sol   holds LP NFTs forever, permissionless fee collect + split
src/FeeVault.sol         pull-based fee accounting shared by both
src/TokenDeployer.sol    CREATE2 LaunchToken factory, deployed by CurvePad
src/Graduator.sol        v4 pool init at P_end, locked full-range mint; deployed by CurvePad
test/unit/               mocks, fuzz and invariant tests
test/fork/               X Layer mainnet fork tests against real Uniswap v4 / TapeOut
script/Deploy.s.sol      deploys PositionLocker then CurvePad
script/keeper/           graduates Complete curves (service: deploy/circ-keeper.service)
web/                     static site at circ.getsarf.xyz, plus the keyless indexer
pin/                     logo pinning endpoint (Vercel)
test/web, test/py        frontend, pin, keeper and indexer tests; test/web/browser.mjs is the real-browser test
```

## Build and test

```sh
forge build
forge test --match-path "test/unit/*"
forge test --match-path "test/fork/*"   # forks X Layer via $XLAYER_RPC_URL (defaults to the public RPC)
```

CI (`.github/workflows/ci.yml`) runs the unit, invariant and fork suites, a gas report, Slither (fails on anything not in
the justified baseline), frontend, keeper and indexer tests, and a deploy dry run on a fork.

## Licence

GPL-2.0-or-later (see LICENSE). It compiles in GPL-2.0-or-later Uniswap code. Vendored MIT files keep their licence.

## Trust assumptions

The TapeOut factory, the Container beacon and the BEM OFT on X Layer are all controlled by the same TapeOut 3-of-5 Safe
(`0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138`), and all of them are upgradeable. Circ relies on:

- `isCPU`
- `ownerOf`
- Container withdrawals
- BEM's behaviour

The holder fallback claim exists in case an upgrade breaks Container withdrawals.

## Deployment

There is no Uniswap v4 on the X Layer testnet, so deployment is dry-run on an anvil mainnet fork first. Mainnet deployment
happens only with the owner's explicit go-ahead. Keys live in `.env`, which is gitignored.
