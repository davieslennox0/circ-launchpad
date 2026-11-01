// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurvePad} from "../src/CurvePad.sol";
import {PositionLocker} from "../src/PositionLocker.sol";
import {PoolKey, IPositionManager, IAllowanceTransfer} from "../src/interfaces/IUniswapV4.sol";
import {ICircuitNFT} from "../src/interfaces/ITapeOut.sol";
import {Addresses} from "./Addresses.sol";

interface IStateView2 {
    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24);
    function getLiquidity(bytes32 poolId) external view returns (uint128);
}

interface IUniversalRouter2 {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev v4-periphery IV4Router.ExactInputSingleParams (commit pinned by Universal Router 2.1.x).
struct ExactInSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/// @notice GATE 2 sample run on an anvil fork (never mainnet): launch -> fill -> graduate -> trade -> collect.
/// Env: CIRC_PAD (deployed CurvePad), BUYER_KEY (funded fork key). The launch is sent as the Nandout holder, which anvil
/// impersonates (--auto-impersonate + --unlocked). Between `launch()` and `finish()`, mine GUARD_BLOCKS blocks.
contract Gate2Sample is Script {
    function launch() external returns (address token) {
        require(block.chainid == 196 || block.chainid == 31337, "fork only");
        CurvePad pad = CurvePad(payable(vm.envAddress("CIRC_PAD")));
        address holder = Addresses.NANDOUT_HOLDER;
        uint256 id = vm.envOr("CIRCUIT_ID", uint256(1));
        require(ICircuitNFT(Addresses.NANDOUT).ownerOf(id) == holder, "holder no longer owns the circuit");
        vm.startBroadcast(holder);
        token = pad.createLaunch(Addresses.NANDOUT, id, "Circ Gate Two", "CGT", "", Addresses.WOKB, 0, 0);
        vm.stopBroadcast();
        console2.log("TOKEN", token);
        (,,,,, address container,,,,) = pad.curves(token);
        console2.log("container", container);
    }

    function finish() external {
        require(block.chainid == 196 || block.chainid == 31337, "fork only");
        CurvePad pad = CurvePad(payable(vm.envAddress("CIRC_PAD")));
        address token = vm.envAddress("CIRC_TOKEN");
        uint256 buyerKey = vm.envUint("BUYER_KEY");
        address buyer = vm.addr(buyerKey);
        PositionLocker locker = PositionLocker(pad.locker());

        // Fill the curve with native OKB (excess refunded) -> Complete.
        (, uint256 need) = pad.previewBuy(token, type(uint128).max);
        console2.log("quote to complete (WOKB wei)", need);
        vm.startBroadcast(buyerKey);
        pad.buyWithOKB{value: need}(token, 0, block.timestamp + 1 hours);
        vm.stopBroadcast();
        (,,,,,,,,, CurvePad.Status st) = pad.curves(token);
        require(st == CurvePad.Status.Complete, "not Complete");
        console2.log("curve Complete");

        // Permissionless graduation by a keeper (here: the buyer key).
        vm.startBroadcast(buyerKey);
        pad.graduate(token);
        vm.stopBroadcast();

        PoolKey memory key = pad.graduator().poolKey(token, Addresses.WOKB);
        bytes32 poolId = keccak256(abi.encode(key));
        uint256 positionId = IPositionManager(Addresses.POSITION_MANAGER).nextTokenId() - 1;
        require(IPositionManager(Addresses.POSITION_MANAGER).ownerOf(positionId) == address(locker), "not locked");
        (, uint128 vQuote, uint128 vToken,,,,,,,) = pad.curves(token);
        (uint160 sqrtP,,,) = IStateView2(Addresses.STATE_VIEW).getSlot0(poolId);
        uint256 expectX192 =
            token < Addresses.WOKB ? Math.mulDiv(vQuote, 1 << 192, vToken) : Math.mulDiv(vToken, 1 << 192, vQuote);
        uint256 gotX192 = Math.mulDiv(sqrtP, sqrtP, 1);
        uint256 diff = gotX192 > expectX192 ? gotX192 - expectX192 : expectX192 - gotX192;
        require(diff * 1000 <= expectX192, "pool price off P_end by > 0.1%");
        console2.log("POOL_ID");
        console2.logBytes32(poolId);
        console2.log("POSITION_ID", positionId);
        console2.log("locked liquidity", uint256(IPositionManager(Addresses.POSITION_MANAGER).getPositionLiquidity(positionId)));
        console2.log("hook open", pad.hook().isOpen(poolId));

        // Sell 1M tokens through Universal Router 2.1.2, then collect LP fees into the locker.
        uint256 amountIn = 1_000_000 ether;
        bool zeroForOne = token == key.currency0;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInSingle(key, zeroForOne, uint128(amountIn), 0, 0, bytes("")));
        params[1] = abi.encode(token, amountIn);
        params[2] = abi.encode(Addresses.WOKB, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        uint256 before = IERC20(Addresses.WOKB).balanceOf(buyer);
        vm.startBroadcast(buyerKey);
        IERC20(token).approve(Addresses.PERMIT2, type(uint256).max);
        IAllowanceTransfer(Addresses.PERMIT2).approve(
            token, Addresses.UNIVERSAL_ROUTER, uint160(amountIn), uint48(block.timestamp + 1 hours)
        );
        IUniversalRouter2(Addresses.UNIVERSAL_ROUTER).execute(
            abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 1 hours
        );
        locker.collect(positionId);
        vm.stopBroadcast();
        console2.log("WOKB received from UR sell", IERC20(Addresses.WOKB).balanceOf(buyer) - before);
        console2.log("locker token fees accrued", locker.totalAccrued(token));
        console2.log("GATE2 SAMPLE RUN OK");
    }
}
