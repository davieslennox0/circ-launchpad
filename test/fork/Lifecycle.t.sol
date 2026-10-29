// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForkBase, IPoolLiquidity} from "./ForkBase.t.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3.sol";
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
        assertEq(t.predictedPool(), _predictV3(address(t), quote), "token predicts the real v3 pool address");
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
        uint256 poolQuoteBefore = IERC20(quote).balanceOf(t.predictedPool());
        (uint256 positionId, address pool) = _graduateNow(t);
        _assertSolvent(ts, quote);

        // Curve closed.
        vm.prank(alice);
        vm.expectRevert(CurvePad.CurveClosed.selector);
        pad.buy(address(t), unit, 0, block.timestamp);

        // Pool opens at the curve's final price (within 0.1%).
        (, uint128 vQuote, uint128 vToken,,,,,,,) = pad.curves(address(t));
        uint256 expectX192 = address(t) < quote
            ? Math.mulDiv(vQuote, 1 << 192, vToken)
            : Math.mulDiv(vToken, 1 << 192, vQuote);
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 gotX192 = Math.mulDiv(sqrtP, sqrtP, 1);
        assertApproxEqRel(gotX192, expectX192, 0.001e18, "pool price ~ P_end");

        // Position locked, liquidity live, raise in the pool.
        assertEq(_ownerOfPosition(positionId), address(locker));
        assertEq(locker.containerOf(positionId), container);
        uint128 liq = _positionLiquidity(positionId);
        assertGt(liq, 0);
        assertEq(IPoolLiquidity(pool).liquidity(), liq, "only our position is in range");
        assertEq(t.balanceOf(address(pad)), 0, "dust burned");
        assertApproxEqRel(t.totalSupply(), 1e27, 0.0001e18);
        uint256 raised = IERC20(quote).balanceOf(pool) - poolQuoteBefore;
        uint256 rTarget = Math.mulDiv(
            _vQuote0(quote), CurveConstants.V_TOKEN0, CurveConstants.V_TOKEN0 - CurveConstants.CURVE_SUPPLY
        ) - _vQuote0(quote);
        assertApproxEqRel(raised, rTarget, 0.0001e18, "R in pool");
        assertGe(pad.totalAccrued(quote), accruedBefore, "graduation never reduces accrued fees");

        // Trade on v3 after graduation (pool lock lifted), then collect and split LP fees.
        vm.prank(alice);
        t.transfer(address(this), 1_000_000 ether);
        _poolSwap(pool, address(t), 1_000_000 ether);
        vm.prank(bob);
        IERC20(quote).transfer(address(this), unit);
        _poolSwap(pool, quote, unit);

        // Someone donates quote to the locker before the collect. Splits must come from what positionManager.collect
        // returns, never from balanceOf, so the donation must not reach this position's Container (or anyone).
        uint256 donation = unit;
        vm.prank(bob);
        IERC20(quote).transfer(address(locker), donation);

        uint256 lockTokBefore = t.balanceOf(address(locker));
        uint256 lockQuoteBefore = IERC20(quote).balanceOf(address(locker));
        vm.recordLogs();
        locker.collect(positionId);
        (uint256 collectedTok, uint256 collectedQuote) = _collectedAmounts(positionId, address(t) < quote);
        assertEq(_positionLiquidity(positionId), liq, "collect never touches liquidity");
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

    function _predictV3(address token, address quote) internal pure returns (address) {
        (address a, address b) = token < quote ? (token, quote) : (quote, token);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            Addresses.V3_FACTORY,
                            keccak256(abi.encode(a, b, uint24(10_000))),
                            bytes32(0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)
                        )
                    )
                )
            )
        );
    }

    function _ownerOfPosition(uint256 id) internal view returns (address o) {
        (bool ok, bytes memory r) = address(npm).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        require(ok);
        o = abi.decode(r, (address));
    }
}
