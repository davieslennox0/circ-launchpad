// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice X Layer mainnet (chain 196) addresses. Every entry was checked for code on 2026-10-29 (RECON.md).
library Addresses {
    // Uniswap v4, source: https://developers.uniswap.org/docs/protocols/v4/deployments (checked on-chain 2026-10-30:
    // PositionManager.poolManager() == POOL_MANAGER, .permit2() == PERMIT2, .WETH9() == WOKB; StateView -> POOL_MANAGER)
    address internal constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant POSITION_MANAGER = 0xcF1EAFC6928dC385A342E7C6491d371d2871458b;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant STATE_VIEW = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address internal constant V4_QUOTER = 0x8928074CA1b241D8Ec02815881c1Af11E8bC5219;
    address internal constant UNIVERSAL_ROUTER = 0x1cd182C94fcF42277B80DBB9060F88024809E61E; // 2.1.2

    // Quote assets
    address internal constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b; // PositionManager.WETH9()
    /// BEM: LayerZero OFT bridged from BSC, 8 decimals. Owned (upgradeable peers/config) by the TapeOut 3-of-5 Safe below.
    address internal constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;

    // TapeOut (sources: tapeout.net bundle L2_FACTORY, on-chain reads; RECON.md section 3)
    address internal constant CIRCUIT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address internal constant CONTAINER_IMPL = 0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57;
    address internal constant CONTAINER_OPENER = 0x536adD8F30f03b69f6fbF29d425A816A0dC50106;
    address internal constant TAPEOUT_SAFE = 0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138;

    // Fork fixtures: Nandout processor and the holder of its circuits #1-#5
    address internal constant NANDOUT = 0x8A60B4A4BCf4066F5E5F9A406fE09c5e4f52a58E;
    address internal constant NANDOUT_HOLDER = 0x934d315C0a9C0866D393B722C1805F2B6b20b816;
    address internal constant BEM_WOKB_POOL = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;

    // Live-price sources for deploy-time curve constants (canonical Uniswap v3 pools, checked 2026-10-30):
    // USD₮0/WOKB 0.05%, the deepest WOKB/USD pool on X Layer (~1,677 WOKB + ~$176k USD₮0), and BEM/WOKB 1% above.
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant WOKB_USDT0_POOL = 0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082;
}
