# Frontend notes

## Creator fees: Container withdraw vs direct holder claim

Creator fees (50% of every curve and LP fee) accrue in the CurvePad / PositionLocker FeeVaults under the launch's
TapeOut Container. The Circuit holder has two ways to take them, both holder-only (`claimCreator(container, asset, toHolder)`):

| Route | Calls | Cost to the holder (TapeOut fees as of 2026-10-31) |
|---|---|---|
| **To Container, then withdraw** | `claimCreator(..., false)`, then `Container.execute(asset, 0, transfer(holder, amt), 0)` | one-time Container open **0.08 OKB** (if not opened; anyone can pay it) + **0.0013 OKB per execute** + gas |
| **Direct to holder wallet** (fallback) | `claimCreator(..., true)` | gas only (~0.000002 OKB) |

UI requirements:
- On the creator panel, show per asset: claimable amount (from `accrued(asset, container)` on both CurvePad and
  PositionLocker), the Container's current balance, whether the Container is opened, and the **Container withdraw fee
  (0.0013 OKB; read live from the Container's fee revert or TapeOut config, don't hard-code) next to that balance**.
- If the value to withdraw is small relative to the fee, **recommend the direct holder claim**: suggested rule, recommend
  direct when `claimable_value_in_OKB < 10 × 0.0013 OKB` (≈ 0.013 OKB), or whenever the Container is not opened yet and
  claimable value < 0.08 OKB. Always show both options; the Container route stays available.
- Explain that fees credited to the Container stay with the Circuit NFT (they move with the NFT on sale), while the
  direct claim pays the current holder's wallet now.
- Fees arrive as **WOKB** (wrapped OKB), not native OKB: show it as OKB with a "wrapped" hint and offer an unwrap.
  Protocol/sink recipients will likewise see WOKB, not native OKB, in their wallets.
- LP fees also accrue in the launch token itself; show those separately (claimable the same two ways).
