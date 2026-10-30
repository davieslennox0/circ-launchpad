// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FeeVault} from "./FeeVault.sol";
import {PositionLocker} from "./PositionLocker.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {TokenDeployer} from "./TokenDeployer.sol";
import {Graduator} from "./Graduator.sol";
import {CircHook} from "./CircHook.sol";
import {ICircuitFactory, ICircuitNFT, IERC6551Registry} from "./interfaces/ITapeOut.sol";
import {IPoolManager, IPositionManager, IAllowanceTransfer, IWOKB} from "./interfaces/IUniswapV4.sol";

/// @title CurvePad
/// @notice Circ launchpad singleton. Every launch is bound to a TapeOut Circuit NFT, trades on a virtual
/// constant-product curve held here, and graduates into a locked full-range Uniswap v4 position (CircHook pool) once the
/// curve sells out. TokenDeployer, CircHook and Graduator are created in the constructor, so the wiring is fixed at deploy.
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

    /// @dev Trading -> Complete (the buy that sells the last curve token) -> Graduated (permissionless `graduate`).
    enum Status {
        Trading,
        Complete,
        Graduated
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
        Status status;
    }

    struct Params {
        address wokb;
        address bem;
        QuoteConfig wokbConfig;
        QuoteConfig bemConfig;
        address circuitFactory;
        address registry;
        address containerImpl;
        address poolManager;
        address positionManager;
        address permit2;
        address locker;
        address protocol;
        address sink;
        /// @dev CREATE2 salt (mined off-chain, see script/HookMiner.sol) giving CircHook an address with exactly the
        /// BEFORE_INITIALIZE and BEFORE_ADD_LIQUIDITY flag bits and no 0x91 prefix.
        bytes32 hookSalt;
    }

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant GUARD_BLOCKS = 5;
    /// @notice During the first GUARD_BLOCKS after launch, at most this many curve tokens can be bought per block, summed
    /// across all buyers (the creator's dev-buy inside createLaunch is exempt and not counted).
    uint256 public constant MAX_EARLY_BUY = TOTAL_SUPPLY / 100;

    address public immutable wokb;
    address public immutable bem;
    ICircuitFactory public immutable circuitFactory;
    IERC6551Registry public immutable registry;
    address public immutable containerImpl;
    address public immutable locker;
    TokenDeployer public immutable tokenDeployer;
    CircHook public immutable hook;
    Graduator public immutable graduator;

    /// @dev Low 14 bits of a v4 hook address are its permission flags: BEFORE_INITIALIZE (1 << 13) | BEFORE_ADD_LIQUIDITY
    /// (1 << 11), nothing else (no swap, donate or delta flags).
    uint160 internal constant HOOK_FLAG_MASK = (1 << 14) - 1;
    uint160 internal constant HOOK_FLAGS = (1 << 13) | (1 << 11);

    uint128 internal immutable wokbVQuote0;
    uint128 internal immutable wokbVToken0;
    uint128 internal immutable wokbCurveSupply;
    uint128 internal immutable wokbLpTokens;
    uint128 internal immutable bemVQuote0;
    uint128 internal immutable bemVToken0;
    uint128 internal immutable bemCurveSupply;
    uint128 internal immutable bemLpTokens;

    mapping(address token => Curve) public curves;

    /// @dev Anti-snipe: curve tokens bought (all buyers combined) in `blockNumber`, tracked only during the guard window.
    struct EarlyBlock {
        uint64 blockNumber;
        uint192 sold;
    }

    mapping(address token => EarlyBlock) public earlyBlock;


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
    /// @notice The curve sold out. Trading is closed; anyone can now call `graduate(token)`.
    event CurveCompleted(address indexed token);
    event Graduated(address indexed token, bytes32 indexed poolId, uint256 positionId, uint256 raised, uint256 lpTokens);

    error BadConfig();
    error BadHookAddress();
    error BadQuote();
    error NotTapeOut();
    error UnknownLaunch();
    error CurveClosed();
    error EarlyBlockCapReached();
    error NotComplete();
    error AlreadyGraduated();
    error Expired();
    error ZeroAmount();
    error Slippage();
    error BadValue();
    error NativeTransferFailed();

    constructor(Params memory p) FeeVault(p.protocol, p.sink) {
        if (
            p.wokb == address(0) || p.bem == address(0) || p.circuitFactory == address(0) || p.registry == address(0)
                || p.containerImpl == address(0) || p.poolManager == address(0) || p.positionManager == address(0)
                || p.permit2 == address(0) || p.locker == address(0)
        ) revert ZeroAddress();
        _checkConfig(p.wokbConfig);
        _checkConfig(p.bemConfig);
        if (
            PositionLocker(p.locker).pad() != address(this)
                || address(PositionLocker(p.locker).positionManager()) != p.positionManager
        ) {
            revert BadConfig();
        }
        wokb = p.wokb;
        bem = p.bem;
        circuitFactory = ICircuitFactory(p.circuitFactory);
        registry = IERC6551Registry(p.registry);
        containerImpl = p.containerImpl;
        locker = p.locker;

        // Creation order fixes the addresses: TokenDeployer (nonce 1), CircHook via CREATE2 (uses nonce 2), Graduator
        // (nonce 3). The hook is built with Graduator's address before Graduator exists, then checked.
        tokenDeployer = new TokenDeployer();
        address graduatorAddr = _createAddress(3);
        hook = new CircHook{salt: p.hookSalt}(graduatorAddr, p.poolManager, p.positionManager);
        uint160 h = uint160(address(hook));
        if (h & HOOK_FLAG_MASK != HOOK_FLAGS || h >> 152 == 0x91) revert BadHookAddress();
        graduator = new Graduator(
            IPoolManager(p.poolManager),
            IPositionManager(p.positionManager),
            IAllowanceTransfer(p.permit2),
            hook,
            p.locker
        );
        if (address(graduator) != graduatorAddr) revert BadConfig();
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
        token = tokenDeployer.deploy(salt, name, symbol);
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
            status: Status.Trading
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
        if (c.status != Status.Trading) revert CurveClosed();
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
        if (c.status != Status.Trading) revert CurveClosed();

        uint256 fee = CurveMath.feeOn(quoteIn);
        uint256 net = quoteIn - fee;
        uint256 out = CurveMath.tokensOut(c.vQuote, c.vToken, net);
        used = quoteIn;

        uint256 cap = c.tokensLeft;
        bool guarded = !exempt && block.number < c.launchBlock + GUARD_BLOCKS;
        uint256 soldThisBlock;
        if (guarded) {
            // Curve-wide per-block cap: every buyer and every call in this block share MAX_EARLY_BUY.
            EarlyBlock memory e = earlyBlock[token];
            if (e.blockNumber == block.number) soldThisBlock = e.sold;
            if (soldThisBlock >= MAX_EARLY_BUY) revert EarlyBlockCapReached();
            if (cap > MAX_EARLY_BUY - soldThisBlock) cap = MAX_EARLY_BUY - soldThisBlock;
        }
        if (out > cap) {
            out = cap;
            net = CurveMath.quoteForTokens(c.vQuote, c.vToken, out);
            used = CurveMath.grossForNet(net);
            fee = used - net;
        }
        if (out == 0) revert ZeroAmount();
        if (out < minTokensOut) revert Slippage();
        if (guarded) earlyBlock[token] = EarlyBlock(uint64(block.number), uint192(soldThisBlock + out));

        c.vQuote += net.toUint128();
        c.vToken -= out.toUint128();
        c.realQuote += net.toUint128();
        c.tokensLeft -= out.toUint128();
        _accrueSplit(c.quote, c.container, fee);

        IERC20(token).safeTransfer(msg.sender, out);
        emit Trade(token, msg.sender, true, used, out, fee, c.vQuote, c.vToken);

        if (c.tokensLeft == 0) {
            c.status = Status.Complete;
            emit CurveCompleted(token);
        }
    }

    /// @notice Graduate a Complete curve into its locked Uniswap v4 position. Permissionless. Nobody else can initialize
    /// or add liquidity to the CircHook pool, so this does not depend on pool state; if it ever reverts, nothing changes
    /// (the curve stays Complete, its funds stay here) and anyone can retry.
    function graduate(address token) external nonReentrant {
        Curve storage c = _curve(token);
        if (c.status == Status.Graduated) revert AlreadyGraduated();
        if (c.status != Status.Complete) revert NotComplete();
        _graduate(token, c);
    }

    /// @dev Unlocks the token, hands the LP tokens and the raise to Graduator for pool setup and the locked mint, and books
    /// whatever quote comes back (normalisation proceeds and rounding) to the protocol.
    function _graduate(address token, Curve storage c) internal {
        c.status = Status.Graduated;
        address quote = c.quote;
        uint256 quoteAmt = c.realQuote;
        c.realQuote = 0;

        uint256 tokenAmt = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(address(graduator), tokenAmt);
        IERC20(quote).safeTransfer(address(graduator), quoteAmt);
        (address c0, address c1) = token < quote ? (token, quote) : (quote, token);
        Graduator.Result memory r = graduator.graduate(
            token,
            quote,
            c.vQuote,
            c.vToken,
            tokenAmt,
            quoteAmt,
            abi.encode(token, c.container, c.circuitNft, c.circuitId, c0, c1)
        );
        _accrueProtocol(quote, r.quoteLeft);
        emit Graduated(token, r.poolId, r.positionId, r.quoteUsed, r.tokenUsed);
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

    /// @dev CREATE address of this contract's `nonce`-th creation (RLP form valid for nonce 1..0x7f).
    function _createAddress(uint8 nonce) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), nonce)))));
    }

    function _checkConfig(QuoteConfig memory q) internal pure {
        if (
            q.vQuote0 == 0 || q.lpTokens == 0 || q.curveSupply == 0 || q.vToken0 <= q.curveSupply
                || uint256(q.curveSupply) + q.lpTokens != TOTAL_SUPPLY
        ) revert BadConfig();
    }
}
