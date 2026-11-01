# Circ Launchpad: X Layer mainnet deployment (2026-10-31)

Production instance. Deployed from `0xc41EFaC70571bF7D7Ef7d402C66E36108202b35D` with `script/Deploy.s.sol:Deploy` at
block 74,717,838 (broadcast record: `broadcast/Deploy.s.sol/196/`).

| Contract | Address |
|---|---|
| CurvePad | `0x45E97E81d50D0c77170D9cb622f9d255768E4827` |
| PositionLocker | `0xFCDE10159a59E81f85F6affB6A8d01e7845EBC50` |
| CircHook (v4 hook, flags 0x2800) | `0x8FB8A9C27EAEb0Ed1434b3EBd2a0eaC7FE82a800` |
| Graduator | `0xe956DDCC15E32E8c8f4AFb7253767bc5f5E630BB` |
| TokenDeployer | `0x3c6F9E00193B698242cC6Bb128C0e37307c7A8D1` |
| Protocol (treasury) Safe 1.5.0, 3-of-3 | `0x79ac0889b0aCa2C5233EeECE7468195ad7A58997` |
| Sink Safe 1.5.0, 3-of-3 | `0x4E2020B7Ef36a22550EDf603C556EFA8c17b65F3` |

Deploy transactions:
- PositionLocker: https://www.oklink.com/x-layer/tx/0x6a39168c84894991533c555f00e0ae3103982bbbfa0e41f4bfa5d309ae6b5332
- CurvePad (creates TokenDeployer, CircHook via CREATE2, Graduator): https://www.oklink.com/x-layer/tx/0x051ff09e8122dd480df1d46117c1c9ee4c28a610989bace75fea802d552b4b82

Curve constants (owner-approved at OKB $110.55 / BEM $18.30; live drift at broadcast 0.025% / 0.11%):
- WOKB vQuote0 `38410582887463587149` (raise ≈ 121.12 WOKB ≈ $13,389)
- BEM vQuote0 `23202554995` (raise ≈ 731.7 BEM)
- vToken0 / curveSupply / lpTokens: `1061538461538461538461538462` / `805950034987136158382022685` / `194049965012863841617977315`

Verification:
- Sourcify: all five contracts `exact_match`. CurvePad needed the full compiler input (Sourcify issue #618, via-IR);
  it is saved as `docs/verification/CurvePad.standard-input.json`.
- OKLink: PositionLocker, CircHook, Graduator, TokenDeployer verified. CurvePad: OKLink's API returns "Unable to verify"
  for the same input Sourcify matches exactly; upload `docs/verification/CurvePad.standard-input.json` in OKLink's
  "Solidity (Standard-Json-Input)" form (compiler v0.8.24+commit.e11b9ed9, contract `src/CurvePad.sol:CurvePad`).

Keeper: `circ-keeper` systemd service (`deploy/circ-keeper.service`), keeper `0x2b41B054C8Ae9fE81Fc64928377e315c2DE6856A`,
env in `/etc/circ-keeper.env` (mode 600), log `/var/log/circ-keeper.log` (logrotate weekly), state
`/var/lib/circ-keeper/state.json`.

CIRC-TEST instance (test only, do not use): CurvePad `0xa66D7020a374BCC3e6424B9075E481617C669057`.
