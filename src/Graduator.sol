// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {TickMath} from "./libraries/uniswap/TickMath.sol";
import {LiquidityAmounts} from "./libraries/uniswap/LiquidityAmounts.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";

/// @title Graduator
/// @notice Moves a sold-out curve into a locked full-range Uniswap v3 position. Deployed by CurvePad in its constructor;
/// no admin, callable only by CurvePad. CurvePad hands over the LP tokens and the raise for one `graduate` call; the
/// position goes to PositionLocker, token dust is burned and leftover quote goes back to CurvePad, so this contract
/// holds nothing between calls.
contract Graduator {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 internal constant BPS = 10_000;
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant TICK_LOWER = -887_200; // full range, multiples of tickSpacing 200
    int24 public constant TICK_UPPER = 887_200;
    /// @notice Max quote spent moving a pre-initialised pool to the curve price: 0.5% of the raise.
    uint256 public constant MAX_NORMALIZE_QUOTE_BPS = 50;
    /// @notice Max LP tokens sold into a pre-initialised pool (always at or above the curve price): 50% of lpTokens.
    uint256 public constant MAX_NORMALIZE_TOKEN_BPS = 5_000;
    uint256 internal constant MINT_SLIPPAGE_BPS = 10; // 0.1% on amounts used at mint

    address public immutable pad;
    IUniswapV3Factory public immutable v3Factory;
    INonfungiblePositionManager public immutable npm;
    address public immutable locker;

    /// @dev Pool allowed to call uniswapV3SwapCallback; set only for the duration of a normalisation swap.
    address private _swapPool;

    struct Result {
        address pool;
        uint256 positionId;
        uint256 tokenUsed;
        uint256 quoteUsed;
        uint256 quoteLeft;
    }

    event PoolNormalized(address indexed pool, int256 amount0, int256 amount1);

    error OnlyPad();
    error BadConfig();
    error NormalizeTooCostly();
    error BadCallback();

    constructor(IUniswapV3Factory v3Factory_, INonfungiblePositionManager npm_, address locker_) {
        pad = msg.sender;
        v3Factory = v3Factory_;
        npm = npm_;
        locker = locker_;
    }

    /// @notice CurvePad has already marked the token graduated and transferred `tokenAmt` tokens and `quoteAmt` quote here.
    /// @param vQuote,vToken the curve's final reserves; the pool opens at vQuote / vToken.
    /// @param lockData forwarded to PositionLocker with the position NFT.
    function graduate(
        address token,
        address quote,
        uint256 vQuote,
        uint256 vToken,
        uint256 tokenAmt,
        uint256 quoteAmt,
        bytes calldata lockData
    ) external returns (Result memory r) {
        if (msg.sender != pad) revert OnlyPad();
        bool tokenIs0 = token < quote;
        uint160 target = _sqrtPriceX96(vQuote, vToken, tokenIs0);

        r.pool = v3Factory.getPool(token, quote, POOL_FEE);
        if (r.pool == address(0)) r.pool = v3Factory.createPool(token, quote, POOL_FEE);

        (uint160 current,,,,,,) = IUniswapV3Pool(r.pool).slot0();
        if (current == 0) {
            IUniswapV3Pool(r.pool).initialize(target);
        } else if (current != target) {
            (tokenAmt, quoteAmt) = _normalize(r.pool, token, quote, tokenIs0, current, target, tokenAmt, quoteAmt);
        }

        (r.positionId, r.tokenUsed, r.quoteUsed) = _mintFullRange(token, quote, tokenIs0, target, tokenAmt, quoteAmt);
        npm.safeTransferFrom(address(this), locker, r.positionId, lockData);

        uint256 tokenDust = IERC20(token).balanceOf(address(this));
        if (tokenDust != 0) LaunchToken(token).burn(tokenDust);
        r.quoteLeft = IERC20(quote).balanceOf(address(this));
        if (r.quoteLeft != 0) IERC20(quote).safeTransfer(pad, r.quoteLeft);
    }

    /// @dev The pool was initialised by someone else. The token lock means it can only hold quote-side liquidity, so:
    /// moving the price through empty ticks is free, and moving it through quote liquidity means selling LP tokens at or
    /// above the curve price (never a loss). Both directions are hard-capped; past the cap, graduation reverts and the
    /// curve stays live (sells keep working), so no user funds are lost.
    function _normalize(
        address pool,
        address token,
        address quote,
        bool tokenIs0,
        uint160 current,
        uint160 target,
        uint256 tokenAmt,
        uint256 quoteAmt
    ) internal returns (uint256, uint256) {
        bool zeroForOne = target < current;
        bool payToken = zeroForOne == tokenIs0;
        uint256 maxIn = payToken ? tokenAmt * MAX_NORMALIZE_TOKEN_BPS / BPS : quoteAmt * MAX_NORMALIZE_QUOTE_BPS / BPS;
        if (maxIn == 0) maxIn = 1;

        (address token0, address token1) = tokenIs0 ? (token, quote) : (quote, token);
        _swapPool = pool;
        (int256 amount0, int256 amount1) =
            IUniswapV3Pool(pool).swap(address(this), zeroForOne, maxIn.toInt256(), target, abi.encode(token0, token1));
        _swapPool = address(0);

        (uint160 after_,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (after_ != target) revert NormalizeTooCostly();
        emit PoolNormalized(pool, amount0, amount1);

        (int256 dToken, int256 dQuote) = tokenIs0 ? (amount0, amount1) : (amount1, amount0);
        // positive = paid into the pool, negative = received from it
        tokenAmt = (tokenAmt.toInt256() - dToken).toUint256();
        quoteAmt = (quoteAmt.toInt256() - dQuote).toUint256();
        return (tokenAmt, quoteAmt);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _swapPool || msg.sender == address(0)) revert BadCallback();
        (address token0, address token1) = abi.decode(data, (address, address));
        if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    function _mintFullRange(
        address token,
        address quote,
        bool tokenIs0,
        uint160 sqrtPrice,
        uint256 tokenAmt,
        uint256 quoteAmt
    ) internal returns (uint256 positionId, uint256 tokenUsed, uint256 quoteUsed) {
        (address token0, address token1, uint256 amt0, uint256 amt1) =
            tokenIs0 ? (token, quote, tokenAmt, quoteAmt) : (quote, token, quoteAmt, tokenAmt);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(TICK_LOWER);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(TICK_UPPER);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtPrice, sqrtA, sqrtB, amt0, amt1);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPrice, sqrtA, sqrtB, liq);

        IERC20(token0).forceApprove(address(npm), amt0);
        IERC20(token1).forceApprove(address(npm), amt1);
        uint256 used0;
        uint256 used1;
        (positionId,, used0, used1) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: exp0 * (BPS - MINT_SLIPPAGE_BPS) / BPS,
                amount1Min: exp1 * (BPS - MINT_SLIPPAGE_BPS) / BPS,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        IERC20(token0).forceApprove(address(npm), 0);
        IERC20(token1).forceApprove(address(npm), 0);
        (tokenUsed, quoteUsed) = tokenIs0 ? (used0, used1) : (used1, used0);
    }

    /// @dev sqrt(token1/token0) in Q64.96 at the curve's price (quote per token = vQuote / vToken).
    function _sqrtPriceX96(uint256 vQuote, uint256 vToken, bool tokenIs0) internal pure returns (uint160) {
        uint256 ratioX192 = tokenIs0 ? Math.mulDiv(vQuote, 1 << 192, vToken) : Math.mulDiv(vToken, 1 << 192, vQuote);
        uint256 s = Math.sqrt(ratioX192);
        if (s < TickMath.MIN_SQRT_RATIO || s >= TickMath.MAX_SQRT_RATIO) revert BadConfig();
        return uint160(s);
    }
}
