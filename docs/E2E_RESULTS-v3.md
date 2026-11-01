# CIRC-TEST end-to-end results

- network: X Layer chain id 196 (mainnet)
- started: 2026-11-01 16:57:45 UTC, block 74783229
- spend cap: 0.5 OKB msg.value across all wallets (gas excluded)
- sweep target MAIN_WALLET: 0x1F4d4B97d9cFD57b2F5CED5b87249ECCa95920E5; test wallet: 0xF06cbA90B09bA220E59276323910157e8c560134

### 0. Preflight
- **PASS** deployer, keeper and buyer are three distinct addresses
- **PASS** CIRC_PROTOCOL and CIRC_SINK differ (needed for the split check)
  - new Nand costs 0.00296 OKB; Container open fee 0.08 OKB; gas price 0.0200 gwei
  - estimate: TEST deploy 0.000172 OKB gas; e2e run 0.00009 OKB gas + ~0.19 OKB value (fill ~0.1, Nand 0.00296, Container open 0.08, withdraw fee 0.0013); prod deploy 0.000172 OKB gas
- **PASS** deployer 0xc41EFaC70571bF7D7Ef7d402C66E36108202b35D holds >= 0.003 OKB
- **PASS** keeper 0x2b41B054C8Ae9fE81Fc64928377e315c2DE6856A holds >= 0.001 OKB
- **PASS** buyer 0xF06cbA90B09bA220E59276323910157e8c560134 holds >= 0.19296 OKB
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | deployer | OKB | 0.019604223 | 0.019604223 | +0 |
  | keeper | OKB | 0.050001 | 0.050001 | +0 |
  | buyer | OKB | 0.200001 | 0.200001 | +0 |

### 1. Deploy CIRC-TEST (script/Deploy.s.sol:DeployTest)
  - tx `0x47d03888a5f10ab9d66d373525adf86489f6de390fbaad72da16ccbed4a089e9` (deploy, gas 1,273,131)
    https://www.oklink.com/x-layer/tx/0x47d03888a5f10ab9d66d373525adf86489f6de390fbaad72da16ccbed4a089e9
  - tx `0xcab7ee326817ff59b7e4f71b4cc9870e093a9a873e908e3f9e04f69577e9acf9` (deploy, gas 5,263,630)
    https://www.oklink.com/x-layer/tx/0xcab7ee326817ff59b7e4f71b4cc9870e093a9a873e908e3f9e04f69577e9acf9
    pad: contract CurvePad 0x8f2bbd9dA778071a8B6E9C2D3fEC3f3a6850E6BA
    locker: contract PositionLocker 0xD2A47144f211d8a83bfc61B433D3341057EF7864
    TEST_WOKB_VQUOTE0 31395561920888904
    TEST_WOKB_RAISE_WEI 98999999999999997
    TEST_BEM_VQUOTE0 31712688
    LABEL CIRC-TEST
    PositionLocker 0xD2A47144f211d8a83bfc61B433D3341057EF7864
    CurvePad       0x8f2bbd9dA778071a8B6E9C2D3fEC3f3a6850E6BA
    CircHook       0x1BA31Db1c87Ac33EC12351953932829Da8456800
    Graduator      0x16E4607eCeFEaaf2D458648AD22d20d319b30AfC
    TokenDeployer  0xA5aFFEE6cfb383bD074e2db18B82382903cb1F36
    protocol       0x79ac0889b0aCa2C5233EeECE7468195ad7A58997
    sink           0x4E2020B7Ef36a22550EDf603C556EFA8c17b65F3
- **PASS** CircHook 0x1BA31Db1c87Ac33EC12351953932829Da8456800 has exactly beforeInitialize|beforeAddLiquidity flags
- **PASS** PositionLocker 0xD2A47144f211d8a83bfc61B433D3341057EF7864 is bound to CurvePad 0x8f2bbd9dA778071a8B6E9C2D3fEC3f3a6850E6BA
- **PASS** protocol and sink are your addresses
- **PASS** TEST WOKB vQuote0 31395561920888904 -> raise 0.099 WOKB (tiny TEST curve)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | deployer | OKB | 0.019604223 | 0.019473487 | -0.000130735 |

