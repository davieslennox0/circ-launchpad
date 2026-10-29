// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {PositionLocker} from "../../src/PositionLocker.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TickMath} from "../../src/libraries/uniswap/TickMath.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager, IWOKB} from "../../src/interfaces/IUniswapV3.sol";
import {ICircuitNFT, IERC6551Registry} from "../../src/interfaces/ITapeOut.sol";
import {Addresses} from "../../script/Addresses.sol";
import {CurveConstants} from "../../script/CurveConstants.sol";
import {CircDeploy} from "../../script/Deploy.s.sol";

interface IPoolLiquidity {
    function liquidity() external view returns (uint128);
}

/// @dev X Layer mainnet fork against the real Uniswap v3, TapeOut factory, ERC-6551 registry, WOKB and BEM.
/// RPC: $XLAYER_RPC_URL, else the public endpoint. Optional $FORK_BLOCK pins the fork.
abstract contract ForkBase is Test {
    CurvePad pad;
    PositionLocker locker;
    IUniswapV3Factory factory = IUniswapV3Factory(Addresses.V3_FACTORY);
    INonfungiblePositionManager npm = INonfungiblePositionManager(Addresses.NPM);
    IERC20 wokb = IERC20(Addresses.WOKB);
    IERC20 bem = IERC20(Addresses.BEM);

    address creator = Addresses.NANDOUT_HOLDER;
    address protocol = makeAddr("protocol");
    address sink = makeAddr("sink");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    function setUp() public virtual {
        string memory rpc = vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);

        (pad, locker) = CircDeploy.deploy(address(this), protocol, sink);
        assertEq(ICircuitNFT(Addresses.NANDOUT).ownerOf(1), creator, "fixture: Nandout #1 holder");

        address[4] memory users = [alice, bob, attacker, creator];
        for (uint256 i; i < users.length; ++i) {
            vm.deal(users[i], 100_000 ether);
            vm.startPrank(users[i]);
            IWOKB(Addresses.WOKB).deposit{value: 10_000 ether}();
            wokb.approve(address(pad), type(uint256).max);
            bem.approve(address(pad), type(uint256).max);
            vm.stopPrank();
            deal(Addresses.BEM, users[i], 5_000e8);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _launch(address quote, uint256 circuitId) internal returns (LaunchToken t) {
        vm.prank(creator);
        t = LaunchToken(pad.createLaunch(Addresses.NANDOUT, circuitId, "Circ Fork", "CF", quote, 0, 0));
    }

    function _container(uint256 circuitId) internal view returns (address) {
        return IERC6551Registry(Addresses.ERC6551_REGISTRY).account(
            Addresses.CONTAINER_IMPL, bytes32(0), block.chainid, Addresses.NANDOUT, circuitId
        );
    }

    function _vQuote0(address quote) internal pure returns (uint256) {
        return quote == Addresses.WOKB ? CurveConstants.WOKB_V_QUOTE0 : CurveConstants.BEM_V_QUOTE0;
    }

    /// @dev sqrtPriceX96 of the pool when the token trades at (curve end price) * num / den, in quote per token.
    function _sqrtAtMultiple(address token, address quote, uint256 num, uint256 den) internal pure returns (uint160) {
        uint256 k = _vQuote0(quote) * uint256(CurveConstants.V_TOKEN0);
        uint256 tEnd = CurveConstants.V_TOKEN0 - CurveConstants.CURVE_SUPPLY;
        uint256 qEnd = Math.mulDiv(k, 1, tEnd, Math.Rounding.Ceil);
        uint256 ratioX192 = token < quote
            ? Math.mulDiv(qEnd * num, 1 << 192, tEnd * den)
            : Math.mulDiv(tEnd * den, 1 << 192, qEnd * num);
        return uint160(Math.sqrt(ratioX192));
    }

    /// @dev Buys until the curve sells out; returns the Graduated event's position id and pool.
    function _graduate(LaunchToken t, address buyer) internal returns (uint256 positionId, address pool) {
        (,,,, uint128 left,,,,,) = pad.curves(address(t));
        (address quote,,,,,,,,,) = pad.curves(address(t));
        (, uint256 need) = pad.previewBuy(address(t), type(uint128).max);
        assertGt(left, 0);
        vm.recordLogs();
        vm.prank(buyer);
        pad.buy(address(t), need, 0, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Graduated(address,address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == sig) {
                pool = address(uint160(uint256(logs[i].topics[2])));
                (positionId,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertTrue(pool != address(0), "graduated");
        assertEq(pool, factory.getPool(address(t), quote, 10_000));
    }

    function _positionLiquidity(uint256 positionId) internal view returns (uint128 liq) {
        (,,,,,,, liq,,,,) = npm.positions(positionId);
    }

    /// @dev CurvePad must always hold at least every curve's real quote plus all accrued fees.
    function _assertSolvent(LaunchToken[] memory ts, address quote) internal view {
        uint256 owed = pad.totalAccrued(quote);
        for (uint256 i; i < ts.length; ++i) {
            (address q,,, uint128 real,,,,,,) = pad.curves(address(ts[i]));
            if (q == quote) owed += real;
        }
        assertGe(IERC20(quote).balanceOf(address(pad)), owed, "pad solvent");
    }

    // Direct pool swaps from the test contract (no router dependency).
    address internal _swapping;

    function _poolSwap(address pool, address tokenIn, uint256 amountIn) internal {
        bool zeroForOne = tokenIn == _token0(pool);
        _swapping = pool;
        IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(tokenIn)
        );
        _swapping = address(0);
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        require(msg.sender == _swapping, "cb");
        address tokenIn = abi.decode(data, (address));
        IERC20(tokenIn).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }

    function _token0(address pool) internal view returns (address t0) {
        (bool ok, bytes memory r) = pool.staticcall(abi.encodeWithSignature("token0()"));
        require(ok);
        t0 = abi.decode(r, (address));
    }
}
