// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {CircHook} from "../../src/CircHook.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {PoolKey, ModifyLiquidityParams} from "../../src/interfaces/IUniswapV4.sol";
import {Addresses} from "../../script/Addresses.sol";

interface IPoolManagerFull {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
}

/// @dev Third parties try to front-run or crowd the graduation pool. The CircHook pool can only be initialized by
/// Graduator and only receives Graduator's own liquidity, so graduation always opens at P_end.
contract ForkHookGateTest is ForkBase {
    IPoolManagerFull pm = IPoolManagerFull(Addresses.POOL_MANAGER);

    bytes4 constant WRAPPED_ERROR = bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"));
    bytes4 constant HOOK_CALL_FAILED = bytes4(keccak256("HookCallFailed()"));
    bytes4 constant POOL_NOT_INITIALIZED = bytes4(keccak256("PoolNotInitialized()"));

    /// @dev v4-core wraps a hook's revert as WrappedError(hook, hookSelector, reason, HookCallFailed).
    function _hookRevert(bytes4 hookFn, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            WRAPPED_ERROR,
            address(pad.hook()),
            hookFn,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(HOOK_CALL_FAILED)
        );
    }

    function _sqrtAt(LaunchToken t, uint256 num, uint256 den) internal view returns (uint160) {
        (address quote,,,,,,,,,) = pad.curves(address(t));
        uint256 vQ = _vQuote0(quote);
        // launch price is fine for a "wrong price" probe: quote per token = vQuote0 / vToken0, scaled by num/den
        uint256 x192 = address(t) < quote
            ? Math.mulDiv(vQ * num, 1 << 192, 1_061_538_461_538_461_538_461_538_462 * den)
            : Math.mulDiv(1_061_538_461_538_461_538_461_538_462 * den, 1 << 192, vQ * num);
        return uint160(Math.sqrt(x192));
    }

    function test_fork_thirdPartyCannotInitializeHookPool() public {
        LaunchToken t = _launch(Addresses.WOKB, 1);
        PoolKey memory key = _key(t);
        uint160[3] memory prices = [_sqrtAt(t, 10, 1), _sqrtAt(t, 1, 10), _sqrtAt(t, 17, 1)];
        for (uint256 i; i < prices.length; ++i) {
            vm.prank(attacker);
            vm.expectRevert(_hookRevert(CircHook.beforeInitialize.selector, CircHook.NotGraduator.selector));
            pm.initialize(key, prices[i]);
        }
        // Other fee tiers / tick spacings with the Circ hook are gated the same way.
        PoolKey memory other = PoolKey(key.currency0, key.currency1, 3000, 60, key.hooks);
        vm.prank(attacker);
        vm.expectRevert(_hookRevert(CircHook.beforeInitialize.selector, CircHook.NotGraduator.selector));
        pm.initialize(other, prices[0]);

        (uint256 positionId, bytes32 poolId) = _graduate(t, alice);
        _assertOpensAtCurvePrice(t, poolId, 0.001e18);
        assertGt(posm.getPositionLiquidity(positionId), 0);
    }

    function test_fork_noLiquidityBeforeGraduation() public {
        LaunchToken t = _launch(Addresses.WOKB, 1);
        PoolKey memory key = _key(t);
        // Nobody can initialize the pool, so there's nothing to add to before graduation.
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, int24(-887_200), int24(887_200), uint256(1e18), type(uint128).max, type(uint128).max, attacker, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.prank(attacker);
        vm.expectRevert(POOL_NOT_INITIALIZED);
        posm.modifyLiquidities(abi.encode(abi.encodePacked(uint8(0x02), uint8(0x0d)), params), block.timestamp);

        (, bytes32 poolId) = _graduate(t, alice);
        _assertOpensAtCurvePrice(t, poolId, 0.001e18);
    }

    function test_fork_thirdPartyCannotAddLiquidityAfterGraduation() public {
        LaunchToken t = _launch(Addresses.BEM, 2);
        (uint256 positionId, bytes32 poolId) = _graduate(t, alice);
        uint128 liq = posm.getPositionLiquidity(positionId);
        PoolKey memory key = _key(t);

        // Through the v4 PositionManager (the only sender the hook ever admits, and only on Graduator's authorisation).
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, int24(-887_200), int24(887_200), uint256(1e18), type(uint128).max, type(uint128).max, attacker, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.prank(attacker);
        vm.expectRevert(_hookRevert(CircHook.beforeAddLiquidity.selector, CircHook.AddLiquidityNotAllowed.selector));
        posm.modifyLiquidities(abi.encode(abi.encodePacked(uint8(0x02), uint8(0x0d)), params), block.timestamp);

        // Directly on the PoolManager from an arbitrary contract.
        _directKey = key;
        vm.expectRevert(_hookRevert(CircHook.beforeAddLiquidity.selector, CircHook.AddLiquidityNotAllowed.selector));
        pm.unlock("");

        assertEq(stateView.getLiquidity(poolId), liq, "pool liquidity is still only the locked position");
    }

    function test_fork_otherPoolsDontAffectGraduation() public {
        LaunchToken t = _launch(Addresses.WOKB, 1);
        PoolKey memory circ = _key(t);
        // A vanilla (hookless) v4 pool for the same pair, initialized far off-price, is a different pool.
        PoolKey memory vanilla = PoolKey(circ.currency0, circ.currency1, circ.fee, circ.tickSpacing, address(0));
        vm.prank(attacker);
        pm.initialize(vanilla, _sqrtAt(t, 10, 1));

        (, bytes32 poolId) = _graduate(t, alice);
        _assertOpensAtCurvePrice(t, poolId, 0.001e18);
        assertTrue(poolId != keccak256(abi.encode(vanilla)));
    }

    // Direct PoolManager liquidity attempt (from this test contract, i.e. an arbitrary third party).
    PoolKey internal _directKey;

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(pm), "cb");
        pm.modifyLiquidity(_directKey, ModifyLiquidityParams(-887_200, 887_200, 1e18, bytes32(0)), "");
        return "";
    }
}
