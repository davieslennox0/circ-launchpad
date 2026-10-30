// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {CircHook} from "./CircHook.sol";
import {TickMath} from "./libraries/uniswap/TickMath.sol";
import {LiquidityAmounts} from "./libraries/uniswap/LiquidityAmounts.sol";
import {
    PoolKey,
    IPoolManager,
    IPositionManager,
    IAllowanceTransfer,
    V4Actions
} from "./interfaces/IUniswapV4.sol";

/// @title Graduator
/// @notice Moves a Complete curve into a locked full-range Uniswap v4 position in a CircHook pool. Deployed by CurvePad in
/// its constructor; no admin, callable only by CurvePad. Only Graduator can initialize a CircHook pool (enforced by the
/// hook), so the pool always opens at exactly the curve's final price: there is no pre-existing pool to normalise.
/// CurvePad hands over the LP tokens and the raise for one `graduate` call; the position goes to PositionLocker, token
/// dust is burned and leftover quote goes back to CurvePad, so this contract holds nothing between calls.
contract Graduator {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint24 public constant POOL_FEE = 10_000; // 1%
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200; // full range, multiples of 200
    int24 public constant TICK_UPPER = 887_200;

    address public immutable pad;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    CircHook public immutable hook;
    address public immutable locker;

    struct Result {
        bytes32 poolId;
        uint256 positionId;
        uint256 tokenUsed;
        uint256 quoteUsed;
        uint256 quoteLeft;
    }

    error OnlyPad();
    error BadConfig();

    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        CircHook hook_,
        address locker_
    ) {
        pad = msg.sender;
        poolManager = poolManager_;
        positionManager = positionManager_;
        permit2 = permit2_;
        hook = hook_;
        locker = locker_;
    }

    /// @notice The pool key every Circ launch graduates into.
    function poolKey(address token, address quote) public view returns (PoolKey memory key) {
        (address c0, address c1) = token < quote ? (token, quote) : (quote, token);
        key = PoolKey(c0, c1, POOL_FEE, TICK_SPACING, address(hook));
    }

    /// @notice CurvePad has transferred `tokenAmt` tokens and `quoteAmt` quote here.
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
        PoolKey memory key = poolKey(token, quote);
        r.poolId = keccak256(abi.encode(key));
        uint160 sqrtPrice = _sqrtPriceX96(vQuote, vToken, tokenIs0);
        poolManager.initialize(key, sqrtPrice);

        (uint256 amt0, uint256 amt1) = tokenIs0 ? (tokenAmt, quoteAmt) : (quoteAmt, tokenAmt);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtRatioAtTick(TICK_LOWER), TickMath.getSqrtRatioAtTick(TICK_UPPER), amt0, amt1
        );

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 quoteBefore = IERC20(quote).balanceOf(address(this));
        r.positionId = positionManager.nextTokenId();
        _mint(key, liq, amt0, amt1, r.poolId);
        r.tokenUsed = tokenBefore - IERC20(token).balanceOf(address(this));
        r.quoteUsed = quoteBefore - IERC20(quote).balanceOf(address(this));

        positionManager.safeTransferFrom(address(this), locker, r.positionId, lockData);

        uint256 tokenDust = IERC20(token).balanceOf(address(this));
        if (tokenDust != 0) LaunchToken(token).burn(tokenDust);
        r.quoteLeft = IERC20(quote).balanceOf(address(this));
        if (r.quoteLeft != 0) IERC20(quote).safeTransfer(pad, r.quoteLeft);
    }

    /// @dev MINT_POSITION (owner = this) then SETTLE_PAIR, paid through Permit2. The hook admits exactly this one add.
    function _mint(PoolKey memory key, uint128 liq, uint256 amt0, uint256 amt1, bytes32 poolId) internal {
        _approve(key.currency0, amt0);
        _approve(key.currency1, amt1);
        hook.allowAdd(poolId);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(liq), amt0.toUint128(), amt1.toUint128(), address(this), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(V4Actions.MINT_POSITION, V4Actions.SETTLE_PAIR), params), block.timestamp
        );

        _revoke(key.currency0);
        _revoke(key.currency1);
    }

    function _approve(address currency, uint256 amount) internal {
        IERC20(currency).forceApprove(address(permit2), amount);
        permit2.approve(currency, address(positionManager), amount.toUint160(), uint48(block.timestamp));
    }

    function _revoke(address currency) internal {
        IERC20(currency).forceApprove(address(permit2), 0);
        permit2.approve(currency, address(positionManager), 0, 0);
    }

    /// @dev sqrt(currency1/currency0) in Q64.96 at the curve's price (quote per token = vQuote / vToken).
    function _sqrtPriceX96(uint256 vQuote, uint256 vToken, bool tokenIs0) internal pure returns (uint160) {
        uint256 ratioX192 = tokenIs0 ? Math.mulDiv(vQuote, 1 << 192, vToken) : Math.mulDiv(vToken, 1 << 192, vQuote);
        uint256 s = Math.sqrt(ratioX192);
        if (s < TickMath.MIN_SQRT_RATIO || s >= TickMath.MAX_SQRT_RATIO) revert BadConfig();
        return uint160(s);
    }
}
