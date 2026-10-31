# CIRC-TEST end-to-end results

- network: X Layer chain id 196 (**anvil fork rehearsal**, nothing on chain)
- started: 2026-10-31 21:15:17 UTC, block 74712276
- spend cap: 0.5 OKB msg.value across all wallets (gas excluded)

### 0. Preflight
- **PASS** deployer, keeper, buyer and Nandout wallet are four distinct addresses
- **PASS** CIRC_PROTOCOL and CIRC_SINK differ (needed for the split check)
- **PASS** Nandout #2 is held by the Nandout wallet
  - Nandout #2 Container 0xEDB42802E129dC8EAb9C41cCD76C1A6D869221e1: not opened yet; open fee 0.08 OKB; gas price 1.0175 gwei
  - estimate: TEST deploy 0.012719239 OKB gas; e2e run 0.004578926 OKB gas + ~0.19 OKB value (fill ~0.1, Container open 0.08, withdraw fee 0.0013); prod deploy 0.012719239 OKB gas
- **PASS** deployer 0xC0FBD5c6Fc9202f3DbFE3619C3609fcfa903ccd9 holds >= 0.003 OKB
- **PASS** keeper 0x8b5dcc729bA86737636531CF87BD3acaf9a9c97E holds >= 0.083 OKB
- **PASS** buyer 0xf81a347f85F3AB0d4C0B418F1CfB6D88886b10B3 holds >= 0.115 OKB
- **PASS** nandout 0x934d315C0a9C0866D393B722C1805F2B6b20b816 holds >= 0.002 OKB
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | deployer | OKB | 0.01 | 0.01 | +0 |
  | keeper | OKB | 0.09 | 0.09 | +0 |
  | buyer | OKB | 0.13 | 0.13 | +0 |
  | nandout | OKB | 0.015460985 | 0.015460985 | +0 |

### 1. Deploy CIRC-TEST (script/Deploy.s.sol:DeployTest)
  - tx `0x8e300e14021a8ea4d5b4f214b663c1eaa9a4f83799e00f78581997a0f5077579` (deploy, gas 1,260,178)  _(anvil fork)_
    https://www.oklink.com/x-layer/tx/0x8e300e14021a8ea4d5b4f214b663c1eaa9a4f83799e00f78581997a0f5077579
  - tx `0xccfeb8fcaeeb12772d679a0a89ad2921a79aba0a6c2be58df38b36146b19aed0` (deploy, gas 5,310,490)  _(anvil fork)_
    https://www.oklink.com/x-layer/tx/0xccfeb8fcaeeb12772d679a0a89ad2921a79aba0a6c2be58df38b36146b19aed0
    pad: contract CurvePad 0xD0FFCE58C3e1345618C4b1444f6623d33Ef5F4cf
    locker: contract PositionLocker 0x2304CFe3b82BA542D9793E5aFEe9a978f1554049
    TEST_WOKB_VQUOTE0 31395561920888904
    TEST_WOKB_RAISE_WEI 98999999999999997
    TEST_BEM_VQUOTE0 31712688
    LABEL CIRC-TEST
    PositionLocker 0x2304CFe3b82BA542D9793E5aFEe9a978f1554049
    CurvePad       0xD0FFCE58C3e1345618C4b1444f6623d33Ef5F4cf
    CircHook       0x64464284cad128a7f76F7C1E4BD9b6989cDae800
    Graduator      0x9Ef1d78FF11efc7D9C9a72919A80C78a6f0514b7
    TokenDeployer  0x3a6aF025d01d37799848328B6533e43D0F68Ee9b
    protocol       0x000000000000000000000000000000000000dEaD
    sink           0x000000000000000000000000000000000000bEEF
- **PASS** CircHook 0x64464284cad128a7f76F7C1E4BD9b6989cDae800 has exactly beforeInitialize|beforeAddLiquidity flags
- **PASS** PositionLocker 0x2304CFe3b82BA542D9793E5aFEe9a978f1554049 is bound to CurvePad 0xD0FFCE58C3e1345618C4b1444f6623d33Ef5F4cf
- **PASS** protocol and sink are your addresses
- **PASS** TEST WOKB vQuote0 31395561920888904 -> raise 0.099 WOKB (tiny TEST curve)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | deployer | OKB | 0.01 | 0.009896259 | -0.000103741 |

