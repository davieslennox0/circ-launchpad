# CIRC-TEST end-to-end results

- network: X Layer chain id 196 (mainnet)
- started: 2026-10-31 21:48:08 UTC, block 74714252
- spend cap: 0.5 OKB msg.value across all wallets (gas excluded)

### 0. Preflight
- **PASS** deployer, keeper, buyer and Nandout wallet are four distinct addresses
- **PASS** CIRC_PROTOCOL and CIRC_SINK differ (needed for the split check)
- **PASS** Nandout #2 is held by the Nandout wallet
  - Nandout #2 Container 0xEDB42802E129dC8EAb9C41cCD76C1A6D869221e1: not opened yet; open fee 0.08 OKB; gas price 0.0200 gwei
  - estimate: TEST deploy 0.000172 OKB gas; e2e run 0.00009 OKB gas + ~0.19 OKB value (fill ~0.1, Container open 0.08, withdraw fee 0.0013); prod deploy 0.000172 OKB gas
- **PASS** deployer 0xc41EFaC70571bF7D7Ef7d402C66E36108202b35D holds >= 0.003 OKB
- **PASS** keeper 0x2b41B054C8Ae9fE81Fc64928377e315c2DE6856A holds >= 0.083 OKB
- **PASS** buyer 0xF06cbA90B09bA220E59276323910157e8c560134 holds >= 0.108 OKB
- **PASS** nandout 0x934d315C0a9C0866D393B722C1805F2B6b20b816 holds >= 0.002 OKB
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | deployer | OKB | 0.02 | 0.02 | +0 |
  | keeper | OKB | 0.09 | 0.09 | +0 |
  | buyer | OKB | 0.11 | 0.11 | +0 |
  | nandout | OKB | 0.015460985 | 0.015460985 | +0 |

### 1. Deploy CIRC-TEST (script/Deploy.s.sol:DeployTest)
  - tx `0x0ecf32a74c2176da641320c913166e61feaa3919c19102ba26e73dc0900a1ab2` (deploy, gas 1,260,610)
    https://www.oklink.com/x-layer/tx/0x0ecf32a74c2176da641320c913166e61feaa3919c19102ba26e73dc0900a1ab2
  - tx `0xec1b5b0122478d33b84bbf374f403977523ad4cf2b3dbfd10711117f72b9b3c6` (deploy, gas 5,310,922)
    https://www.oklink.com/x-layer/tx/0xec1b5b0122478d33b84bbf374f403977523ad4cf2b3dbfd10711117f72b9b3c6
    pad: contract CurvePad 0xa66D7020a374BCC3e6424B9075E481617C669057
    locker: contract PositionLocker 0x205781775e8F4c613f75cc99df4c32911cBcbeB5
    TEST_WOKB_VQUOTE0 31395561920888904
    TEST_WOKB_RAISE_WEI 98999999999999997
    TEST_BEM_VQUOTE0 31712688
    LABEL CIRC-TEST
    PositionLocker 0x205781775e8F4c613f75cc99df4c32911cBcbeB5
    CurvePad       0xa66D7020a374BCC3e6424B9075E481617C669057
    CircHook       0x38061f753867aDC1C7031b087c322737466AA800
    Graduator      0x144eCBCc21BB95dfE11EFa3F500d796baFC073CC
    TokenDeployer  0x4fb0124FcE3807f684a75C4E8D914562685ae369
    protocol       0xd59D80a9C82E3a6DF1A64EAdeAA8fAd7A663c901
    sink           0x32145f040E3fd727a875cF33b4eaB60302A8A4df
- **PASS** CircHook 0x38061f753867aDC1C7031b087c322737466AA800 has exactly beforeInitialize|beforeAddLiquidity flags
- **PASS** PositionLocker 0x205781775e8F4c613f75cc99df4c32911cBcbeB5 is bound to CurvePad 0xa66D7020a374BCC3e6424B9075E481617C669057
- **PASS** protocol and sink are your addresses
- **PASS** TEST WOKB vQuote0 31395561920888904 -> raise 0.099 WOKB (tiny TEST curve)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | deployer | OKB | 0.02 | 0.019868569 | -0.000131431 |

