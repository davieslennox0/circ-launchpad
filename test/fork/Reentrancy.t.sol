// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {PositionLocker} from "../../src/PositionLocker.sol";
import {CircHook} from "../../src/CircHook.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {PoolKey, ModifyLiquidityParams} from "../../src/interfaces/IUniswapV4.sol";
import {Addresses} from "../../script/Addresses.sol";
import {CurveConstants} from "../../script/CurveConstants.sol";
import {CircDeploy} from "../../script/Deploy.s.sol";

interface IPoolManagerModify {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256, int256);
}

interface IPositionManagerNoUnlock {
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable;
}

/// @dev 8-decimal quote token that, once armed, re-enters during the graduation mint's settlement (Permit2 pulling it
/// into the PoolManager) and tries a second liquidity add into the same Circ pool, both directly on the PoolManager
/// (which is unlocked at that moment) and through the PositionManager. Errors are recorded, not bubbled, so the
/// graduation itself completes and the test can inspect both attempts.
contract ReentrantQuote is ERC20 {
    address immutable poolManager;
    address immutable positionManager;
    PoolKey internal key;
    address internal attacker;
    bool public armed;
    bool public attempted;
    bool public directSucceeded;
    bool public posmSucceeded;
    bytes public directErr;
    bytes public posmErr;

    constructor(address poolManager_, address positionManager_) ERC20("Reentrant", "RQ") {
        poolManager = poolManager_;
        positionManager = positionManager_;
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(PoolKey memory key_, address attacker_) external {
        key = key_;
        attacker = attacker_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (armed && !attempted && to == poolManager) {
            attempted = true;
            ModifyLiquidityParams memory p = ModifyLiquidityParams(-887_200, 887_200, 1e15, bytes32("reenter"));
            try IPoolManagerModify(poolManager).modifyLiquidity(key, p, "") {
                directSucceeded = true;
            } catch (bytes memory e) {
                directErr = e;
            }
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(
                key, int24(-887_200), int24(887_200), uint256(1e15), type(uint128).max, type(uint128).max, attacker, bytes("")
            );
            try IPositionManagerNoUnlock(positionManager).modifyLiquiditiesWithoutUnlock(
                abi.encodePacked(uint8(0x02)), params
            ) {
                posmSucceeded = true;
            } catch (bytes memory e) {
                posmErr = e;
            }
        }
        return ok;
    }
}

contract ForkReentrancyTest is ForkBase {
    function test_fork_reentrantSecondAddDuringSettlementReverts() public {
        ReentrantQuote rq = new ReentrantQuote(Addresses.POOL_MANAGER, Addresses.POSITION_MANAGER);
        // A separate pad whose second quote slot is the reentrant token (BEM-like: 8 decimals, BEM curve constants).
        address deployer = makeAddr("reentrancyDeployer");
        vm.startPrank(deployer);
        (CurvePad rpad, PositionLocker rlocker) = CircDeploy.deployWith(
            deployer, protocol, sink, CurveConstants.wokb(), CurveConstants.bem(), address(rq)
        );
        vm.stopPrank();

        vm.prank(creator);
        LaunchToken t = LaunchToken(rpad.createLaunch(Addresses.NANDOUT, 3, "Reenter", "RE", "", address(rq), 0, 0));
        vm.roll(block.number + rpad.GUARD_BLOCKS());
        rq.mint(alice, 10_000e8);
        vm.startPrank(alice);
        rq.approve(address(rpad), type(uint256).max);
        (, uint256 need) = rpad.previewBuy(address(t), type(uint128).max);
        rpad.buy(address(t), need, 0, block.timestamp);
        vm.stopPrank();

        PoolKey memory key = rpad.graduator().poolKey(address(t), address(rq));
        bytes32 poolId = keccak256(abi.encode(key));
        rq.arm(key, attacker);

        vm.prank(makeAddr("keeper"));
        rpad.graduate(address(t));

        // The settlement transfer happened and the token did try to re-enter...
        assertTrue(rq.attempted(), "reentry attempted during settlement");
        // ...but the direct PoolManager add hit the hook: authorisation already consumed, pool not yet open.
        assertFalse(rq.directSucceeded(), "direct second add must revert");
        assertEq(
            rq.directErr(),
            abi.encodeWithSelector(
                bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")),
                address(rpad.hook()),
                CircHook.beforeAddLiquidity.selector,
                abi.encodeWithSelector(CircHook.AddLiquidityNotAllowed.selector),
                abi.encodeWithSelector(bytes4(keccak256("HookCallFailed()")))
            ),
            "hook rejected the second add"
        );
        // ...and the PositionManager route is closed by its own reentrancy lock.
        assertFalse(rq.posmSucceeded(), "PositionManager second add must revert");
        assertEq(bytes4(rq.posmErr()), bytes4(keccak256("ContractLocked()")));

        // Graduation itself completed normally, with only the locked position in the pool, and the pool is now open.
        (,,,,,,,,, CurvePad.Status st) = rpad.curves(address(t));
        assertEq(uint8(st), uint8(CurvePad.Status.Graduated));
        assertTrue(rpad.hook().isOpen(poolId));
        uint256 lockedId = posm.nextTokenId() - 1;
        assertEq(posm.ownerOf(lockedId), address(rlocker));
        assertEq(stateView.getLiquidity(poolId), posm.getPositionLiquidity(lockedId));
    }
}
