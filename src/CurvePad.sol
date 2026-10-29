// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FeeVault} from "./FeeVault.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {PositionLocker} from "./PositionLocker.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {TickMath} from "./libraries/uniswap/TickMath.sol";
import {LiquidityAmounts} from "./libraries/uniswap/LiquidityAmounts.sol";
import {ICircuitFactory, ICircuitNFT, IERC6551Registry} from "./interfaces/ITapeOut.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager, IWOKB} from "./interfaces/IUniswapV3.sol";

/// @title CurvePad
/// @notice Circ launchpad singleton. Every launch is bound to a TapeOut Circuit NFT, trades on a virtual
/// constant-product curve held here, and graduates into a locked full-range Uniswap v3 position when the curve sells out.
contract CurvePad is FeeVault {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct QuoteConfig {
        uint128 vQuote0;
        uint128 vToken0;
        uint128 curveSupply;
        uint128 lpTokens;
    }

    struct Curve {
        address quote;
        uint128 vQuote;
        uint128 vToken;
        uint128 realQuote;
        uint128 tokensLeft;
        address container;
        address circuitNft;
        uint256 circuitId;
        uint64 launchBlock;
        bool graduated;
    }

    struct Params {
        address wokb;
        address bem;
        QuoteConfig wokbConfig;
        QuoteConfig bemConfig;
        address circuitFactory;
        address registry;
        address containerImpl;
        address v3Factory;
        address npm;
        address locker;
        address protocol;
        address sink;
    }

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant TICK_LOWER = -887_200; // full range, multiples of tickSpacing 200
    int24 public constant TICK_UPPER = 887_200;
    uint256 public constant GUARD_BLOCKS = 5;
    uint256 public constant MAX_EARLY_BUY = TOTAL_SUPPLY / 100;
    /// @notice Max quote spent moving a pre-initialised pool to the curve price: 0.5% of the raise.
    uint256 public constant MAX_NORMALIZE_QUOTE_BPS = 50;
    /// @notice Max LP tokens sold into a pre-initialised pool (always at or above the curve price): 50% of lpTokens.
    uint256 public constant MAX_NORMALIZE_TOKEN_BPS = 5_000;
    uint256 internal constant MINT_SLIPPAGE_BPS = 10; // 0.1% on amounts used at mint

    address public immutable wokb;
    address public immutable bem;
    ICircuitFactory public immutable circuitFactory;
    IERC6551Registry public immutable registry;
    address public immutable containerImpl;
    IUniswapV3Factory public immutable v3Factory;
    INonfungiblePositionManager public immutable npm;
    address public immutable locker;

    uint128 internal immutable wokbVQuote0;
    uint128 internal immutable wokbVToken0;
    uint128 internal immutable wokbCurveSupply;
    uint128 internal immutable wokbLpTokens;
    uint128 internal immutable bemVQuote0;
    uint128 internal immutable bemVToken0;
    uint128 internal immutable bemCurveSupply;
    uint128 internal immutable bemLpTokens;

    mapping(address token => Curve) public curves;

    /// @dev Pool allowed to call uniswapV3SwapCallback; set only for the duration of a normalisation swap.
    address private _swapPool;

    event LaunchCreated(
        address indexed token,
        address indexed quote,
        address indexed circuitNft,
        uint256 circuitId,
        address container,
        address creator
    );
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 vQuote,
        uint256 vToken
    );
    event Graduated(address indexed token, address indexed pool, uint256 positionId, uint256 raised, uint256 lpTokens);
    event PoolNormalized(address indexed pool, int256 amount0, int256 amount1);

    error BadConfig();
    error BadQuote();
    error NotTapeOut();
    error UnknownLaunch();
    error AlreadyGraduated();
    error Expired();
    error ZeroAmount();
    error Slippage();
    error BadValue();
    error NormalizeTooCostly();
    error BadCallback();
    error NativeTransferFailed();

    constructor(Params memory p) FeeVault(p.protocol, p.sink) {
        if (
            p.wokb == address(0) || p.bem == address(0) || p.circuitFactory == address(0) || p.registry == address(0)
                || p.containerImpl == address(0) || p.v3Factory == address(0) || p.npm == address(0)
                || p.locker == address(0)
        ) revert ZeroAddress();
        _checkConfig(p.wokbConfig);
        _checkConfig(p.bemConfig);
        if (PositionLocker(p.locker).pad() != address(this) || address(PositionLocker(p.locker).npm()) != p.npm) {
            revert BadConfig();
        }
        wokb = p.wokb;
        bem = p.bem;
        circuitFactory = ICircuitFactory(p.circuitFactory);
        registry = IERC6551Registry(p.registry);
        containerImpl = p.containerImpl;
        v3Factory = IUniswapV3Factory(p.v3Factory);
        npm = INonfungiblePositionManager(p.npm);
        locker = p.locker;
        (wokbVQuote0, wokbVToken0, wokbCurveSupply, wokbLpTokens) =
            (p.wokbConfig.vQuote0, p.wokbConfig.vToken0, p.wokbConfig.curveSupply, p.wokbConfig.lpTokens);
        (bemVQuote0, bemVToken0, bemCurveSupply, bemLpTokens) =
            (p.bemConfig.vQuote0, p.bemConfig.vToken0, p.bemConfig.curveSupply, p.bemConfig.lpTokens);
    }

    receive() external payable {
        if (msg.sender != wokb) revert BadValue(); // only WOKB unwraps
    }

    // ------------------------------------------------------------------ launch

    /// @notice Launch a token bound to a TapeOut Circuit you hold.
    /// @param devBuyAmount BEM launches only: quote pulled via transferFrom for the creator's dev-buy.
    /// WOKB launches send native OKB as msg.value instead (wrapped here). The dev-buy is exempt from anti-snipe.
    function createLaunch(
        address circuitNft,
        uint256 circuitId,
        string calldata name,
        string calldata symbol,
        address quote,
        uint256 devBuyAmount,
        uint256 devBuyMinOut
    ) external payable nonReentrant returns (address token) {
        token = _deployLaunch(circuitNft, circuitId, name, symbol, quote);

        if (quote == wokb) {
            if (devBuyAmount != 0) revert BadValue();
            if (msg.value != 0) {
                IWOKB(wokb).deposit{value: msg.value}();
                uint256 used = _buy(token, msg.value, devBuyMinOut, true);
                _refundNative(msg.value - used);
            }
        } else {
            if (msg.value != 0) revert BadValue();
            if (devBuyAmount != 0) {
                uint256 received = _pullQuote(quote, devBuyAmount);
                uint256 used = _buy(token, received, devBuyMinOut, true);
                if (received > used) IERC20(quote).safeTransfer(msg.sender, received - used);
            }
        }
    }

    function _deployLaunch(
        address circuitNft,
        uint256 circuitId,
        string calldata name,
        string calldata symbol,
        address quote
    ) internal returns (address token) {
        QuoteConfig memory cfg = quoteConfig(quote);
        if (!circuitFactory.isCPU(circuitNft)) revert NotTapeOut();
        if (ICircuitNFT(circuitNft).ownerOf(circuitId) != msg.sender) revert NotHolder();
        address container = registry.account(containerImpl, bytes32(0), block.chainid, circuitNft, circuitId);
        _registerContainer(container, circuitNft, circuitId);

        bytes32 salt = keccak256(abi.encode(msg.sender, circuitNft, circuitId));
        token = address(new LaunchToken{salt: salt}(name, symbol, quote, address(v3Factory)));
        curves[token] = Curve({
            quote: quote,
            vQuote: cfg.vQuote0,
            vToken: cfg.vToken0,
            realQuote: 0,
            tokensLeft: cfg.curveSupply,
            container: container,
            circuitNft: circuitNft,
            circuitId: circuitId,
            launchBlock: uint64(block.number),
            graduated: false
        });
        emit LaunchCreated(token, quote, circuitNft, circuitId, container, msg.sender);
    }

    // ------------------------------------------------------------------ trade

    /// @notice Buy with the curve's quote ERC-20 (approve first). Excess beyond the curve's remaining supply is refunded.
    function buy(address token, uint256 quoteIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkDeadline(deadline);
        address quote = _curve(token).quote;
        uint256 received = _pullQuote(quote, quoteIn);
        uint256 balBefore = IERC20(token).balanceOf(msg.sender);
        uint256 used = _buy(token, received, minTokensOut, false);
        if (received > used) IERC20(quote).safeTransfer(msg.sender, received - used);
        tokensOut = IERC20(token).balanceOf(msg.sender) - balBefore;
    }

    /// @notice Buy a WOKB-quoted launch with native OKB. Excess is refunded in native OKB.
    function buyWithOKB(address token, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkDeadline(deadline);
        if (_curve(token).quote != wokb) revert BadQuote();
        if (msg.value == 0) revert ZeroAmount();
        IWOKB(wokb).deposit{value: msg.value}();
        uint256 balBefore = IERC20(token).balanceOf(msg.sender);
        uint256 used = _buy(token, msg.value, minTokensOut, false);
        _refundNative(msg.value - used);
        tokensOut = IERC20(token).balanceOf(msg.sender) - balBefore;
    }

    /// @notice Sell tokens back to the curve for its quote ERC-20 (approve the token first).
    function sell(address token, uint256 tokensIn, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 quoteToUser)
    {
        _checkDeadline(deadline);
        Curve storage c = _curve(token);
        if (c.graduated) revert AlreadyGraduated();
        if (tokensIn == 0) revert ZeroAmount();

        uint256 out = CurveMath.quoteOut(c.vQuote, c.vToken, tokensIn);
        uint256 fee = CurveMath.feeOn(out);
        quoteToUser = out - fee;
        if (quoteToUser == 0) revert ZeroAmount();
        if (quoteToUser < minQuoteOut) revert Slippage();

        c.vQuote -= out.toUint128();
        c.vToken += tokensIn.toUint128();
        c.realQuote -= out.toUint128(); // reverts if the curve would pay out more than it holds
        c.tokensLeft += tokensIn.toUint128();
        _accrueSplit(c.quote, c.container, fee);

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        IERC20(c.quote).safeTransfer(msg.sender, quoteToUser);
        emit Trade(token, msg.sender, false, out, tokensIn, fee, c.vQuote, c.vToken);
    }

    // ------------------------------------------------------------------ views

    function quoteConfig(address quote) public view returns (QuoteConfig memory) {
        if (quote == wokb) return QuoteConfig(wokbVQuote0, wokbVToken0, wokbCurveSupply, wokbLpTokens);
        if (quote == bem) return QuoteConfig(bemVQuote0, bemVToken0, bemCurveSupply, bemLpTokens);
        revert BadQuote();
    }

    /// @notice Tokens a buy of `quoteIn` would return right now (ignores the anti-snipe cap).
    function previewBuy(address token, uint256 quoteIn) external view returns (uint256 tokensOut, uint256 quoteUsed) {
        Curve storage c = _curve(token);
        uint256 net = quoteIn - CurveMath.feeOn(quoteIn);
        tokensOut = CurveMath.tokensOut(c.vQuote, c.vToken, net);
        quoteUsed = quoteIn;
        if (tokensOut > c.tokensLeft) {
            tokensOut = c.tokensLeft;
            quoteUsed = CurveMath.grossForNet(CurveMath.quoteForTokens(c.vQuote, c.vToken, tokensOut));
        }
    }

    function previewSell(address token, uint256 tokensIn) external view returns (uint256 quoteToUser) {
        Curve storage c = _curve(token);
        uint256 out = CurveMath.quoteOut(c.vQuote, c.vToken, tokensIn);
        quoteToUser = out - CurveMath.feeOn(out);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Quote for this buy is already held by the pad. Returns the gross quote consumed (fee included).
    function _buy(address token, uint256 quoteIn, uint256 minTokensOut, bool exempt) internal returns (uint256 used) {
        Curve storage c = _curve(token);
        if (c.graduated) revert AlreadyGraduated();

        uint256 fee = CurveMath.feeOn(quoteIn);
        uint256 net = quoteIn - fee;
        uint256 out = CurveMath.tokensOut(c.vQuote, c.vToken, net);
        used = quoteIn;

        uint256 cap = c.tokensLeft;
        if (!exempt && block.number < c.launchBlock + GUARD_BLOCKS && cap > MAX_EARLY_BUY) cap = MAX_EARLY_BUY;
        if (out > cap) {
            out = cap;
            net = CurveMath.quoteForTokens(c.vQuote, c.vToken, out);
            used = CurveMath.grossForNet(net);
            fee = used - net;
        }
        if (out == 0) revert ZeroAmount();
        if (out < minTokensOut) revert Slippage();

        c.vQuote += net.toUint128();
        c.vToken -= out.toUint128();
        c.realQuote += net.toUint128();
        c.tokensLeft -= out.toUint128();
        _accrueSplit(c.quote, c.container, fee);

        IERC20(token).safeTransfer(msg.sender, out);
        emit Trade(token, msg.sender, true, used, out, fee, c.vQuote, c.vToken);

        if (c.tokensLeft == 0) _graduate(token, c);
    }

    function _graduate(address token, Curve storage c) internal {
        c.graduated = true;
        address quote = c.quote;
        uint256 quoteAvail = c.realQuote;
        c.realQuote = 0;
        bool tokenIs0 = token < quote;
        uint160 target = _sqrtPriceX96(c.vQuote, c.vToken, tokenIs0);

        address pool = v3Factory.getPool(token, quote, POOL_FEE);
        if (pool == address(0)) pool = v3Factory.createPool(token, quote, POOL_FEE);

        // Unlock the token first: normalising an attacker-initialised pool may need to sell tokens into it.
        LaunchToken(token).markGraduated();

        uint256 tokenAvail = IERC20(token).balanceOf(address(this));
        (uint160 current,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (current == 0) {
            IUniswapV3Pool(pool).initialize(target);
        } else if (current != target) {
            (tokenAvail, quoteAvail) = _normalize(pool, token, quote, tokenIs0, current, target, tokenAvail, quoteAvail);
        }

        (uint256 positionId, uint256 tokenUsed, uint256 quoteUsed) =
            _mintFullRange(token, quote, tokenIs0, target, tokenAvail, quoteAvail);
        npm.safeTransferFrom(address(this), locker, positionId, abi.encode(token, c.container, c.circuitNft, c.circuitId));

        uint256 tokenDust = IERC20(token).balanceOf(address(this));
        if (tokenDust != 0) LaunchToken(token).burn(tokenDust);
        _accrueProtocol(quote, quoteAvail - quoteUsed);

        emit Graduated(token, pool, positionId, quoteUsed, tokenUsed);
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
        uint256 tokenAvail,
        uint256 quoteAvail
    ) internal returns (uint256, uint256) {
        bool zeroForOne = target < current;
        bool payToken = zeroForOne == tokenIs0;
        uint256 maxIn = payToken
            ? tokenAvail * MAX_NORMALIZE_TOKEN_BPS / BPS
            : quoteAvail * MAX_NORMALIZE_QUOTE_BPS / BPS;
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
        tokenAvail = (tokenAvail.toInt256() - dToken).toUint256();
        quoteAvail = (quoteAvail.toInt256() - dQuote).toUint256();
        return (tokenAvail, quoteAvail);
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

    /// @dev sqrt(token1/token0) in Q64.96 at the curve's current price (quote per token = vQuote / vToken).
    function _sqrtPriceX96(uint256 vQuote, uint256 vToken, bool tokenIs0) internal pure returns (uint160) {
        uint256 ratioX192 = tokenIs0 ? Math.mulDiv(vQuote, 1 << 192, vToken) : Math.mulDiv(vToken, 1 << 192, vQuote);
        uint256 s = Math.sqrt(ratioX192);
        if (s < TickMath.MIN_SQRT_RATIO || s >= TickMath.MAX_SQRT_RATIO) revert BadConfig();
        return uint160(s);
    }

    function _curve(address token) internal view returns (Curve storage c) {
        c = curves[token];
        if (c.quote == address(0)) revert UnknownLaunch();
    }

    function _pullQuote(address quote, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(quote).balanceOf(address(this)) - before;
    }

    function _refundNative(uint256 amount) internal {
        if (amount == 0) return;
        IWOKB(wokb).withdraw(amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired();
    }

    function _checkConfig(QuoteConfig memory q) internal pure {
        if (
            q.vQuote0 == 0 || q.lpTokens == 0 || q.curveSupply == 0 || q.vToken0 <= q.curveSupply
                || uint256(q.curveSupply) + q.lpTokens != TOTAL_SUPPLY
        ) revert BadConfig();
    }

    /// @dev Position NFTs only arrive from the position manager during our own mint.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(npm)) revert BadCallback();
        return this.onERC721Received.selector;
    }
}
