// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TickMath} from "../../src/libraries/uniswap/TickMath.sol";
import {Graduator} from "../../src/Graduator.sol";
import {IUniswapV3Pool, INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
import {Addresses} from "../../script/Addresses.sol";

/// @dev Someone creates and initialises the token's v3 pool before graduation, optionally with quote-only liquidity
/// (the token lock blocks any token-side liquidity). Graduation must still open at P_end, or revert past the cost cap
/// with every user's funds intact.
interface INpmDecrease {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
}

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

        // (a) A direct transfer of the token to the pool reverts with the token's own error.
        vm.prank(attacker);
        vm.expectRevert(LaunchToken.PoolLocked.selector);
        t.transfer(pool, 1);
        // ...and so does a transfer out of it (nothing to move, but the lock is symmetric).
        vm.prank(pool);
        vm.expectRevert(LaunchToken.PoolLocked.selector);
        t.transfer(attacker, 0);

        // The position manager pulls the token with TransferHelper, which surfaces that PoolLocked as "STF".
        INonfungiblePositionManager.MintParams memory mp = _fullRangeMint(address(t), Addresses.WOKB);
        vm.startPrank(attacker);
        t.approve(address(npm), type(uint256).max);
        wokb.approve(address(npm), type(uint256).max);
        vm.expectRevert(bytes("STF"));
        npm.mint(mp);
        vm.stopPrank();

        // (b) After graduation the identical mint succeeds.
        _graduate(t, alice);
        uint256 tokBefore = t.balanceOf(attacker);
        vm.prank(attacker);
        (uint256 id, uint128 liq,,) = npm.mint(mp);
        assertGt(liq, 0, "token-side liquidity allowed after graduation");
        assertLt(t.balanceOf(attacker), tokBefore, "tokens moved into the pool");
        assertGt(id, 0);
    }

    function _fullRangeMint(address token, address quote)
        internal
        view
        returns (INonfungiblePositionManager.MintParams memory)
    {
        (address t0, address t1) = token < quote ? (token, quote) : (quote, token);
        return INonfungiblePositionManager.MintParams(
            t0, t1, 10_000, -887_200, 887_200, 1_000_000 ether, 1 ether, 0, 0, attacker, block.timestamp + 1 days
        );
    }

    function _attack(address quote, uint256 circuitId, uint256 num, uint256 den, uint256 quoteLiq, bool expectRevert)
        internal
    {
        LaunchToken t = _launch(quote, circuitId);
        vm.roll(block.number + pad.GUARD_BLOCKS());
        vm.prank(bob);
        pad.buy(address(t), quote == Addresses.WOKB ? 5 ether : 20e8, 0, block.timestamp);

        address pool = factory.createPool(address(t), quote, 10_000);
        uint160 target = _sqrtAtMultiple(address(t), quote, 1, 1);
        uint160 start = _sqrtAtMultiple(address(t), quote, num, den);
        IUniswapV3Pool(pool).initialize(start);
        uint256 griefId;
        if (quoteLiq != 0) griefId = _addQuoteOnly(pool, address(t), quote, start, target, quoteLiq);

        LaunchToken[] memory ts = new LaunchToken[](1);
        ts[0] = t;
        _complete(t, alice);
        _assertSolvent(ts, quote);

        if (expectRevert) {
            // Griefed: graduate() reverts, twice, and changes nothing. The curve stays Complete and fully backed.
            for (uint256 i; i < 2; ++i) {
                vm.prank(makeAddr("keeper"));
                vm.expectRevert(Graduator.NormalizeTooCostly.selector);
                pad.graduate(address(t));
            }
            (,,,,,,,,, CurvePad.Status st) = pad.curves(address(t));
            assertEq(uint8(st), uint8(CurvePad.Status.Complete));
            assertFalse(t.graduated());
            assertEq(t.balanceOf(address(pad)), 194_049_965_012_863_841_617_977_315, "LP reserve still in the pad");
            _assertSolvent(ts, quote);
            _assertGraduatorEmpty(address(t), quote);
            vm.prank(bob);
            vm.expectRevert(CurvePad.CurveClosed.selector);
            pad.buy(address(t), 1e6, 0, block.timestamp);

            // The grief is removed (the attacker pulls their quote-only liquidity); graduate() now succeeds.
            _removeLiquidity(griefId);
        }

        (uint256 positionId,) = _graduateNow(t);
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
        returns (uint256 id)
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
        (id,,,) = npm.mint(
            INonfungiblePositionManager.MintParams(
                t0, t1, 10_000, lo, hi, quoteIs0 ? amount : 0, quoteIs0 ? 0 : amount, 0, 0, attacker, block.timestamp
            )
        );
        vm.stopPrank();
        assertGt(IERC20(quote).balanceOf(pool), 0, "attacker liquidity in pool");
    }

    function _removeLiquidity(uint256 id) internal {
        (,,,,,,, uint128 liq,,,,) = npm.positions(id);
        vm.startPrank(attacker);
        INpmDecrease(address(npm)).decreaseLiquidity(INpmDecrease.DecreaseLiquidityParams(id, liq, 0, 0, block.timestamp));
        npm.collect(INonfungiblePositionManager.CollectParams(id, attacker, type(uint128).max, type(uint128).max));
        vm.stopPrank();
    }

    function _floor(int24 tick) internal pure returns (int24) {
        int24 f = tick / SPACING * SPACING;
        if (tick < 0 && f != tick) f -= SPACING;
        return f;
    }
}