### 2. Launch CIRC-TEST from Nandout #2
  - tx `0x36c3eb0d5f42071bbc5efdb817de787d417815025d4adfac7092bf4b8a2d3cb7` (createLaunch, from nandout, value 0 OKB, gas 759,644)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x36c3eb0d5f42071bbc5efdb817de787d417815025d4adfac7092bf4b8a2d3cb7
  - token **0x9d0bad5aff2d102ffcb7f668214ff350cb544608**, Container 0xEDB42802E129dC8EAb9C41cCD76C1A6D869221e1, launch block 74712279
- **PASS** curve is Trading, quoted in WOKB
- **PASS** pad holds the full 1,000,000,000 supply
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | nandout | OKB | 0.015460985 | 0.015450693 | -0.000010292 |
  | nandout | WOKB | 0 | 0 | +0 |

### 3. Anti-snipe: buy inside the 30-block guard is capped at 0.5% of supply
  - tx `0xb18703530ffa440ca46435812876f28b0fb6e3c5fe3e461ba7f269dba5daea62` (buyWithOKB inside guard, from buyer, value 0.001 OKB, gas 252,402)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xb18703530ffa440ca46435812876f28b0fb6e3c5fe3e461ba7f269dba5daea62
- **PASS** buy landed in block 74712280, inside the guard (ends 74712309)
- **PASS** tokens received 5,000,000.0000 == cap 5,000,000.0000 (0.5% of supply)
- **PASS** curve-wide per-block counter recorded the capped amount
- **PASS** excess refunded: net OKB out 0.000153074 < sent 0.001 (incl. gas)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.13 | 0.129846926 | -0.000153074 |
  | buyer | WOKB | 0 | 0 | +0 |
  | buyer | CIRCTEST | 0.0000 | 5,000,000.0000 | +5,000,000.0000 |

### 4a. Buy 0.01 OKB after the guard
  - tx `0xa77b5d4630fcd9a74cfe9505576376abb8045728d3186f9ffa14b2c6a3ebade5` (buyWithOKB 0.01, from buyer, value 0.01 OKB, gas 107,333)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xa77b5d4630fcd9a74cfe9505576376abb8045728d3186f9ffa14b2c6a3ebade5
- **PASS** received 252,381,420.4717 CIRCTEST == previewBuy
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.129846926 | 0.119846906 | -0.01000002 |
  | buyer | WOKB | 0 | 0 | +0 |
  | buyer | CIRCTEST | 5,000,000.0000 | 257,381,420.4717 | +252,381,420.4717 |

### 4b. Sell half the buyer's tokens back to the curve
  - tx `0x447879fab10fa0255b7ac9431a81d5c561d575ab32d583f6992e8df7a1828ed1` (approve pad, from buyer, value 0 OKB, gas 46,031)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x447879fab10fa0255b7ac9431a81d5c561d575ab32d583f6992e8df7a1828ed1
  - tx `0xe2f12463ee8c99df57d44dfe4c6a2d0458b39bcfdd66bec5f18496ddc9413f52` (sell, from buyer, value 0 OKB, gas 117,531)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xe2f12463ee8c99df57d44dfe4c6a2d0458b39bcfdd66bec5f18496ddc9413f52
- **PASS** received 0.005660239 WOKB == previewSell
- **PASS** sent 128,690,710.2359 CIRCTEST
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.119846906 | 0.119846881 | -0.000000025 |
  | buyer | WOKB | 0 | 0.005660239 | +0.005660239 |
  | buyer | CIRCTEST | 257,381,420.4717 | 128,690,710.2359 | -128,690,710.2359 |

### 5. Fill the curve -> Complete
  - quote needed to complete: 0.095625086 WOKB
  - tx `0x77aaa85c4eb980ce285f53ff63d88e01b298ce695dbfa009ace6ed0d156d3916` (buyWithOKB fill, from buyer, value 0.095626086 OKB, gas 131,131)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x77aaa85c4eb980ce285f53ff63d88e01b298ce695dbfa009ace6ed0d156d3916
- **PASS** curve status Complete, CurveCompleted emitted
- **PASS** curve supply sold out
- **PASS** further curve buys revert CurveClosed
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.119846881 | 0.024221779 | -0.095625103 |
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
  - tx `0x6bedbe6cf91c95031914759f5493dbc86a9345e7b4a2d043ae71fa66da7b82a0` (graduate, from keeper, value 0 OKB, gas 751,097)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x6bedbe6cf91c95031914759f5493dbc86a9345e7b4a2d043ae71fa66da7b82a0
  - poolId 0xdfa5d90e81ad6e672796ca32ff67931c928df50aee6fabf7ebbc904e863dc430, position #20160, quote in LP 0.099 WOKB, tokens in LP 194,049,965.0129
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
  | keeper | OKB | 0.09 | 0.089999917 | -0.000000083 |
  | keeper | WOKB | 0 | 0 | +0 |
  | keeper | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |

