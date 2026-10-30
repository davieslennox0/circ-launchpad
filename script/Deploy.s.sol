// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {CurvePad} from "../src/CurvePad.sol";
import {PositionLocker} from "../src/PositionLocker.sol";
import {IPositionManager} from "../src/interfaces/IUniswapV4.sol";
import {Addresses} from "./Addresses.sol";
import {CurveConstants} from "./CurveConstants.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Shared X Layer wiring for the deploy script and fork tests.
library CircDeploy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Deploys PositionLocker then CurvePad from `deployer`, whose next two nonces must be these two creates.
    function deploy(address deployer, address protocol, address sink)
        internal
        returns (CurvePad pad, PositionLocker locker)
    {
        address predictedPad = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        (bytes32 hookSalt,) = HookMiner.mine(predictedPad, Addresses.POOL_MANAGER, Addresses.POSITION_MANAGER);
        locker = new PositionLocker(IPositionManager(Addresses.POSITION_MANAGER), predictedPad, protocol, sink);
        pad = new CurvePad(params(address(locker), protocol, sink, hookSalt));
        require(address(pad) == predictedPad, "pad address mismatch");
    }

    function params(address locker, address protocol, address sink, bytes32 hookSalt)
        internal
        pure
        returns (CurvePad.Params memory)
    {
        return CurvePad.Params({
            wokb: Addresses.WOKB,
            bem: Addresses.BEM,
            wokbConfig: CurveConstants.wokb(),
            bemConfig: CurveConstants.bem(),
            circuitFactory: Addresses.CIRCUIT_FACTORY,
            registry: Addresses.ERC6551_REGISTRY,
            containerImpl: Addresses.CONTAINER_IMPL,
            poolManager: Addresses.POOL_MANAGER,
            positionManager: Addresses.POSITION_MANAGER,
            permit2: Addresses.PERMIT2,
            locker: locker,
            protocol: protocol,
            sink: sink,
            hookSalt: hookSalt
        });
    }
}

/// @notice Deploys PositionLocker, then CurvePad, wired to each other.
/// Env: PRIVATE_KEY (deployer), CIRC_PROTOCOL (protocol treasury), CIRC_SINK (ecosystem sink).
/// Dry run: forge script script/Deploy.s.sol --fork-url $XLAYER_RPC_URL
/// Never add --broadcast against mainnet without the owner's explicit go-ahead.
contract Deploy is Script {
    /// @dev Foundry's default script sender.
    address internal constant FOUNDRY_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    error DefaultKeyOnMainnet(address broadcaster);

    function run() external returns (CurvePad pad, PositionLocker locker) {
        require(block.chainid == 196 || block.chainid == 31337, "X Layer mainnet or local fork only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (broadcasting && block.chainid == 196) _requireNotDefaultKey(deployer);
        address protocol = vm.envAddress("CIRC_PROTOCOL");
        address sink = vm.envAddress("CIRC_SINK");

        vm.startBroadcast(pk);
        (pad, locker) = CircDeploy.deploy(deployer, protocol, sink);
        vm.stopBroadcast();

        console2.log("PositionLocker", address(locker));
        console2.log("CurvePad      ", address(pad));
        console2.log("CircHook      ", address(pad.hook()));
        console2.log("Graduator     ", address(pad.graduator()));
        console2.log("protocol      ", protocol);
        console2.log("sink          ", sink);
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