### 2. Launch CIRC-TEST from Nandout #2
  - tx `0xbd60a097255f3163e59264a2198f5c8ce6d1acb3bfc72b3cd100cad723cda77b` (createLaunch, from nandout, value 0 OKB, gas 759,644)
    https://www.oklink.com/x-layer/tx/0xbd60a097255f3163e59264a2198f5c8ce6d1acb3bfc72b3cd100cad723cda77b
  - token **0x757f834027d086fe431c3a745659545a1cf18651**, Container 0xEDB42802E129dC8EAb9C41cCD76C1A6D869221e1, launch block 74714289
- **PASS** curve is Trading, quoted in WOKB
- **PASS** pad holds the full 1,000,000,000 supply
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | nandout | OKB | 0.015460985 | 0.015445792 | -0.000015193 |
  | nandout | WOKB | 0 | 0 | +0 |

### 3. Anti-snipe: buy inside the 30-block guard is capped at 0.5% of supply
  - tx `0x78c7bac3b4cdc42f744e723701a233d9a8beb5825b85494943adc49fdf1f8490` (buyWithOKB inside guard, from buyer, value 0.001 OKB, gas 252,402)
    https://www.oklink.com/x-layer/tx/0x78c7bac3b4cdc42f744e723701a233d9a8beb5825b85494943adc49fdf1f8490
- **PASS** buy landed in block 74714300, inside the guard (ends 74714319)
- **PASS** tokens received 5,000,000.0000 == cap 5,000,000.0000 (0.5% of supply)
- **PASS** curve-wide per-block counter recorded the capped amount
- **PASS** excess refunded: net OKB out 0.000155126 < sent 0.001 (incl. gas)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.11 | 0.109844874 | -0.000155126 |
  | buyer | WOKB | 0 | 0 | +0 |
  | buyer | CIRCTEST | 0.0000 | 5,000,000.0000 | +5,000,000.0000 |

### 4a. Buy 0.01 OKB after the guard
  - tx `0x2f0ccd4b06a7a532136abcf8f9e9bae277646c7d645db933870cf9cb551f1659` (buyWithOKB 0.01, from buyer, value 0.01 OKB, gas 107,333)
    https://www.oklink.com/x-layer/tx/0x2f0ccd4b06a7a532136abcf8f9e9bae277646c7d645db933870cf9cb551f1659
- **PASS** received 252,381,420.4717 CIRCTEST == previewBuy
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.109844874 | 0.099842727 | -0.010002147 |
  | buyer | WOKB | 0 | 0 | +0 |
  | buyer | CIRCTEST | 5,000,000.0000 | 257,381,420.4717 | +252,381,420.4717 |

### 4b. Sell half the buyer's tokens back to the curve
  - tx `0xe5fb40a261e8cf2129013e569b6e2e604dc817af0e7f5250f9a7957c44d296bb` (approve pad, from buyer, value 0 OKB, gas 46,031)
    https://www.oklink.com/x-layer/tx/0xe5fb40a261e8cf2129013e569b6e2e604dc817af0e7f5250f9a7957c44d296bb
  - tx `0x5fecdf2fe18060b63f05ec31a50d9f112886b5dc396d80b7d96e4078a70b5765` (sell, from buyer, value 0 OKB, gas 117,531)
    https://www.oklink.com/x-layer/tx/0x5fecdf2fe18060b63f05ec31a50d9f112886b5dc396d80b7d96e4078a70b5765
- **PASS** received 0.005660239 WOKB == previewSell
- **PASS** sent 128,690,710.2359 CIRCTEST
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.099842727 | 0.099839456 | -0.000003271 |
  | buyer | WOKB | 0 | 0.005660239 | +0.005660239 |
  | buyer | CIRCTEST | 257,381,420.4717 | 128,690,710.2359 | -128,690,710.2359 |

### 5. Fill the curve -> Complete
  - quote needed to complete: 0.095625086 WOKB
  - tx `0xbb8f8498eb60819a582e4840dedfd1dcb9a764b7a4e5c838b5e8035ede791ad0` (buyWithOKB fill, from buyer, value 0.095626086 OKB, gas 131,131)
    https://www.oklink.com/x-layer/tx/0xbb8f8498eb60819a582e4840dedfd1dcb9a764b7a4e5c838b5e8035ede791ad0
- **PASS** curve status Complete, CurveCompleted emitted
- **PASS** curve supply sold out
- **PASS** further curve buys revert CurveClosed
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.099839456 | 0.004211747 | -0.095627709 |
  | buyer | WOKB | 0.005660239 | 0.005660239 | +0 |
  | buyer | CIRCTEST | 128,690,710.2359 | 805,950,034.9871 | +677,259,324.7513 |