### 7a. Universal Router 2.1.2: buy with WOKB
  - tx `0xed5bf25f61a78b6991baa3d7d2f96e5fddf343ae9ffbc68ae031d7de6fcaeda8` (approve Permit2, from buyer, value 0 OKB, gas 46,337)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xed5bf25f61a78b6991baa3d7d2f96e5fddf343ae9ffbc68ae031d7de6fcaeda8
  - tx `0xa7ccdc09fc88b969448671641a37da2b5499c39799f7ac1637fb0714fba7190d` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 47,614)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xa7ccdc09fc88b969448671641a37da2b5499c39799f7ac1637fb0714fba7190d
  - tx `0x1f7c63ab00f2950ea12915067f428e5eec71904242d8b89d4fe26b72faf0f1ac` (Universal Router V4_SWAP exact-in 0.002, from buyer, value 0 OKB, gas 138,677)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x1f7c63ab00f2950ea12915067f428e5eec71904242d8b89d4fe26b72faf0f1ac
- **PASS** paid 0.002 WOKB, got 3,804,901.2748 CIRCTEST (quoted 3,804,901.2748)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.024221779 | 0.02422176 | -0.000000019 |
  | buyer | WOKB | 0.005660239 | 0.003660239 | -0.002 |
  | buyer | CIRCTEST | 805,950,034.9871 | 809,754,936.2619 | +3,804,901.2748 |

### 7b. Universal Router 2.1.2: sell 10% of the buyer's tokens
  - tx `0x53861e5c4d949461621306baffabbe94be80cb747ba244f564f682e422dafa60` (approve Permit2, from buyer, value 0 OKB, gas 46,223)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x53861e5c4d949461621306baffabbe94be80cb747ba244f564f682e422dafa60
  - tx `0x0378f7bca80be876516820d9dd6e053287dd885be1ac0b01b7e54a8be2bc8e11` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 47,686)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x0378f7bca80be876516820d9dd6e053287dd885be1ac0b01b7e54a8be2bc8e11
  - tx `0xe1ac9be5b4557ced3f7a85af9d4b185d9d96e103e5a97f0453be65450c3cc42e` (Universal Router V4_SWAP exact-in 80,975,493.6262, from buyer, value 0 OKB, gas 139,068)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xe1ac9be5b4557ced3f7a85af9d4b185d9d96e103e5a97f0453be65450c3cc42e
- **PASS** sold 80,975,493.6262 CIRCTEST for 0.029936438 WOKB (quoted 0.029936438)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.02422176 | 0.024221747 | -0.000000013 |
  | buyer | WOKB | 0.003660239 | 0.033596677 | +0.029936438 |
  | buyer | CIRCTEST | 809,754,936.2619 | 728,779,442.6357 | -80,975,493.6262 |

### 8. Locker collect (permissionless) + LP fee split 50/30/20
  - tx `0x9dac90cb1e1d0263cadae2fbde542ce8275e38e68bb4d3d7f638575023d53957` (collect, from keeper, value 0 OKB, gas 387,531)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x9dac90cb1e1d0263cadae2fbde542ce8275e38e68bb4d3d7f638575023d53957
  - collected 809754936261898194576158 (currency0 0x9d0bad5aff2d102ffcb7f668214ff350cb544608) and 19999999999999 (currency1 0xe538905cf8410324e03A5A23C1c177a474D59b2b) wei
- **PASS** fees collected in both currencies (one UR buy, one UR sell)
- **PASS** CIRCTEST: Container 404877468130949097288079 / protocol 242926480878569458372848 / sink 161950987252379638915231 = 50/30/20
- **PASS** WOKB: Container 9999999999999 / protocol 6000000000001 / sink 3999999999999 = 50/30/20
- **PASS** locked liquidity unchanged by collect
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | keeper | OKB | 0.089999917 | 0.0899999 | -0.000000017 |

### 9. Protocol and sink claims (permissionless push to your addresses)
  - tx `0xbc055965a851a34888b4e38776d8db4bbfd4fb4f0c193b2bc8068b8698497d66` (CurvePad.claim WOKB -> protocol, from keeper, value 0 OKB, gas 49,900)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xbc055965a851a34888b4e38776d8db4bbfd4fb4f0c193b2bc8068b8698497d66
