# Circ Launchpad: X Layer mainnet deployments

## Production v2 (current, 2026-11-01)

Deployed from `0xc41EFaC70571bF7D7Ef7d402C66E36108202b35D` with `script/Deploy.s.sol:Deploy` at block 74,725,398
(broadcast record: `broadcast/Deploy.s.sol/196/run-1793494434397.json`). Adds SPEC A8 (one launch per Circuit,
`isLaunched`) and A9 (`imageURI` in `createLaunch`, emitted in `LaunchCreated`).

| Contract | Address |
|---|---|
| CurvePad | `0x071a1ff737415Ddc2085629D80B7C68741e17A18` |
| PositionLocker | `0x30B948F015bf266BC617d52B4A458C2860CbEb43` |
| CircHook (v4 hook, flags 0x2800) | `0xB9df0fC41D85411207ea820Cd3b10fd8eEF7a800` |
| Graduator | `0x3aA6A1990C27b1995EAD5922F24036ac6Ec50E7D` |
| TokenDeployer | `0xB6a6aD8eD30428E67b1A0c7AfA1921a8D8f79a57` |
| Protocol (treasury) Safe 1.5.0, 2-of-3 | `0x79ac0889b0aCa2C5233EeECE7468195ad7A58997` |
| Sink Safe 1.5.0, 2-of-3 | `0x4E2020B7Ef36a22550EDf603C556EFA8c17b65F3` |

Deploy transactions:
- PositionLocker: https://www.oklink.com/x-layer/tx/0x8a6f77c2fb55d04226bafff6c3f37880c7846a5675db43bb251327b38d158cdf
- CurvePad (creates TokenDeployer, CircHook via CREATE2, Graduator): https://www.oklink.com/x-layer/tx/0x04a1447b035c5d9d6ba350421b471c9d87e327991298f8dabb60a98600dfdf91

Curve constants (owner-approved at OKB $110.60 / BEM $18.43; live drift at broadcast 0.009% / 0.60%):
- WOKB vQuote0 `38393377713177396386` (raise ≈ 121.07 WOKB ≈ $13,389)
- BEM vQuote0 `23044916836` (raise ≈ 726.7 BEM; volatile quote)
- vToken0 / curveSupply / lpTokens: `1061538461538461538461538462` / `805950034987136158382022685` / `194049965012863841617977315`
- `MAX_IMAGE_URI` = 256 bytes

Verification:
- Sourcify: all five contracts `exact_match`. CurvePad via the full compiler input (Sourcify issue #618, via-IR).
- OKLink: PositionLocker, CircHook, Graduator, TokenDeployer verified. CurvePad: OKLink's API again returns "Unable to
  verify" for the input Sourcify matches exactly. Manual upload: OKLink → contract → Verify → "Solidity
  (Standard-Json-Input)", compiler `v0.8.24+commit.e11b9ed9`, contract `src/CurvePad.sol:CurvePad`, file
  `docs/verification/CurvePad-v2.standard-input.json`, constructor arguments (ABI-encoded, no 0x) from
  `docs/verification/CurvePad-v2.constructor-args.txt`.

Keeper: `circ-keeper-v2` systemd service (`deploy/circ-keeper-v2.service`), keeper
`0x2b41B054C8Ae9fE81Fc64928377e315c2DE6856A`, env `/etc/circ-keeper-v2.env` (mode 600), log `/var/log/circ-keeper-v2.log`,
state `/var/lib/circ-keeper-v2/state.json`. Started and confirmed caught up before the v1 keeper was stopped.

## Production v1: DEPRECATED (2026-10-31 → 2026-11-01)

**Do not use.** Replaced by v2 before any launch: it lacks the one-launch-per-Circuit guard and `imageURI`. Zero
launches, zero fees, no funds held (checked over every block from its deploy to the switch). Its keeper
(`circ-keeper`) is stopped and disabled. Contracts stay on chain and verified for the record.

| Contract | Address |
|---|---|
| CurvePad | `0x45E97E81d50D0c77170D9cb622f9d255768E4827` |
| PositionLocker | `0xFCDE10159a59E81f85F6affB6A8d01e7845EBC50` |
| CircHook | `0x8FB8A9C27EAEb0Ed1434b3EBd2a0eaC7FE82a800` |
| Graduator | `0xe956DDCC15E32E8c8f4AFb7253767bc5f5E630BB` |
| TokenDeployer | `0x3c6F9E00193B698242cC6Bb128C0e37307c7A8D1` |

Deployed at block 74,717,838 (`broadcast/Deploy.s.sol/196/run-1793486874792.json`); Sourcify exact match for all five;
OKLink manual input `docs/verification/CurvePad.standard-input.json`.

## CIRC-TEST (test only)

CurvePad `0xa66D7020a374BCC3e6424B9075E481617C669057` (tiny 0.099 WOKB curve, pre-A8/A9 ABI), used for the live E2E run
(`docs/E2E_RESULTS.md`). Never point users at it.