### 5b. Curve fee split 50/30/20 (CurvePad FeeVault)
- **PASS** FeeVault total 0.001114926 WOKB == sum of 4 Trade-event fees
  - fees: 0.000001501, 0.0001, 0.000057174, 0.000956251 WOKB (total 0.001114926)
- **PASS** Container 0.000557463 = 50%
- **PASS** protocol 0.000334478 = 30% (+rounding)
- **PASS** sink 0.000222985 = 20%
- **PASS** shares sum to the total fee

### 6. Keeper graduates (permissionless)
  - tx `0x9c2b741a560fb82d13f1013d8c8a18af33169201cecf7677738fb083c446b58b` (graduate, from keeper, value 0 OKB, gas 751,097)
    https://www.oklink.com/x-layer/tx/0x9c2b741a560fb82d13f1013d8c8a18af33169201cecf7677738fb083c446b58b
  - poolId 0x67932a976b8b915aac17b6cadab35e9c13d6adffdf5ddfe3e9dc3b072dabd6b8, position #20160, quote in LP 0.099 WOKB, tokens in LP 194,049,965.0129
- **PASS** curve status Graduated
- **PASS** position NFT owned by PositionLocker
- **PASS** locker records the launch's Container
- **PASS** hook reports the pool open
- **PASS** Graduator holds nothing
- **PASS** pool opened at the curve's final price (within 0.1%)
- **PASS** pool liquidity == locked position liquidity (4,383,029,378,896,919,952,481)
  - graduation dust booked to protocol: 0 WOKB
- **PASS** second graduate reverts AlreadyGraduated
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | keeper | OKB | 0.09 | 0.089984978 | -0.000015022 |
  | keeper | WOKB | 0 | 0 | +0 |
  | keeper | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |

### 7a. Universal Router 2.1.2: buy with WOKB
  - tx `0x2daace7370b05544e0a6dcefc783fa2085f96c96d14730521a1bb1809742ee30` (approve Permit2, from buyer, value 0 OKB, gas 46,337)
    https://www.oklink.com/x-layer/tx/0x2daace7370b05544e0a6dcefc783fa2085f96c96d14730521a1bb1809742ee30
  - tx `0x3cc438853e6f7c0639deeee24a07d9a0228e5651b69f12716b9f8a968d12454d` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 47,614)
    https://www.oklink.com/x-layer/tx/0x3cc438853e6f7c0639deeee24a07d9a0228e5651b69f12716b9f8a968d12454d
  - tx `0xf23ee70fead3551771fd06cc49856ceb8ff44f93cbd1f9847ce5cfec6f8913d2` (Universal Router V4_SWAP exact-in 0.002, from buyer, value 0 OKB, gas 138,677)
    https://www.oklink.com/x-layer/tx/0xf23ee70fead3551771fd06cc49856ceb8ff44f93cbd1f9847ce5cfec6f8913d2
- **PASS** paid 0.002 WOKB, got 3,804,901.2748 CIRCTEST (quoted 3,804,901.2748)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.004211747 | 0.004207094 | -0.000004653 |
  | buyer | WOKB | 0.005660239 | 0.003660239 | -0.002 |
  | buyer | CIRCTEST | 805,950,034.9871 | 809,754,936.2619 | +3,804,901.2748 |

### 7b. Universal Router 2.1.2: sell 10% of the buyer's tokens
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.004207094 | 0.00420617 | -0.000000924 |
  | buyer | WOKB | 0.003660239 | 0.003660239 | +0 |
  | buyer | CIRCTEST | 809,754,936.2619 | 809,754,936.2619 | +0.0000 |

**STOPPED: approve Permit2: transaction not sent / reverted: Error: server returned a null response when a non-null response was expected**

E2E RESULT: FAIL

## Resumed from step 7b (2026-10-31 21:56:04 UTC) on the same CIRC-TEST instance
- network: X Layer chain id 196 (mainnet)
- started: 2026-10-31 21:56:04 UTC, block 74714728
- spend cap: 0.5 OKB msg.value across all wallets (gas excluded)
- **PASS** CIRC-TEST token 0x757f834027d086fe431c3a745659545a1cf18651 is Graduated on pad 0xa66D7020a374BCC3e6424B9075E481617C669057
- **PASS** position #20160 is locked
- msg.value already spent before the stop: 0.106626086 OKB (counted against the 0.5 cap)