### 2a. Mint a new Nand (buy 1 NAND transistor, tape out)
  - tx `0xb5d0623da4ec3a15960ae754bc3f142de2f0fe7d960432d7bc22ea31ce2d9472` (buy NAND transistor, from buyer, value 0.00166 OKB, gas 86,399)
    https://www.oklink.com/x-layer/tx/0xb5d0623da4ec3a15960ae754bc3f142de2f0fe7d960432d7bc22ea31ce2d9472
  - tx `0x5a76f58c6f9447d0eee2a95d1354a7e295c89c7b8940df6bdd0207c4dd3c1b06` (tape out, from buyer, value 0.0013 OKB, gas 221,915)
    https://www.oklink.com/x-layer/tx/0x5a76f58c6f9447d0eee2a95d1354a7e295c89c7b8940df6bdd0207c4dd3c1b06
- **PASS** nextId() was the last id (11); the new Nand is #12
- **PASS** the buyer holds it
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.200001 | 0.197034834 | -0.002966166 |

### 2b. Launch limits (simulated, nothing sent)
- **PASS** empty name reverts BadName
- **PASS** 65-byte name reverts BadName
- **PASS** 17-byte symbol reverts BadSymbol
- **PASS** tradeFeeBps 100, feeSplitBps [5000, 3000, 2000]

### 2c. Launch CIRC-TEST from Nand #12
- **PASS** isLaunched is false before
  - tx `0xedbe6e150746caea2ca297eca2c62f61dc873a5b58ff426b6437670e35ee4ef8` (createLaunch, from buyer, value 0 OKB, gas 786,028)
    https://www.oklink.com/x-layer/tx/0xedbe6e150746caea2ca297eca2c62f61dc873a5b58ff426b6437670e35ee4ef8
- **PASS** isLaunched is true after
- **PASS** a second launch from this Nand reverts AlreadyLaunched
- **PASS** imageURI is emitted in LaunchCreated
  - token **0x1868b87ec03130ea1389e0c81395c957e353f0d3**, Container 0x1e813b07D5d532Df62fAC52829b4c6AE148ac56A, launch block 74783287
- **PASS** curve is Trading, quoted in WOKB
- **PASS** pad holds the full 1,000,000,000 supply
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.197034834 | 0.197019113 | -0.000015721 |
  | buyer | WOKB | 0 | 0 | +0 |

### 3. Anti-snipe: buy inside the 30-block guard is capped at 0.5% of supply
  - tx `0xe04f2becf53636a320bfbc7f329904cef6cc7c0b9d9ccb6254c98c7d087bb743` (buyWithOKB inside guard, from buyer, value 0.001 OKB, gas 252,266)
    https://www.oklink.com/x-layer/tx/0xe04f2becf53636a320bfbc7f329904cef6cc7c0b9d9ccb6254c98c7d087bb743
- **PASS** buy landed in block 74783300, inside the guard (ends 74783317)
- **PASS** tokens received 5,000,000.0000 == cap 5,000,000.0000 (0.5% of supply)
- **PASS** curve-wide per-block counter recorded the capped amount
- **PASS** excess refunded: net OKB out 0.000155124 < sent 0.001 (incl. gas)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.197019113 | 0.19686399 | -0.000155124 |
  | buyer | WOKB | 0 | 0 | +0 |
  | buyer | CIRCTEST | 0.0000 | 5,000,000.0000 | +5,000,000.0000 |

