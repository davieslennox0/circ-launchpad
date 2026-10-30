# OKX DEX integration request: Circ Launchpad Uniswap v4 hook (X Layer)

**To:** OKX DEX aggregator team
**Chain:** X Layer mainnet (196)
**Request:** route Uniswap v4 pools that use the Circ hook, alongside your existing "Uniswap V4" source (id 438).

## What Circ is

Circ Launchpad by Sarf is a launchpad for tokens bound to TapeOut Circuit NFTs.

1. Each token trades first on a bonding curve inside our contract.
2. When the curve sells out, anyone can graduate the token into one Uniswap v4 pool, with a full-range position of 1B
   fixed-supply tokens against WOKB (or BEM). The position is locked forever.
3. Every graduated token after that trades only in its Circ pool.

## What the hook does

The Circ hook is immutable, has no admin and is not upgradeable. It sets only two permission flags:

| Flag | Behaviour |
|---|---|
| `beforeInitialize` | Reverts unless the caller is Circ's Graduator contract, so nobody can create the pool early or at a wrong price |
| `beforeAddLiquidity` | Reverts unless Circ's Graduator authorised that exact add (its own one-time full-range mint, made through the v4 PositionManager) |

It has **no swap, donate or remove-liquidity hooks** and **no delta-returning flags**.

- **Swaps** run exactly as in a vanilla v4 pool: the quoted price is the settled price, with no hookData, no custom fee
  logic and no balance changes from the hook.
- **Fees** are static: 1% (10000) with tick spacing 200.
- **Allowlist:** the hook address does not start with `0x91`, so it is on Uniswap's routing auto-allowlist.

## Pools

- Currencies: the launched token and WOKB (`0xe538905cf8410324e03A5A23C1c177a474D59b2b`) or BEM
  (`0x60e62Efa9405d6873C5deaBD4E6CC91c25363952`), sorted.
- Pool key: (currency0, currency1, fee 10000, tickSpacing 200, hooks = CircHook).
- Pool liquidity: exactly one locked full-range position. No other liquidity can be added.
- Discovery:
  - every graduation emits `Graduated(address token, bytes32 poolId, uint256 positionId, uint256 raised, uint256 lpTokens)`
    from CurvePad;
  - the PoolManager emits its standard `Initialize` event with `hooks = CircHook`.

## Addresses (filled in at deployment)

| Contract | Address |
|---|---|
| CircHook | `<after deployment>` |
| CurvePad (emits `Graduated`) | `<after deployment>` |
| Graduator | `<after deployment>` |
| Uniswap v4 PoolManager | `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32` |
| Uniswap v4 PositionManager | `0xcF1EAFC6928dC385A342E7C6491d371d2871458b` |

Source is verified on Sourcify / OKLink at deployment, and a fork test swaps through Universal Router 2.1.2. Happy to
provide anything else your review needs.

Contact: `<your contact>`