### 7b. Universal Router 2.1.2: sell 10% of the buyer's tokens
  - tx `0x0bf775aa6eff79316a834581fc94f104ac5d7cb60c35f5a251a18bd908b82801` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 47,686)
    https://www.oklink.com/x-layer/tx/0x0bf775aa6eff79316a834581fc94f104ac5d7cb60c35f5a251a18bd908b82801
  - tx `0xf484b2b9ebdb3b500dd7944c48e1848a8288fd67abd0e7ee7a7ca1b648125970` (Universal Router V4_SWAP exact-in 80,975,493.6262, from buyer, value 0 OKB, gas 139,068)
    https://www.oklink.com/x-layer/tx/0xf484b2b9ebdb3b500dd7944c48e1848a8288fd67abd0e7ee7a7ca1b648125970
- **PASS** sold 80,975,493.6262 CIRCTEST for 0.029936438 WOKB (quoted 0.029936438)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.00420617 | 0.004202435 | -0.000003735 |
  | buyer | WOKB | 0.003660239 | 0.033596677 | +0.029936438 |
  | buyer | CIRCTEST | 809,754,936.2619 | 728,779,442.6357 | -80,975,493.6262 |

### 8. Locker collect (permissionless) + LP fee split 50/30/20
  - tx `0x879ec96080b566e248b11b23726d1f93a541e78347883302ba681670f1e8050a` (collect, from keeper, value 0 OKB, gas 387,531)
    https://www.oklink.com/x-layer/tx/0x879ec96080b566e248b11b23726d1f93a541e78347883302ba681670f1e8050a
  - collected 809754936261898194576158 (currency0 0x757f834027d086fe431c3a745659545a1cf18651) and 19999999999999 (currency1 0xe538905cf8410324e03A5A23C1c177a474D59b2b) wei
- **PASS** fees collected in both currencies (one UR buy, one UR sell)
- **PASS** CIRCTEST: Container 404877468130949097288079 / protocol 242926480878569458372848 / sink 161950987252379638915231 = 50/30/20
- **PASS** WOKB: Container 9999999999999 / protocol 6000000000001 / sink 3999999999999 = 50/30/20
- **PASS** locked liquidity unchanged by collect
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | keeper | OKB | 0.089984978 | 0.089977227 | -0.000007751 |

### 9. Protocol and sink claims (permissionless push to your addresses)
  - tx `0x5d985d5dbea622e22432b7d37f433db22cdd859e1816a3ee2b5026d1d4d51f9a` (CurvePad.claim WOKB -> protocol, from keeper, value 0 OKB, gas 67,216)
    https://www.oklink.com/x-layer/tx/0x5d985d5dbea622e22432b7d37f433db22cdd859e1816a3ee2b5026d1d4d51f9a
- **PASS** protocol received 0.000334478 WOKB from CurvePad
  - tx `0x4f9cc19a73cd3950fdadf1b5696eafde6d2e7d69d22ab85d65b1a68912bcde5c` (CurvePad.claim WOKB -> sink, from keeper, value 0 OKB, gas 67,216)
    https://www.oklink.com/x-layer/tx/0x4f9cc19a73cd3950fdadf1b5696eafde6d2e7d69d22ab85d65b1a68912bcde5c
- **PASS** sink received 0.000222985 WOKB from CurvePad
  - tx `0x99d4a5cf22e91482c4faa22fab8128ea5c4c48a4934c68d9f34cf72e196ceb14` (PositionLocker.claim WOKB -> protocol, from keeper, value 0 OKB, gas 50,016)
    https://www.oklink.com/x-layer/tx/0x99d4a5cf22e91482c4faa22fab8128ea5c4c48a4934c68d9f34cf72e196ceb14
- **PASS** protocol received 0.000006 WOKB from PositionLocker
  - tx `0x9f39eb7340a96fb0198f6c1aa431f8252e00f42568f729a41a147b2d2339e329` (PositionLocker.claim WOKB -> sink, from keeper, value 0 OKB, gas 50,016)
    https://www.oklink.com/x-layer/tx/0x9f39eb7340a96fb0198f6c1aa431f8252e00f42568f729a41a147b2d2339e329