- **PASS** protocol received 0.000334478 WOKB from CurvePad
  - tx `0x332d16aa8c2964ccd556e18c0c0cd4424bb4d1320a920838254b087593ee5c20` (CurvePad.claim WOKB -> sink, from keeper, value 0 OKB, gas 67,000)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x332d16aa8c2964ccd556e18c0c0cd4424bb4d1320a920838254b087593ee5c20
- **PASS** sink received 0.000222985 WOKB from CurvePad
  - tx `0xda493d46133c28b98cefd95e368efc4cad2dee7d217d0db027443c4e6a54533d` (PositionLocker.claim WOKB -> protocol, from keeper, value 0 OKB, gas 49,800)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xda493d46133c28b98cefd95e368efc4cad2dee7d217d0db027443c4e6a54533d
- **PASS** protocol received 0.000006 WOKB from PositionLocker
  - tx `0x26fcc0ae2d82576cbcb957f9d748c4603040426438c48a1a15e28af38b2ce294` (PositionLocker.claim WOKB -> sink, from keeper, value 0 OKB, gas 49,800)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x26fcc0ae2d82576cbcb957f9d748c4603040426438c48a1a15e28af38b2ce294
- **PASS** sink received 0.000004 WOKB from PositionLocker
- **PASS** claim() cannot push creator fees (CreatorClaimOnly)
- **PASS** non-holder claimCreator reverts NotHolder

### 10. Container open + creator claim to Container + holder withdraw
  - tx `0x762ba814beb8df0ac7526cd4653a1da0db98779267bc78eff7c82b93f4846177` (TapeOut opener.open (fee 0.08 OKB), from keeper, value 0.08 OKB, gas 169,734)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x762ba814beb8df0ac7526cd4653a1da0db98779267bc78eff7c82b93f4846177
- **PASS** Container 0xEDB42802E129dC8EAb9C41cCD76C1A6D869221e1 deployed
  - tx `0x0bb48f154fba02cbfd9fe545c4a13deb457820187eba065c66195f32f14b57b1` (claimCreator -> Container, from nandout, value 0 OKB, gas 75,738)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x0bb48f154fba02cbfd9fe545c4a13deb457820187eba065c66195f32f14b57b1
- **PASS** Container received 0.000557463 WOKB creator fees
  - Container execute fee: 0.0013 OKB
  - tx `0x28e4e18983eb51fa148f73a623983564462552e24cf7d4af688eed6e412af3ed` (Container.execute withdraw, from nandout, value 0.0013 OKB, gas 129,035)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x28e4e18983eb51fa148f73a623983564462552e24cf7d4af688eed6e412af3ed
- **PASS** holder withdrew 0.000557463 WOKB from the Container
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | keeper | OKB | 0.089999893 | 0.009999889 | -0.080000004 |
  | keeper | WOKB | 0 | 0 | +0 |
  | keeper | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |
  | nandout | OKB | 0.015450693 | 0.014150689 | -0.001300004 |
  | nandout | WOKB | 0 | 0.000557463 | +0.000557463 |
  | nandout | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |

### 11. Fallback: holder claims LP creator fees straight to the holder wallet
  - tx `0xf5be3fede6ece80034e989709f1a00d6d4eec1b48ffbc5b1f55eaeeb5e8d1223` (locker.claimCreator WOKB -> holder, from nandout, value 0 OKB, gas 60,591)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xf5be3fede6ece80034e989709f1a00d6d4eec1b48ffbc5b1f55eaeeb5e8d1223
- **PASS** holder wallet received 0.00001 WOKB
  - tx `0x1ca0d9d26102d4e2f41ceb099b71c1166a4e0a19ca586e2da74baf5d0943db91` (locker.claimCreator CIRCTEST -> holder, from nandout, value 0 OKB, gas 84,877)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x1ca0d9d26102d4e2f41ceb099b71c1166a4e0a19ca586e2da74baf5d0943db91
- **PASS** holder wallet received 404,877.4681 CIRCTEST
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | nandout | OKB | 0.014150689 | 0.014150687 | -0.000000002 |
  | nandout | WOKB | 0.000557463 | 0.000567463 | +0.00001 |
  | nandout | CIRCTEST | 0.0000 | 404,877.4681 | +404,877.4681 |

### 12. Cleanup: sell all CIRCTEST back into the pool, unwrap, sweep to MAIN_WALLET
  - tx `0x009e9bd8426eca2883826698bc8498130f7f65d90bff6cab17c14c475d5a9394` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 30,598)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x009e9bd8426eca2883826698bc8498130f7f65d90bff6cab17c14c475d5a9394
  - tx `0x0d4145c7792349094cdd4e79108f8c5751b477af9f45a8c1acc2829890887054` (Universal Router V4_SWAP exact-in 728,779,442.6357, from buyer, value 0 OKB, gas 116,263)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x0d4145c7792349094cdd4e79108f8c5751b477af9f45a8c1acc2829890887054
