// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurvePad} from "../src/CurvePad.sol";
import {PositionLocker} from "../src/PositionLocker.sol";
import {IPositionManager} from "../src/interfaces/IUniswapV4.sol";
import {Addresses} from "./Addresses.sol";
import {CurveConstants} from "./CurveConstants.sol";
import {HookMiner} from "./HookMiner.sol";
import {LivePrices} from "./LivePrices.sol";

/// @notice Shared X Layer wiring for the deploy script and fork tests.
library CircDeploy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Fixed constants from CurveConstants (tests). See deployWith.
    function deploy(address deployer, address protocol, address sink)
        internal
        returns (CurvePad pad, PositionLocker locker)
    {
        return deployWith(deployer, protocol, sink, CurveConstants.wokb(), CurveConstants.bem(), Addresses.BEM);
    }

    /// @dev Deploys PositionLocker then CurvePad from `deployer`, whose next two nonces must be these two creates.
    /// `bemToken` is the BEM-slot quote asset (Addresses.BEM in production; tests may substitute a mock).
    function deployWith(
        address deployer,
        address protocol,
        address sink,
        CurvePad.QuoteConfig memory wokbConfig,
        CurvePad.QuoteConfig memory bemConfig,
        address bemToken
    ) internal returns (CurvePad pad, PositionLocker locker) {
        address predictedPad = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        (bytes32 hookSalt,) = HookMiner.mine(predictedPad, Addresses.POOL_MANAGER, Addresses.POSITION_MANAGER);
        locker = new PositionLocker(IPositionManager(Addresses.POSITION_MANAGER), predictedPad, protocol, sink);
        pad = new CurvePad(
            CurvePad.Params({
                wokb: Addresses.WOKB,
                bem: bemToken,
                wokbConfig: wokbConfig,
                bemConfig: bemConfig,
                circuitFactory: Addresses.CIRCUIT_FACTORY,
                registry: Addresses.ERC6551_REGISTRY,
                containerImpl: Addresses.CONTAINER_IMPL,
                poolManager: Addresses.POOL_MANAGER,
                positionManager: Addresses.POSITION_MANAGER,
                permit2: Addresses.PERMIT2,
                locker: address(locker),
                protocol: protocol,
                sink: sink,
                hookSalt: hookSalt
            })
        );
        require(address(pad) == predictedPad, "pad address mismatch");
    }
}

/// @notice Checks and logging shared by the production and TEST deploy scripts.
abstract contract DeployGuards is Script {
    /// @dev Foundry's default script sender.
    address internal constant FOUNDRY_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    error DefaultKeyOnMainnet(address broadcaster);

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    function _logDeployment(CurvePad pad, PositionLocker locker) internal view {
        console2.log("PositionLocker", address(locker));
        console2.log("CurvePad      ", address(pad));
        console2.log("CircHook      ", address(pad.hook()));
        console2.log("Graduator     ", address(pad.graduator()));
        console2.log("TokenDeployer ", address(pad.tokenDeployer()));
        console2.log("protocol      ", pad.protocol());
        console2.log("sink          ", pad.sink());
    }

    /// @dev Refuse a mainnet broadcast from any publicly known key: the Foundry default sender or the first 20 accounts of
    /// anvil's default mnemonic.
    function _requireNotDefaultKey(address broadcaster) internal pure {
        if (broadcaster == FOUNDRY_DEFAULT_SENDER) revert DefaultKeyOnMainnet(broadcaster);
        for (uint32 i; i < 20; ++i) {
            if (broadcaster == vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i))) revert DefaultKeyOnMainnet(broadcaster);
        }
    }
}