- **PASS** sink received 0.000004 WOKB from PositionLocker
- **PASS** claim() cannot push creator fees (CreatorClaimOnly)
- **PASS** non-holder claimCreator reverts NotHolder

### 10. Container open + creator claim to Container + holder withdraw
  - tx `0x6fec6901c5be4b45b157636dd85f8b7f9466842ba503829365af4d86856591b0` (TapeOut opener.open (fee 0.08 OKB), from keeper, value 0.08 OKB, gas 169,734)
    https://www.oklink.com/x-layer/tx/0x6fec6901c5be4b45b157636dd85f8b7f9466842ba503829365af4d86856591b0
- **PASS** Container 0xEDB42802E129dC8EAb9C41cCD76C1A6D869221e1 deployed
  - tx `0x76b2e789894ac6de3a25dd629d8f929341449a4d7c2d42a45df9e55fd47194a4` (claimCreator -> Container, from nandout, value 0 OKB, gas 75,738)
    https://www.oklink.com/x-layer/tx/0x76b2e789894ac6de3a25dd629d8f929341449a4d7c2d42a45df9e55fd47194a4
- **PASS** Container received 0.000557463 WOKB creator fees
  - Container execute fee: 0.0013 OKB
  - tx `0x615ce233cf344a0bc8bcb66f4f87cd8dbc699f50ed384cb5d3c5ef3ffa91a397` (Container.execute withdraw, from nandout, value 0.0013 OKB, gas 129,035)
    https://www.oklink.com/x-layer/tx/0x615ce233cf344a0bc8bcb66f4f87cd8dbc699f50ed384cb5d3c5ef3ffa91a397
- **PASS** holder withdrew 0.000557463 WOKB from the Container
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | keeper | OKB | 0.089972538 | 0.009969143 | -0.080003395 |
  | keeper | WOKB | 0 | 0 | +0 |
  | keeper | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |
  | nandout | OKB | 0.015445792 | 0.014141697 | -0.001304095 |
  | nandout | WOKB | 0 | 0.000557463 | +0.000557463 |
  | nandout | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |

### 11. Fallback: holder claims LP creator fees straight to the holder wallet
  - tx `0xe3df722473ad624980159de85544f04b2e1d9be61cd9f4ed09d646a39381a6ae` (locker.claimCreator WOKB -> holder, from nandout, value 0 OKB, gas 60,591)
    https://www.oklink.com/x-layer/tx/0xe3df722473ad624980159de85544f04b2e1d9be61cd9f4ed09d646a39381a6ae
- **PASS** holder wallet received 0.00001 WOKB
  - tx `0x83ca2b767d1007e1c7f4d913d55fbb3c3813a5b9e7cdcb3f3ee398c899e50b2a` (locker.claimCreator CIRCTEST -> holder, from nandout, value 0 OKB, gas 84,877)
    https://www.oklink.com/x-layer/tx/0x83ca2b767d1007e1c7f4d913d55fbb3c3813a5b9e7cdcb3f3ee398c899e50b2a
- **PASS** holder wallet received 404,877.4681 CIRCTEST
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | nandout | OKB | 0.014141697 | 0.014138788 | -0.000002909 |
  | nandout | WOKB | 0.000557463 | 0.000567463 | +0.00001 |
  | nandout | CIRCTEST | 0.0000 | 404,877.4681 | +404,877.4681 |

### 12. Cleanup: sell all CIRCTEST back into the pool, unwrap, sweep to MAIN_WALLET
  - tx `0x1db627c12085035b4a70a0979e23e6a74f27820c0de15e68598d395342917c14` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 30,598)
    https://www.oklink.com/x-layer/tx/0x1db627c12085035b4a70a0979e23e6a74f27820c0de15e68598d395342917c14
  - tx `0x7cbfb3e662c7215072ba87e315998ca3036cb4549d18f16fdfbf930c7a7de863` (Universal Router V4_SWAP exact-in 728,779,442.6357, from buyer, value 0 OKB, gas 116,263)
    https://www.oklink.com/x-layer/tx/0x7cbfb3e662c7215072ba87e315998ca3036cb4549d18f16fdfbf930c7a7de863
