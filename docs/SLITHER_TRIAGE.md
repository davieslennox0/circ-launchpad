# Slither triage (v3 contracts)

- **Run:** slither-analyzer 0.10.4 in CI, run 41303582133, branch `feat/v3-contracts`.
- **Enforced:** `script/ci/slither_gate.py` fails CI on any finding missing from `script/ci/slither_baseline.json` (first run with an empty baseline failed on all 27, as it should). The key is detector + flagged code, so editing flagged code re-opens it.
- **Scope:** `src/` only. `lib/`, `test/`, `script/` and vendored `src/libraries/uniswap/` are excluded.
- **Result:** 38 contracts, 93 detectors, **27 results, none of them real issues.** Each detector is justified below.
  No code changes were needed.

| # | Detector | Where | Verdict |
|---|---|---|---|
| 1 | dangerous-strict-equalities (6) | `FeeVault._accrueSplit/_accrueProtocol` (`amount == 0`), `CurvePad._buy` (`e.blockNumber == block.number`, `out == 0`, `c.tokensLeft == 0`), `CurvePad._refundNative` (`amount == 0`) | **Not an issue.** The detector targets equality against values an attacker can move, such as `balanceOf`. These compare our own accounting values, or the block number against a stored block number. Exact equality is intended in each case. |
| 2 | uninitialized-local-variables | `CurvePad._buy` `soldThisBlock` | **Intended.** It defaults to 0 and is set only when this block already has early sales recorded. |
| 3 | unused-return | `Graduator.graduate` ignores the tick from `poolManager.initialize` | **Intended.** The tick isn't needed, and the sqrt price is set exactly by us. |
| 4 | missing-zero-address-validation (4) | `CircHook` constructor (graduator, poolManager, positionManager), `Graduator` constructor (locker) | **Not reachable.** Both are created only by CurvePad's constructor. That constructor rejects zero `poolManager`, `positionManager`, `permit2` and `locker`, and computes the Graduator address itself (then checks it after creation). |
| 5 | calls-inside-a-loop (5) | `PositionLocker.collectMany` → `collect` | **Accepted.** It is a permissionless batch helper, and the caller picks the ids. Each `collect` is independent, so one bad id reverts only that batch, and the caller can retry with fewer ids. |
| 6 | reentrancy-benign (6) | `CurvePad._deployLaunch`, `_graduate`, `buyWithOKB`, `createLaunch`; `PositionLocker.collect` | **Not exploitable.** Every state-changing entry point in CurvePad and FeeVault shares one `nonReentrant` guard, and `PositionLocker.collect` is `nonReentrant`. The external callees are our own helpers created in the constructor (TokenDeployer, Graduator), WOKB (WETH9: no callbacks), and the Uniswap v4 PositionManager. The writes after the calls are accounting of amounts those calls already fixed. |
| 7 | block-timestamp | `CurvePad._checkDeadline` | **Intended.** These are user-supplied trade deadlines, where a few seconds of drift is harmless. |
| 8 | assembly | `CircHook.allowAdd`, `beforeAddLiquidity` | **Intended.** `tstore`/`tload` hold the one-shot add authorisation in transient storage. It is cleared on use and at the end of the transaction. |
| 9 | low-level-calls | `CurvePad._refundNative` | **Intended.** It sends refunded native OKB to `msg.sender`. The result is checked (`NativeTransferFailed`), and it runs under `nonReentrant` after all state is written. |

Any new finding fails CI until it is fixed, or justified both here and in the baseline.