- **PASS** buyer holds no CIRCTEST
  - tx `0x8f26b44c55c968a25b28b3e2be7423bc493409563dfc6753ffb7a4b4b9bc5316` (approve Permit2, from nandout, value 0 OKB, gas 46,223)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x8f26b44c55c968a25b28b3e2be7423bc493409563dfc6753ffb7a4b4b9bc5316
  - tx `0xaab878b3a78d53184a67b55add77555c093f40e62b87eff8a71dcceebaf25e97` (Permit2 approve Universal Router, from nandout, value 0 OKB, gas 47,674)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xaab878b3a78d53184a67b55add77555c093f40e62b87eff8a71dcceebaf25e97
  - tx `0xbafe8e19de8f5f36d01516d448c7fcec01f5b71afdabcdbcb6a5b400f2f7cf10` (Universal Router V4_SWAP exact-in 404,877.4681, from nandout, value 0 OKB, gas 117,088)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xbafe8e19de8f5f36d01516d448c7fcec01f5b71afdabcdbcb6a5b400f2f7cf10
- **PASS** nandout holds no CIRCTEST
  - tx `0xb0fa9092c05a9d2b8208d48183513b343b1c66ad4c18fd83907da1472f46ec65` (unwrap WOKB, from buyer, value 0 OKB, gas 34,477)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0xb0fa9092c05a9d2b8208d48183513b343b1c66ad4c18fd83907da1472f46ec65
  - tx `0x7fb10fdd8dda7b95e7501767c6adfd965921476fdf587c24c9bdee031a863e33` (sweep 0.109472206 OKB -> MAIN_WALLET, from buyer, value 0.109472206 OKB, gas 21,000)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x7fb10fdd8dda7b95e7501767c6adfd965921476fdf587c24c9bdee031a863e33
  - buyer left with 0.000022 OKB
  - tx `0x84ae0bde7db488fee7d8715bbed9fa1050a000337f8e35b52f2c4be543125083` (sweep 0.009977889 OKB -> MAIN_WALLET, from keeper, value 0.009977889 OKB, gas 21,000)  _(anvil fork, not on chain)_
    https://www.oklink.com/x-layer/tx/0x84ae0bde7db488fee7d8715bbed9fa1050a000337f8e35b52f2c4be543125083
  - keeper left with 0.000022 OKB
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.024221747 | 0.000022 | -0.024199747 |
  | buyer | WOKB | 0.033596677 | 0 | -0.033596677 |
  | buyer | CIRCTEST | 728,779,442.6357 | 0.0000 | -728,779,442.6357 |
  | keeper | OKB | 0.009999889 | 0.000022 | -0.009977889 |
  | keeper | WOKB | 0 | 0 | +0 |
  | keeper | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |
  | nandout | OKB | 0.014150687 | 0.014150686 | -0.000000002 |
  | nandout | WOKB | 0.000567463 | 0.000575286 | +0.000007823 |
  | nandout | CIRCTEST | 404,877.4681 | 0.0000 | -404,877.4681 |

### 13. Locked LP (stays forever by design)
- locked position #20160: ~0.019359955 OKB (as WOKB) + ~992,303,279.3308 CIRCTEST

## Summary

- CurvePad (CIRC-TEST): `0xD0FFCE58C3e1345618C4b1444f6623d33Ef5F4cf`; PositionLocker `0x2304CFe3b82BA542D9793E5aFEe9a978f1554049`; CircHook `0x64464284cad128a7f76F7C1E4BD9b6989cDae800`; Graduator `0x9Ef1d78FF11efc7D9C9a72919A80C78a6f0514b7`
- token `0x9d0bad5aff2d102ffcb7f668214ff350cb544608`; pool `0xdfa5d90e81ad6e672796ca32ff67931c928df50aee6fabf7ebbc904e863dc430`; locked position #20160
- msg.value spent (cap 0.5 OKB): 0.187926086 OKB
- gas, deploy: 0.000103741 OKB
- gas, e2e: 0.000013497 OKB
- gas, cleanup: 0.000000003 OKB
- prod deploy estimate: ~0.000103741 OKB gas (same contracts)
- checks: 55 PASS, 0 FAIL, 0 SKIPPED

E2E RESULT: PASS
