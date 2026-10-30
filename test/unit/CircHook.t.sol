// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UnitBase} from "./Base.t.sol";
import {CircHook} from "../../src/CircHook.sol";
import {PoolKey, ModifyLiquidityParams} from "../../src/interfaces/IUniswapV4.sol";

/// @dev Hook gating in isolation (the PoolManager is pranked). The real PoolManager path is in test/fork/HookGate.t.sol.
contract CircHookUnitTest is UnitBase {
    CircHook hook;
    address graduator;
    PoolKey key;
    ModifyLiquidityParams mlp;

    function setUp() public override {
        super.setUp();
        hook = pad.hook();
        graduator = address(pad.graduator());
        key = PoolKey(address(0xA), address(0xB), 10_000, 200, address(hook));
        mlp = ModifyLiquidityParams(-887_200, 887_200, 1e18, bytes32(0));
    }

    function test_beforeInitialize_onlyGraduator() public {
        vm.prank(POOL_MANAGER);
        vm.expectRevert(CircHook.NotGraduator.selector);
        hook.beforeInitialize(alice, key, 1 << 96);

        vm.prank(POOL_MANAGER);
        assertEq(hook.beforeInitialize(graduator, key, 1 << 96), CircHook.beforeInitialize.selector);
    }

    function test_hooks_onlyPoolManager() public {
        vm.expectRevert(CircHook.NotPoolManager.selector);
        hook.beforeInitialize(graduator, key, 1 << 96);
        vm.expectRevert(CircHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(posm, key, mlp, "");
    }

    function test_allowAdd_onlyGraduator() public {
        vm.prank(alice);
        vm.expectRevert(CircHook.NotGraduator.selector);
        hook.allowAdd(keccak256(abi.encode(key)));
    }

    function test_beforeAddLiquidity_requiresGraduatorAuthorisation() public {
        // No authorisation: reverts even from the position manager.
        vm.prank(POOL_MANAGER);
        vm.expectRevert(CircHook.AddLiquidityNotAllowed.selector);
        hook.beforeAddLiquidity(posm, key, mlp, "");

        vm.prank(graduator);
        hook.allowAdd(keccak256(abi.encode(key)));

        // Authorised pool, but the add doesn't come through the position manager.
        vm.prank(POOL_MANAGER);
        vm.expectRevert(CircHook.AddLiquidityNotAllowed.selector);
        hook.beforeAddLiquidity(alice, key, mlp, "");

        // A different pool isn't covered by the authorisation.
        PoolKey memory other = PoolKey(address(0xA), address(0xC), 10_000, 200, address(hook));
        vm.prank(POOL_MANAGER);
        vm.expectRevert(CircHook.AddLiquidityNotAllowed.selector);
        hook.beforeAddLiquidity(posm, other, mlp, "");

        // The authorised add passes once...
        vm.prank(POOL_MANAGER);
        assertEq(hook.beforeAddLiquidity(posm, key, mlp, ""), CircHook.beforeAddLiquidity.selector);

        // ...and only once.
        vm.prank(POOL_MANAGER);
        vm.expectRevert(CircHook.AddLiquidityNotAllowed.selector);
        hook.beforeAddLiquidity(posm, key, mlp, "");
    }
}
