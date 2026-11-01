# Circ Launchpad: X Layer mainnet deployments

## Production v3 (current, 2026-11-01)

Deployed from `0xc41EFaC70571bF7D7Ef7d402C66E36108202b35D` with `script/Deploy.s.sol:Deploy` at block 74,785,331
(broadcast record in `broadcast/Deploy.s.sol/196/`). Adds SPEC A10: name and symbol limits, fee views, GPL-2.0-or-later.

| Contract | Address |
|---|---|
| CurvePad | `0x4b9eb3Ee0a25FFE62e159080f392551a99493cC7` |
| PositionLocker | `0x125DEc95d0186f98975dF17F083aB4420CC1E586` |
| CircHook (v4 hook, flags 0x2800) | `0x9Afb0AB86CC8dc087C562e82500a504e7c4ae800` |
| Graduator | `0xf12c68d5797d97776Cf30EEC8d90491790a7e35f` |
| TokenDeployer | `0xB0b10c142F323c08C529286d2dC5c989d869351c` |
| Protocol (treasury) Safe 1.5.0, 2-of-3 | `0x79ac0889b0aCa2C5233EeECE7468195ad7A58997` |
| Sink Safe 1.5.0, 2-of-3 | `0x4E2020B7Ef36a22550EDf603C556EFA8c17b65F3` |

Deploy transactions:
- PositionLocker: https://www.oklink.com/x-layer/tx/0x934962bd620740a17796c11681a824f6eee1b995e19c6f7eccf2828b8b921a6e
- CurvePad (creates TokenDeployer, CircHook via CREATE2, Graduator): https://www.oklink.com/x-layer/tx/0x9a360ff4b9060cacac255e44330aa91151a8ac73e91b62f07acf5c62e1ce8282

Curve constants (owner-approved at OKB $114.26 / BEM $21.71; live drift at broadcast 0.08% / 1.46%):
- WOKB vQuote0 `37161178063163679453` (raise ≈ 117.18 WOKB ≈ $13,389)
- BEM vQuote0 `19558480651` (raise ≈ 616.7 BEM; volatile quote)
- vToken0 / curveSupply / lpTokens: `1061538461538461538461538462` / `805950034987136158382022685` / `194049965012863841617977315`
- Dev buy is uncapped and exempt from anti-snipe, by owner decision. The site shows "Dev holds X%" instead.

Verification:
- Sourcify: all five contracts `exact_match`. CurvePad needs the full compiler input.
- OKLink: PositionLocker, CircHook, Graduator, TokenDeployer verified. CurvePad fails on OKLink's side (`server error`,
  "Unable to verify") for the input that recompiles byte for byte to the deployed runtime (CI run 41332707443); support
  request pending. Input: `docs/verification/CurvePad-v3.standard-input.json`, `CurvePad-v3.constructor-args.txt`.

Live test: the same code passed 62/62 on the CIRC-TEST instance (`docs/E2E_RESULTS-v3.md`).

Services on the server (dedicated `circ` user, code in `/opt/circ`, not the git checkout):
- `circ-keeper`: keeper `0x2b41B054C8Ae9fE81Fc64928377e315c2DE6856A`, private RPC (token only in `/etc/circ/keeper.env`) with the public RPC as fallback, encrypted
  keystore in `/etc/circ`, log
  `/var/log/circ-keeper.log`, state `/var/lib/circ-keeper`.
- `circ-indexer`: holds no wallet key, same private RPC and fallback (`/etc/circ/indexer.env`), writes `/srv/circ-web/data`, log
  `/var/log/circ-indexer.log`. The website itself stays on the public RPC.
- Site: https://circ.getsarf.xyz from `/srv/circ-web` (Caddy block in `deploy/Caddyfile.circ`).
- Logo pinning: https://circ-launchpad-pin.vercel.app/api/pin (`pin/`, Vercel project root `pin`).
- Staging: https://circ.getsarf.xyz/staging/ from `/srv/circ-staging`, on the CIRC-TEST pad with launching allowed. Transactions there
  are real and cost real OKB. No keeper watches it, so "Tape out now" is manual. Publish with `deploy/publish-web.sh staging|prod`.

To update code: copy `script/keeper/keeper.py` and `web/indexer.py` to `/opt/circ`, and publish `web/` with `deploy/publish-web.sh`.
Before each frontend release run `node test/web/browser.mjs <url> <shots dir> [staging]`.

## Instances not to use

### Production v2: DEPRECATED (2026-11-01)
Replaced before any launch: no name limits or fee views. Zero launches, no funds. CurvePad
`0x071a1ff737415Ddc2085629D80B7C68741e17A18`, PositionLocker `0x30B948F015bf266BC617d52B4A458C2860CbEb43`, CircHook
`0xB9df0fC41D85411207ea820Cd3b10fd8eEF7a800`. Keeper stopped and removed.

### Production v1: DEPRECATED (2026-11-01)
Replaced before any launch: no one-launch-per-Circuit guard or `imageURI`. Zero launches, no funds. CurvePad
`0x45E97E81d50D0c77170D9cb622f9d255768E4827`, PositionLocker `0xFCDE10159a59E81f85F6affB6A8d01e7845EBC50`, CircHook
`0x8FB8A9C27EAEb0Ed1434b3EBd2a0eaC7FE82a800`.

### CIRC-TEST (test only)
Tiny 0.099 WOKB curves used for live end-to-end runs, never for users. v3 code: CurvePad
`0x8f2bbd9dA778071a8B6E9C2D3fEC3f3a6850E6BA` (shown on the site as "Preview data"). Older code: CurvePad
`0xa66D7020a374BCC3e6424B9075E481617C669057`.