- **PASS** buyer holds no CIRCTEST
  - tx `0x6d29b26be7065a0df83c40af60d3e5ccac2409f5bea563a74388464aff2893e4` (approve Permit2, from nandout, value 0 OKB, gas 46,223)
    https://www.oklink.com/x-layer/tx/0x6d29b26be7065a0df83c40af60d3e5ccac2409f5bea563a74388464aff2893e4
  - tx `0x2de3102c3dff8d5eb1b65fb7cb762ca7a9a44e1896357d0e24b5bc8f89537880` (Permit2 approve Universal Router, from nandout, value 0 OKB, gas 47,674)
    https://www.oklink.com/x-layer/tx/0x2de3102c3dff8d5eb1b65fb7cb762ca7a9a44e1896357d0e24b5bc8f89537880
  - tx `0x07eda206080e6e04ba648db0ab2ae51d1a809ffdd6ed0ce644dfbc33ae0dc017` (Universal Router V4_SWAP exact-in 404,877.4681, from nandout, value 0 OKB, gas 117,088)
    https://www.oklink.com/x-layer/tx/0x07eda206080e6e04ba648db0ab2ae51d1a809ffdd6ed0ce644dfbc33ae0dc017
- **PASS** nandout holds no CIRCTEST
  - tx `0x0c00ce553ca0c81d502631125ba2e87c43910f36c9d8b0ef2dd812fa2a5c8065` (unwrap WOKB, from buyer, value 0 OKB, gas 34,477)
    https://www.oklink.com/x-layer/tx/0x0c00ce553ca0c81d502631125ba2e87c43910f36c9d8b0ef2dd812fa2a5c8065
  - tx `0x9c3c22028ba448eaf43b1a791c0bcf8bf0769474121504655cd54c6249ec092b` (sweep 0.089469849 OKB -> MAIN_WALLET, from buyer, value 0.089469849 OKB, gas 21,000)
    https://www.oklink.com/x-layer/tx/0x9c3c22028ba448eaf43b1a791c0bcf8bf0769474121504655cd54c6249ec092b
  - buyer left with 0.000001 OKB
  - tx `0x97a2f2cbc66069ef6edd38bea8c6ef62278bc72794b420ca4463be22eeabafc0` (sweep 0.009967723 OKB -> MAIN_WALLET, from keeper, value 0.009967723 OKB, gas 21,000)
    https://www.oklink.com/x-layer/tx/0x97a2f2cbc66069ef6edd38bea8c6ef62278bc72794b420ca4463be22eeabafc0
  - keeper left with 0.000001 OKB
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.004202435 | 0.000001 | -0.004201435 |
  | buyer | WOKB | 0.033596677 | 0 | -0.033596677 |
  | buyer | CIRCTEST | 728,779,442.6357 | 0.0000 | -728,779,442.6357 |
  | keeper | OKB | 0.009969143 | 0.000001 | -0.009968143 |
  | keeper | WOKB | 0 | 0 | +0 |
  | keeper | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |
  | nandout | OKB | 0.014138788 | 0.014134568 | -0.00000422 |
  | nandout | WOKB | 0.000567463 | 0.000575286 | +0.000007823 |
  | nandout | CIRCTEST | 404,877.4681 | 0.0000 | -404,877.4681 |

### 13. Locked LP (stays forever by design)
- locked position #20160: ~0.019359955 OKB (as WOKB) + ~992,303,279.3308 CIRCTEST

## Summary

- CurvePad (CIRC-TEST): `0xa66D7020a374BCC3e6424B9075E481617C669057`; PositionLocker `0x205781775e8F4c613f75cc99df4c32911cBcbeB5`; CircHook `0x38061f753867aDC1C7031b087c322737466AA800`; Graduator `0x144eCBCc21BB95dfE11EFa3F500d796baFC073CC`
- token `0x757f834027d086fe431c3a745659545a1cf18651`; pool `0x67932a976b8b915aac17b6cadab35e9c13d6adffdf5ddfe3e9dc3b072dabd6b8`; locked position #20160
- msg.value spent (cap 0.5 OKB): 0.187926086 OKB
- gas paid, deploy: 0.000131431 OKB
- gas paid, e2e: 0.00007453 OKB
- gas paid, cleanup: 0.000008686 OKB
- gas paid, total: 0.000214648 OKB
- prod deploy estimate: ~0.000131431 OKB gas (same contracts)
- checks: 57 PASS, 0 FAIL, 0 SKIPPED

E2E RESULT: PASS
