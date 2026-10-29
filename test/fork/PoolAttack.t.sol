// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TickMath} from "../../src/libraries/uniswap/TickMath.sol";
import {IUniswapV3Pool, INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
import {Addresses} from "../../script/Addresses.sol";

/// @dev Someone creates and initialises the token's v3 pool before graduation, optionally with quote-only liquidity
/// (the token lock blocks any token-side liquidity). Graduation must still open at P_end, or revert past the cost cap
/// with every user's funds intact.
contract ForkPoolAttackTest is ForkBase {
    int24 constant SPACING = 200;

    function test_fork_attack_10x_noLiquidity() public {
        _attack(Addresses.WOKB, 1, 10, 1, 0, false);
    }

    function test_fork_attack_0_1x_noLiquidity() public {
        _attack(Addresses.WOKB, 1, 1, 10, 0, false);
    }

    function test_fork_attack_10x_smallQuoteLiquidity() public {
        _attack(Addresses.WOKB, 1, 10, 1, 1 ether, false);
    }

    function test_fork_attack_0_1x_quoteLiquidity() public {
        _attack(Addresses.WOKB, 1, 1, 10, 1_000 ether, false);
    }

    function test_fork_attack_10x_hugeQuoteLiquidity_reverts() public {
        _attack(Addresses.WOKB, 1, 10, 1, 5_000 ether, true);
    }

    function test_fork_attack_bem_10x_smallQuoteLiquidity() public {
        _attack(Addresses.BEM, 2, 10, 1, 5e8, false);
    }

    function test_fork_attack_tokenSideLiquidityBlocked() public {
        LaunchToken t = _launch(Addresses.WOKB, 1);
        vm.roll(block.number + pad.GUARD_BLOCKS());
        vm.prank(attacker);
        pad.buy(address(t), 1 ether, 0, block.timestamp);
        address pool = factory.createPool(address(t), Addresses.WOKB, 10_000);
        assertEq(pool, t.predictedPool());
        IUniswapV3Pool(pool).initialize(_sqrtAtMultiple(address(t), Addresses.WOKB, 1, 1));

        vm.startPrank(attacker);
        t.approve(address(npm), type(uint256).max);
        wokb.approve(address(npm), type(uint256).max);
        (address t0, address t1) = address(t) < Addresses.WOKB ? (address(t), Addresses.WOKB) : (Addresses.WOKB, address(t));
        vm.expectRevert(LaunchToken.PoolLocked.selector);
        npm.mint(
            INonfungiblePositionManager.MintParams(
                t0, t1, 10_000, -887_200, 887_200, 1_000 ether, 1_000 ether, 0, 0, attacker, block.timestamp
            )
        );
        vm.expectRevert(LaunchToken.PoolLocked.selector);
        t.transfer(pool, 1);
        vm.stopPrank();
    }

    function _attack(address quote, uint256 circuitId, uint256 num, uint256 den, uint256 quoteLiq, bool expectRevert)
        internal
    {
        LaunchToken t = _launch(quote, circuitId);
        vm.roll(block.number + pad.GUARD_BLOCKS());
        vm.prank(bob);
        uint256 bobTokens = pad.buy(address(t), quote == Addresses.WOKB ? 5 ether : 20e8, 0, block.timestamp);

        address pool = factory.createPool(address(t), quote, 10_000);
        uint160 target = _sqrtAtMultiple(address(t), quote, 1, 1);
        uint160 start = _sqrtAtMultiple(address(t), quote, num, den);
        IUniswapV3Pool(pool).initialize(start);
        if (quoteLiq != 0) _addQuoteOnly(pool, address(t), quote, start, target, quoteLiq);

        LaunchToken[] memory ts = new LaunchToken[](1);
        ts[0] = t;
        if (expectRevert) {
            (, uint256 need) = pad.previewBuy(address(t), type(uint128).max);
            vm.prank(alice);
            vm.expectRevert(CurvePad.NormalizeTooCostly.selector);
            pad.buy(address(t), need, 0, block.timestamp);
            // Curve stays live and fully backed: holders can still exit.
            (,,,,,,,,, bool graduated) = pad.curves(address(t));
            assertFalse(graduated);
            assertFalse(t.graduated());
            _assertSolvent(ts, quote);
            vm.startPrank(bob);
            t.approve(address(pad), bobTokens);
            uint256 back = pad.sell(address(t), bobTokens, 1, block.timestamp);
            vm.stopPrank();
            assertGt(back, 0);
            _assertSolvent(ts, quote);
            return;
        }

        (uint256 positionId,) = _graduate(t, alice);
        _assertSolvent(ts, quote);
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        (, uint128 vQuote, uint128 vToken,,,,,,,) = pad.curves(address(t));
        uint256 expectX192 = address(t) < quote ? Math.mulDiv(vQuote, 1 << 192, vToken) : Math.mulDiv(vToken, 1 << 192, vQuote);
        assertApproxEqRel(Math.mulDiv(sqrtP, sqrtP, 1), expectX192, 0.001e18, "opens at ~P_end");
        assertGt(_positionLiquidity(positionId), 0);
        assertEq(t.balanceOf(address(pad)), 0);
    }

    /// @dev Quote-only position on the quote side of the start price. When the target lies on that side (pool set above
    /// P_end), the range spans start..target, so normalising must sell LP tokens through it.
    function _addQuoteOnly(address pool, address token, address quote, uint160 start, uint160 target, uint256 amount)
        internal
    {
        int24 cur = TickMath.getTickAtSqrtRatio(start);
        int24 tgt = TickMath.getTickAtSqrtRatio(target);
        bool quoteIs0 = quote < token;
        int24 lo;
        int24 hi;
        // token0-only liquidity lives above the current tick, token1-only below it.
        if (quoteIs0) {
            lo = _floor(cur) + 2 * SPACING;
            hi = tgt > cur ? _floor(tgt) - SPACING : lo + 100 * SPACING;
        } else {
            hi = _floor(cur) - SPACING;
            lo = tgt < cur ? _floor(tgt) + 2 * SPACING : hi - 100 * SPACING;
        }
        require(lo < hi, "range");
        (address t0, address t1) = quoteIs0 ? (quote, token) : (token, quote);
        if (quote == Addresses.BEM) deal(Addresses.BEM, attacker, amount);
        vm.startPrank(attacker);
        IERC20(quote).approve(address(npm), type(uint256).max);
        npm.mint(
            INonfungiblePositionManager.MintParams(
                t0, t1, 10_000, lo, hi, quoteIs0 ? amount : 0, quoteIs0 ? 0 : amount, 0, 0, attacker, block.timestamp
            )
        );
        vm.stopPrank();
        assertGt(IERC20(quote).balanceOf(pool), 0, "attacker liquidity in pool");
    }

    function _floor(int24 tick) internal pure returns (int24) {
        int24 f = tick / SPACING * SPACING;
        if (tick < 0 && f != tick) f -= SPACING;
        return f;
    }
}