### 4a. Buy 0.01 OKB after the guard
  - tx `0x22b1bc221a833a94ecd4781d252f2f395baaf848a7e16af454e0b609b119c8e7` (buyWithOKB 0.01, from buyer, value 0.01 OKB, gas 107,272)
    https://www.oklink.com/x-layer/tx/0x22b1bc221a833a94ecd4781d252f2f395baaf848a7e16af454e0b609b119c8e7
- **PASS** received 252,381,420.4717 CIRCTEST == previewBuy
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.19686399 | 0.186861844 | -0.010002145 |
  | buyer | WOKB | 0 | 0 | +0 |
  | buyer | CIRCTEST | 5,000,000.0000 | 257,381,420.4717 | +252,381,420.4717 |

### 4b. Sell half the buyer's tokens back to the curve
  - tx `0xddbe0eb1665fa8aa3b76106623a5b2b4f0915489e296579202237770fb37335b` (approve pad, from buyer, value 0 OKB, gas 46,031)
    https://www.oklink.com/x-layer/tx/0xddbe0eb1665fa8aa3b76106623a5b2b4f0915489e296579202237770fb37335b
  - tx `0x65b5dda4c5d755ec92a9dd70b262d4c64e2e186c980f61e14dc49ea752d8f09a` (sell, from buyer, value 0 OKB, gas 117,587)
    https://www.oklink.com/x-layer/tx/0x65b5dda4c5d755ec92a9dd70b262d4c64e2e186c980f61e14dc49ea752d8f09a
- **PASS** received 0.005660239 WOKB == previewSell
- **PASS** sent 128,690,710.2359 CIRCTEST
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.186861844 | 0.186858572 | -0.000003272 |
  | buyer | WOKB | 0 | 0.005660239 | +0.005660239 |
  | buyer | CIRCTEST | 257,381,420.4717 | 128,690,710.2359 | -128,690,710.2359 |

### 5. Fill the curve -> Complete
  - quote needed to complete: 0.095625086 WOKB
  - tx `0x0773454e3fc6e6bda81d4195a2e3cad10bf3652740ec8ae24a05e8bfd82309f9` (buyWithOKB fill, from buyer, value 0.095626086 OKB, gas 130,993)
    https://www.oklink.com/x-layer/tx/0x0773454e3fc6e6bda81d4195a2e3cad10bf3652740ec8ae24a05e8bfd82309f9
- **PASS** curve status Complete, CurveCompleted emitted
- **PASS** curve supply sold out
- **PASS** further curve buys revert CurveClosed
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.186858572 | 0.091230866 | -0.095627706 |
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
  - tx `0xb7184d4dea2edf16ac84d5fd73f1f54e4a777f62e238d0942e1747aabd2df937` (graduate, from keeper, value 0 OKB, gas 751,257)
    https://www.oklink.com/x-layer/tx/0xb7184d4dea2edf16ac84d5fd73f1f54e4a777f62e238d0942e1747aabd2df937
  - poolId 0x2fef683d5d7372fcd5994580a4c05b2033a5c2545cefdcd8f8a0b55280d8cc59, position #20190, quote in LP 0.099 WOKB, tokens in LP 194,049,965.0129
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
  | keeper | OKB | 0.050001 | 0.049985975 | -0.000015025 |
  | keeper | WOKB | 0 | 0 | +0 |
  | keeper | CIRCTEST | 0.0000 | 0.0000 | +0.0000 |

### 7a. Universal Router 2.1.2: buy with WOKB
  - tx `0xd0b634ab37fa1fba12ad1991e4c5e5f51909f6fb1a1c494b991ecda90947d68c` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 30,514)
    https://www.oklink.com/x-layer/tx/0xd0b634ab37fa1fba12ad1991e4c5e5f51909f6fb1a1c494b991ecda90947d68c
  - tx `0x94004f963790da18526bc461346d7d7e97c1d889b68c92ec31a2d8d1cc5e538c` (Universal Router V4_SWAP exact-in 0.002, from buyer, value 0 OKB, gas 138,677)
    https://www.oklink.com/x-layer/tx/0x94004f963790da18526bc461346d7d7e97c1d889b68c92ec31a2d8d1cc5e538c
