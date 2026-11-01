// SPDX-License-Identifier: GPL-2.0-or-later
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

    function test_beforeAddLiquidity_rejectsWithoutAuthorisation() public {
        vm.prank(POOL_MANAGER);
        vm.expectRevert(CircHook.AddLiquidityNotAllowed.selector);
        hook.beforeAddLiquidity(posm, key, mlp, "");
    }

    /// @dev allowAdd and the add must share a transaction (transient storage), as they do in Graduator.graduate. Foundry
    /// doesn't carry transient storage across a test's top-level calls, so a harness plays Graduator and PoolManager in
    /// one call. The real path (PoolManager -> hook via PositionManager) is covered by the fork suite.
    function test_beforeAddLiquidity_oneShotAuthorisation() public {
        HookHarness h = new HookHarness(posm);
        h.run(key, mlp);
    }

    function test_openPool_onlyGraduator() public {
        vm.prank(alice);
        vm.expectRevert(CircHook.NotGraduator.selector);
        hook.openPool(keccak256(abi.encode(key)));
    }

    function test_openPool_thenAnyoneMayAdd() public {
        bytes32 id = keccak256(abi.encode(key));
        assertFalse(hook.isOpen(id));
        vm.prank(graduator);
        hook.openPool(id);
        assertTrue(hook.isOpen(id));
        vm.prank(POOL_MANAGER);
        assertEq(hook.beforeAddLiquidity(alice, key, mlp, ""), CircHook.beforeAddLiquidity.selector);
        // Other (unopened) pools stay gated.
        PoolKey memory other = PoolKey(address(0xA), address(0xC), 10_000, 200, address(hook));
        vm.prank(POOL_MANAGER);
        vm.expectRevert(CircHook.AddLiquidityNotAllowed.selector);
        hook.beforeAddLiquidity(alice, other, mlp, "");
    }
}

/// @dev Stands in for both Graduator and PoolManager of a dedicated CircHook instance.
contract HookHarness {
    CircHook public immutable hook;
    address immutable posm;

    constructor(address posm_) {
        posm = posm_;
        hook = new CircHook(address(this), address(this), posm_);
    }

    function run(PoolKey memory key, ModifyLiquidityParams memory mlp) external {
        hook.allowAdd(keccak256(abi.encode(key)));

        // Authorised pool, but the add doesn't come through the position manager.
        _expectNotAllowed(address(0xBEEF), key, mlp);
        // A different pool isn't covered by the authorisation.
        PoolKey memory other = PoolKey(key.currency0, address(0xC), key.fee, key.tickSpacing, key.hooks);
        _expectNotAllowed(posm, other, mlp);
        // The authorised add passes once...
        require(hook.beforeAddLiquidity(posm, key, mlp, "") == CircHook.beforeAddLiquidity.selector, "authorised add");
        // ...and only once.
        _expectNotAllowed(posm, key, mlp);
    }

    function _expectNotAllowed(address sender, PoolKey memory key, ModifyLiquidityParams memory mlp) internal {
        try hook.beforeAddLiquidity(sender, key, mlp, "") {
            revert("expected AddLiquidityNotAllowed");
        } catch (bytes memory err) {
            require(bytes4(err) == CircHook.AddLiquidityNotAllowed.selector, "wrong error");
        }
    }
}
