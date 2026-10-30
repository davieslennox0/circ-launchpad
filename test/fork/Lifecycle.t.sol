// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {PoolKey} from "../../src/interfaces/IUniswapV4.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Addresses} from "../../script/Addresses.sol";
import {CurveConstants} from "../../script/CurveConstants.sol";

contract ForkLifecycleTest is ForkBase {
    function test_fork_lifecycle_wokb() public {
        _lifecycle(Addresses.WOKB, 1, 1 ether);
    }

    function test_fork_lifecycle_bem8dp() public {
        _lifecycle(Addresses.BEM, 2, 5e8);
    }

    function _lifecycle(address quote, uint256 circuitId, uint256 unit) internal {
        LaunchToken t = _launch(quote, circuitId);
        (,,,,, address container,,,,) = pad.curves(address(t));
        assertEq(container, _container(circuitId));

        vm.roll(block.number + pad.GUARD_BLOCKS());
        LaunchToken[] memory ts = new LaunchToken[](1);
        ts[0] = t;
        // A churn of buys and partial sells from two traders.
        for (uint256 i; i < 12; ++i) {
            address who = i % 2 == 0 ? alice : bob;
            vm.prank(who);
            uint256 got = pad.buy(address(t), unit * (1 + i % 3), 0, block.timestamp);
            if (i % 3 == 2) {
                vm.startPrank(who);
                t.approve(address(pad), got / 2);
                pad.sell(address(t), got / 2, 0, block.timestamp);
                vm.stopPrank();
            }
            _assertSolvent(ts, quote);
        }

        uint256 accruedBefore = pad.totalAccrued(quote);
        _complete(t, alice);
        _assertSolvent(ts, quote); // Complete: funds still in the pad
        // v4 pools share the PoolManager's balance, so the raise is measured as the PoolManager's quote delta.
        uint256 pmQuoteBefore = IERC20(quote).balanceOf(Addresses.POOL_MANAGER);
        (uint256 positionId, bytes32 poolId) = _graduateNow(t);
        _assertSolvent(ts, quote);

        // Curve closed.
        vm.prank(alice);
        vm.expectRevert(CurvePad.CurveClosed.selector);
        pad.buy(address(t), unit, 0, block.timestamp);

        // Pool opens at the curve's final price (within 0.1%).
        _assertOpensAtCurvePrice(t, poolId, 0.001e18);

        // Position locked, liquidity live, raise in the pool.
        assertEq(posm.ownerOf(positionId), address(locker));
        assertEq(locker.containerOf(positionId), container);
        uint128 liq = posm.getPositionLiquidity(positionId);
        assertGt(liq, 0);
        assertEq(stateView.getLiquidity(poolId), liq, "the locked position is the pool's only liquidity");
        assertEq(t.balanceOf(address(pad)), 0, "dust burned");
        assertApproxEqRel(t.totalSupply(), 1e27, 0.0001e18);
        uint256 raised = IERC20(quote).balanceOf(Addresses.POOL_MANAGER) - pmQuoteBefore;
        uint256 rTarget = Math.mulDiv(
            _vQuote0(quote), CurveConstants.V_TOKEN0, CurveConstants.V_TOKEN0 - CurveConstants.CURVE_SUPPLY
        ) - _vQuote0(quote);
        assertApproxEqRel(raised, rTarget, 0.0001e18, "R in pool");
        assertGe(pad.totalAccrued(quote), accruedBefore, "graduation never reduces accrued fees");

        // Routing: trade the graduated token both ways through Universal Router 2.1.2, then collect and split LP fees.
        PoolKey memory key = _key(t);
        uint256 quoteOut = _routerSwap(alice, key, address(t), 1_000_000 ether);
        assertGt(quoteOut, 0, "sell via Universal Router");
        uint256 tokOut = _routerSwap(bob, key, quote, unit);
        assertGt(tokOut, 0, "buy via Universal Router");

        // Someone donates quote to the locker before the collect. The split must cover only what this collect brought
        // in, so the donation must not reach this position's Container (or anyone).
        uint256 donation = unit;
        vm.prank(bob);
        IERC20(quote).transfer(address(locker), donation);

        uint256 lockTokBefore = t.balanceOf(address(locker));
        uint256 lockQuoteBefore = IERC20(quote).balanceOf(address(locker));
        vm.recordLogs();
        locker.collect(positionId);
        (uint256 collectedTok, uint256 collectedQuote) = _collectedAmounts(positionId, address(t) < quote);
        assertEq(posm.getPositionLiquidity(positionId), liq, "collect never touches liquidity");
        assertGt(collectedTok, 0, "token fees collected");
        assertGt(collectedQuote, 0, "quote fees collected");
        _checkLockerSplit(address(t), container, collectedTok);
        _checkLockerSplit(quote, container, collectedQuote);
        assertEq(t.balanceOf(address(locker)) - lockTokBefore, collectedTok, "locker token delta == collected");
        assertEq(IERC20(quote).balanceOf(address(locker)) - lockQuoteBefore, collectedQuote, "locker quote delta == collected");

        // Creator fees: holder may route to the Container or (fallback) to their wallet; nobody else may.
        uint256 c = pad.accrued(quote, container);
        assertGt(c, 0);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("NotHolder()")));
        pad.claimCreator(container, quote, false);
        uint256 cBefore = IERC20(quote).balanceOf(container); // a Container is a real account anyone can send to
        vm.prank(creator);
        pad.claimCreator(container, quote, false);
        assertEq(IERC20(quote).balanceOf(container) - cBefore, c, "fees landed in the Container");

        // Locker creator claim pays exactly the accrued share; the donation stays unallocated in the locker.
        uint256 lcq = locker.accrued(quote, container);
        cBefore = IERC20(quote).balanceOf(container);
        vm.prank(creator);
        locker.claimCreator(container, quote, false);
        assertEq(IERC20(quote).balanceOf(container) - cBefore, lcq, "Container gets its LP-fee share only");
        assertEq(lcq, collectedQuote * 5_000 / 10_000, "donation not credited to the Container");
        assertEq(
            IERC20(quote).balanceOf(address(locker)), lockQuoteBefore + collectedQuote - lcq, "donation still unallocated"
        );
        assertGe(IERC20(quote).balanceOf(address(locker)) - locker.totalAccrued(quote), donation);

        uint256 lc = locker.accrued(address(t), container);
        uint256 before = t.balanceOf(creator);
        vm.prank(creator);
        locker.claimCreator(container, address(t), true);
        assertEq(t.balanceOf(creator) - before, lc, "fallback route to holder wallet");

        uint256 pAcc = pad.accrued(quote, protocol);
        uint256 sAcc = pad.accrued(quote, sink);
        uint256 pBefore = IERC20(quote).balanceOf(protocol);
        uint256 sBefore = IERC20(quote).balanceOf(sink);
        pad.claim(quote, protocol);
        pad.claim(quote, sink);
        assertEq(IERC20(quote).balanceOf(protocol) - pBefore, pAcc);
        assertEq(IERC20(quote).balanceOf(sink) - sBefore, sAcc);
        assertEq(pad.totalAccrued(quote), 0);
    }

    /// @dev Amounts from this collect's Collected event, as (token, quote).
    function _collectedAmounts(uint256 positionId, bool tokenIs0) internal returns (uint256 tok, uint256 qt) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Collected(uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(locker) && logs[i].topics[0] == sig && uint256(logs[i].topics[1]) == positionId)
            {
                (uint256 a0, uint256 a1) = abi.decode(logs[i].data, (uint256, uint256));
                (tok, qt) = tokenIs0 ? (a0, a1) : (a1, a0);
                found = true;
            }
        }
        assertTrue(found, "Collected event");
    }

    /// @dev First collect for this asset: the locker's accruals must be exactly the collected amount, split by bps.
    function _checkLockerSplit(address asset, address container, uint256 collected) internal view {
        uint256 total = locker.totalAccrued(asset);
        assertEq(total, collected, "accrued == collected (not balanceOf)");
        uint256 toC = locker.accrued(asset, container);
        uint256 toS = locker.accrued(asset, sink);
        uint256 toP = locker.accrued(asset, protocol);
        assertEq(toC + toS + toP, total);
        assertEq(toC, total * 5_000 / 10_000);
        assertEq(toS, total * 2_000 / 10_000);
    }
}