- **PASS** paid 0.002 WOKB, got 3,804,901.2748 CIRCTEST (quoted 3,804,901.2748)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.091230866 | 0.091227482 | -0.000003384 |
  | buyer | WOKB | 0.005660239 | 0.003660239 | -0.002 |
  | buyer | CIRCTEST | 805,950,034.9871 | 809,754,936.2619 | +3,804,901.2748 |

### 7b. Universal Router 2.1.2: sell 10% of the buyer's tokens
  - tx `0x288dcb5e712092e1e8a645ea6d5ea34bc38fb99ddf0ae8f15496b3b57dd0dcb9` (approve Permit2, from buyer, value 0 OKB, gas 46,223)
    https://www.oklink.com/x-layer/tx/0x288dcb5e712092e1e8a645ea6d5ea34bc38fb99ddf0ae8f15496b3b57dd0dcb9
  - tx `0xb7cbc24fb1b6eea4a6844f37d69e72f42768f0d324379fbc745693385e17be27` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 47,686)
    https://www.oklink.com/x-layer/tx/0xb7cbc24fb1b6eea4a6844f37d69e72f42768f0d324379fbc745693385e17be27
  - tx `0xd06ac5886abc6fc401e7e9b929b5ea8116be71715e28775d1da82d01e17ebe80` (Universal Router V4_SWAP exact-in 80,975,493.6262, from buyer, value 0 OKB, gas 139,068)
    https://www.oklink.com/x-layer/tx/0xd06ac5886abc6fc401e7e9b929b5ea8116be71715e28775d1da82d01e17ebe80
- **PASS** sold 80,975,493.6262 CIRCTEST for 0.029936438 WOKB (quoted 0.029936438)
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.091227482 | 0.091222822 | -0.00000466 |
  | buyer | WOKB | 0.003660239 | 0.033596677 | +0.029936438 |
  | buyer | CIRCTEST | 809,754,936.2619 | 728,779,442.6357 | -80,975,493.6262 |

### 8. Locker collect (permissionless) + LP fee split 50/30/20
  - tx `0x209b67df9e57c0cbb083cada44ecbed9573bbf62283f22157498b9c6766fbcc4` (collect, from keeper, value 0 OKB, gas 387,553)
    https://www.oklink.com/x-layer/tx/0x209b67df9e57c0cbb083cada44ecbed9573bbf62283f22157498b9c6766fbcc4
  - collected 809754936261898194576158 (currency0 0x1868b87ec03130ea1389e0c81395c957e353f0d3) and 19999999999999 (currency1 0xe538905cf8410324e03A5A23C1c177a474D59b2b) wei
- **PASS** fees collected in both currencies (one UR buy, one UR sell)
- **PASS** CIRCTEST: Container 404877468130949097288079 / protocol 242926480878569458372848 / sink 161950987252379638915231 = 50/30/20
- **PASS** WOKB: Container 9999999999999 / protocol 6000000000001 / sink 3999999999999 = 50/30/20
- **PASS** locked liquidity unchanged by collect
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | keeper | OKB | 0.049985975 | 0.049978224 | -0.000007751 |

### 9. Protocol and sink claims (permissionless push to your addresses)
  - tx `0x520a7e8a961086f15ee5fb289954b10e40018b1c6094355fcbf4df1e14ea215d` (CurvePad.claim WOKB -> protocol, from keeper, value 0 OKB, gas 67,241)
    https://www.oklink.com/x-layer/tx/0x520a7e8a961086f15ee5fb289954b10e40018b1c6094355fcbf4df1e14ea215d
- **PASS** protocol received 0.000334478 WOKB from CurvePad
  - tx `0x080fc8970a998af5bcac8c154ab559403c6431d89c69ad2529eac3f2825dc5c5` (CurvePad.claim WOKB -> sink, from keeper, value 0 OKB, gas 67,241)
    https://www.oklink.com/x-layer/tx/0x080fc8970a998af5bcac8c154ab559403c6431d89c69ad2529eac3f2825dc5c5