/// @notice Deploys PositionLocker, then CurvePad (which creates TokenDeployer, CircHook and Graduator).
///
/// Curve constants are regenerated from live on-chain prices at run time (script/LivePrices.sol) and printed:
///   1. Dry run (no --broadcast): prints LIVE_WOKB_VQUOTE0 / LIVE_BEM_VQUOTE0 and what they mean in USD.
///   2. The owner approves those numbers.
///   3. Broadcast run: set APPROVED_WOKB_VQUOTE0 / APPROVED_BEM_VQUOTE0 to the approved values. The script deploys with
///      exactly those, and refuses if live prices have since moved them by more than MAX_DRIFT_BPS.
/// Env: PRIVATE_KEY, CIRC_PROTOCOL, CIRC_SINK (+ APPROVED_* when broadcasting).
/// Never add --broadcast against mainnet without the owner's explicit go-ahead.
contract Deploy is DeployGuards {
    uint256 internal constant MAX_DRIFT_BPS = 200; // 2%

    error ApprovalRequired();
    error PricesMovedSinceApproval(string quote, uint256 approved, uint256 live);

    function run() external returns (CurvePad pad, PositionLocker locker) {
        require(block.chainid == 196 || block.chainid == 31337, "X Layer mainnet or local fork only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool broadcasting = _broadcasting();
        if (broadcasting && block.chainid == 196) _requireNotDefaultKey(deployer);
        address protocol = vm.envAddress("CIRC_PROTOCOL");
        address sink = vm.envAddress("CIRC_SINK");

        (uint128 wokbVQ0, uint128 bemVQ0) = _constants(broadcasting);

        vm.startBroadcast(pk);
        (pad, locker) = CircDeploy.deployWith(
            deployer, protocol, sink, LivePrices.config(wokbVQ0), LivePrices.config(bemVQ0), Addresses.BEM
        );
        vm.stopBroadcast();
        _logDeployment(pad, locker);
    }

    /// @dev Live constants on a dry run; owner-approved constants (checked against live) on a broadcast.
    function _constants(bool broadcasting) internal view returns (uint128 wokbVQ0, uint128 bemVQ0) {
        (uint256 okbUsd, uint256 bemUsd) = LivePrices.read();
        uint128 liveW = LivePrices.vQuote0(okbUsd, 18);
        uint128 liveB = LivePrices.vQuote0(bemUsd, 8);

        console2.log("=== Curve constants from live prices (block %s) ===", block.number);
        console2.log("OKB_USD_E18", okbUsd);
        console2.log("BEM_USD_E18", bemUsd);
        console2.log("LIVE_WOKB_VQUOTE0", uint256(liveW));
        console2.log("LIVE_BEM_VQUOTE0", uint256(liveB));
        console2.log("WOKB raise R (wei)", LivePrices.raise(liveW));
        console2.log("BEM raise R (8dp)", LivePrices.raise(liveB));
        console2.log("raise in USD (both)", LivePrices.raise(liveW) * okbUsd / 1e36);
        console2.log("vToken0 / curveSupply / lpTokens (fixed):");
        console2.log(uint256(CurveConstants.V_TOKEN0), uint256(CurveConstants.CURVE_SUPPLY), uint256(CurveConstants.LP_TOKENS));

        if (!broadcasting) return (liveW, liveB);

        uint256 approvedW = vm.envOr("APPROVED_WOKB_VQUOTE0", uint256(0));
        uint256 approvedB = vm.envOr("APPROVED_BEM_VQUOTE0", uint256(0));
        if (approvedW == 0 || approvedB == 0) revert ApprovalRequired();
        _checkDrift("WOKB", approvedW, liveW);
        _checkDrift("BEM", approvedB, liveB);
        console2.log("Using APPROVED constants:", approvedW, approvedB);
        return (uint128(approvedW), uint128(approvedB));
    }

    function _checkDrift(string memory quote, uint256 approved, uint256 live) internal pure {
        uint256 diff = approved > live ? approved - live : live - approved;
        if (diff * 10_000 > live * MAX_DRIFT_BPS) revert PricesMovedSinceApproval(quote, approved, live);
    }

}

/// @notice CIRC-TEST instance: the same contracts and constructor checks as production, with a tiny WOKB curve so a
/// launch completes after ~0.1 OKB of buys (TEST_RAISE_WEI, default 0.099 WOKB raise + 1% fee). For the end-to-end
/// test only (script/e2e); never point a frontend at it. The BEM slot gets a 1-BEM raise and is not exercised.
/// Env: PRIVATE_KEY, CIRC_PROTOCOL, CIRC_SINK, optional TEST_RAISE_WEI (capped at MAX_TEST_RAISE).
contract DeployTest is DeployGuards {
    string public constant LABEL = "CIRC-TEST";
    uint256 internal constant DEFAULT_TEST_RAISE = 0.099 ether;
    uint256 internal constant MAX_TEST_RAISE = 0.2 ether;
    uint256 internal constant TEST_BEM_RAISE = 1e8; // 1 BEM (8 dp)

    error TestRaiseTooLarge(uint256 raise);

    function run() external returns (CurvePad pad, PositionLocker locker) {
        require(block.chainid == 196 || block.chainid == 31337, "X Layer mainnet or local fork only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        if (_broadcasting() && block.chainid == 196) _requireNotDefaultKey(deployer);
        uint256 raise = vm.envOr("TEST_RAISE_WEI", DEFAULT_TEST_RAISE);
        if (raise == 0 || raise > MAX_TEST_RAISE) revert TestRaiseTooLarge(raise);

        (uint128 wokbVQ0, uint128 bemVQ0) = testVQuote0(raise);
        console2.log("=== %s deploy (TEST profile) ===", LABEL);
        console2.log("TEST_WOKB_VQUOTE0", uint256(wokbVQ0));
        console2.log("TEST_WOKB_RAISE_WEI", LivePrices.raise(wokbVQ0));
        console2.log("TEST_BEM_VQUOTE0", uint256(bemVQ0));

        vm.startBroadcast(pk);
        (pad, locker) = CircDeploy.deployWith(
            deployer,
            vm.envAddress("CIRC_PROTOCOL"),
            vm.envAddress("CIRC_SINK"),
            LivePrices.config(wokbVQ0),
            LivePrices.config(bemVQ0),
            Addresses.BEM
        );
        vm.stopBroadcast();
        console2.log("LABEL", LABEL);
        _logDeployment(pad, locker);
    }

    /// @dev vQuote0 whose raise R = vQ0 * curveSupply / tEnd equals `raise` (rounded down).
    function testVQuote0(uint256 raise) public pure returns (uint128 wokbVQ0, uint128 bemVQ0) {
        uint256 tEnd = uint256(CurveConstants.V_TOKEN0) - CurveConstants.CURVE_SUPPLY;
        wokbVQ0 = uint128(Math.mulDiv(raise, tEnd, CurveConstants.CURVE_SUPPLY));
        bemVQ0 = uint128(Math.mulDiv(TEST_BEM_RAISE, tEnd, CurveConstants.CURVE_SUPPLY));
    }
}