- **PASS** sink received 0.000222985 WOKB from CurvePad
  - tx `0x9fe76bb285d377d85b2e60ac5c2b12675c4b45475ce4ab709ac3b6e8bc4069bd` (PositionLocker.claim WOKB -> protocol, from keeper, value 0 OKB, gas 50,038)
    https://www.oklink.com/x-layer/tx/0x9fe76bb285d377d85b2e60ac5c2b12675c4b45475ce4ab709ac3b6e8bc4069bd
- **PASS** protocol received 0.000006 WOKB from PositionLocker
  - tx `0xcd9c43e74c447d1fc39ab1425c65a5dc4fd744d81eff0bbc8a22fd6dd6f8e040` (PositionLocker.claim WOKB -> sink, from keeper, value 0 OKB, gas 50,038)
    https://www.oklink.com/x-layer/tx/0xcd9c43e74c447d1fc39ab1425c65a5dc4fd744d81eff0bbc8a22fd6dd6f8e040
- **PASS** sink received 0.000004 WOKB from PositionLocker
- **PASS** claim() cannot push creator fees (CreatorClaimOnly)
- **PASS** non-holder claimCreator reverts NotHolder

### 10. Container open + creator claim to Container + holder withdraw
  - tx `0x59b7a4b9878099315ccd489e2c2d68db5ae3be674b9de859350020bddf123285` (TapeOut opener.open (fee 0.08 OKB), from buyer, value 0.08 OKB, gas 167,234)
    https://www.oklink.com/x-layer/tx/0x59b7a4b9878099315ccd489e2c2d68db5ae3be674b9de859350020bddf123285
- **PASS** Container 0x1e813b07D5d532Df62fAC52829b4c6AE148ac56A deployed
  - tx `0x6c7d3700c114237cd3fa07113744eec86e5b3e578231703d5fd3777fbdc02ccb` (claimCreator -> Container, from buyer, value 0 OKB, gas 75,741)
    https://www.oklink.com/x-layer/tx/0x6c7d3700c114237cd3fa07113744eec86e5b3e578231703d5fd3777fbdc02ccb
- **PASS** Container received 0.000557463 WOKB creator fees
  - Container execute fee: 0.0013 OKB
  - tx `0x69ad7b00fc86af5af23ca8a19db480ce36c455b485251411d5358cad68108ac6` (Container.execute withdraw, from buyer, value 0.0013 OKB, gas 111,935)
    https://www.oklink.com/x-layer/tx/0x69ad7b00fc86af5af23ca8a19db480ce36c455b485251411d5358cad68108ac6
- **PASS** holder withdrew 0.000557463 WOKB from the Container
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.091222822 | 0.009915724 | -0.081307098 |
  | buyer | WOKB | 0.033596677 | 0.03415414 | +0.000557463 |
  | buyer | CIRCTEST | 728,779,442.6357 | 728,779,442.6357 | +0.0000 |

### 11. Fallback: holder claims LP creator fees straight to the holder wallet
  - tx `0xbdb9de1695267a5e95d3a8803ce2524bee0c4ec0a58fc1939ccd0e50f7da19d4` (locker.claimCreator WOKB -> holder, from buyer, value 0 OKB, gas 60,591)
    https://www.oklink.com/x-layer/tx/0xbdb9de1695267a5e95d3a8803ce2524bee0c4ec0a58fc1939ccd0e50f7da19d4
- **PASS** holder wallet received 0.00001 WOKB
  - tx `0xc323b1ff4dad5fc5da75829cb370fb22442c5d7b89aadf9143f8b4d6da9f4210` (locker.claimCreator CIRCTEST -> holder, from buyer, value 0 OKB, gas 67,777)
    https://www.oklink.com/x-layer/tx/0xc323b1ff4dad5fc5da75829cb370fb22442c5d7b89aadf9143f8b4d6da9f4210
- **PASS** holder wallet received 404,877.4681 CIRCTEST
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.009915724 | 0.009913157 | -0.000002567 |
  | buyer | WOKB | 0.03415414 | 0.03416414 | +0.00001 |
  | buyer | CIRCTEST | 728,779,442.6357 | 729,184,320.1038 | +404,877.4681 |

### 12. Cleanup: sell all CIRCTEST back into the pool, unwrap, sweep the buyer to MAIN_WALLET
  - tx `0xe892ce169feb0c2d55daf6ad3c07b581d9977ae5816532045b545ed1c20dd9e6` (Permit2 approve Universal Router, from buyer, value 0 OKB, gas 30,598)
    https://www.oklink.com/x-layer/tx/0xe892ce169feb0c2d55daf6ad3c07b581d9977ae5816532045b545ed1c20dd9e6
  - tx `0xce297b39f90aa86a853d2a732f4b8643e1aa20af6d12078c7f693b6bd56ff03d` (Universal Router V4_SWAP exact-in 729,184,320.1038, from buyer, value 0 OKB, gas 117,160)
    https://www.oklink.com/x-layer/tx/0xce297b39f90aa86a853d2a732f4b8643e1aa20af6d12078c7f693b6bd56ff03d
- **PASS** buyer holds no CIRCTEST
  - tx `0x2a363e4379a44fcca7c1229d3fc325fe39c770d6f51bfaaed5a183bef7e2dfcc` (unwrap WOKB, from buyer, value 0 OKB, gas 34,477)
    https://www.oklink.com/x-layer/tx/0x2a363e4379a44fcca7c1229d3fc325fe39c770d6f51bfaaed5a183bef7e2dfcc
  - tx `0x2c268d1893a4a2bfde36c052a50f08758ffe8da589dfb2c441b81d204373962c` (sweep 0.095755839 OKB -> MAIN_WALLET, from buyer, value 0.095755839 OKB, gas 21,000)
    https://www.oklink.com/x-layer/tx/0x2c268d1893a4a2bfde36c052a50f08758ffe8da589dfb2c441b81d204373962c
  - buyer left with 0.000001 OKB
  | wallet | asset | before | after | delta |
  |---|---|---|---|---|
  | buyer | OKB | 0.009913157 | 0.000001 | -0.009912157 |
  | buyer | WOKB | 0.03416414 | 0 | -0.03416414 |
  | buyer | CIRCTEST | 729,184,320.1038 | 0.0000 | -729,184,320.1038 |

### 13. Locked LP (stays forever by design)
- locked position #20190: ~0.019359955 OKB (as WOKB) + ~992,303,279.3308 CIRCTEST

## Summary

- CurvePad (CIRC-TEST): `0x8f2bbd9dA778071a8B6E9C2D3fEC3f3a6850E6BA`; PositionLocker `0xD2A47144f211d8a83bfc61B433D3341057EF7864`; CircHook `0x1BA31Db1c87Ac33EC12351953932829Da8456800`; Graduator `0x16E4607eCeFEaaf2D458648AD22d20d319b30AfC`
- token `0x1868b87ec03130ea1389e0c81395c957e353f0d3`; pool `0x2fef683d5d7372fcd5994580a4c05b2033a5c2545cefdcd8f8a0b55280d8cc59`; locked position #20190
- msg.value spent (cap 0.5 OKB): 0.190886086 OKB
- gas paid, deploy: 0.000130735 OKB
- gas paid, e2e: 0.000080146 OKB
- gas paid, cleanup: 0.000004065 OKB
- gas paid, total: 0.000214946 OKB
- prod deploy estimate: ~0.000130735 OKB gas (same contracts)
- checks: 62 PASS, 0 FAIL, 0 SKIPPED

E2E RESULT: PASS
