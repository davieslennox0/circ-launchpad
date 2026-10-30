// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {PositionLocker} from "../../src/PositionLocker.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {PoolKey, IPositionManager, IAllowanceTransfer, IWOKB} from "../../src/interfaces/IUniswapV4.sol";
import {ICircuitNFT, IERC6551Registry} from "../../src/interfaces/ITapeOut.sol";
import {Addresses} from "../../script/Addresses.sol";
import {CurveConstants} from "../../script/CurveConstants.sol";
import {CircDeploy} from "../../script/Deploy.s.sol";

interface IStateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev v4-periphery IV4Router.ExactInputSingleParams at the commit Universal Router 2.1.x pins (a7af5b3).
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/// @dev X Layer mainnet fork against the real Uniswap v4 (PoolManager, PositionManager, Permit2, Universal Router 2.1.2),
/// TapeOut factory, ERC-6551 registry, WOKB and BEM. RPC: $XLAYER_RPC_URL, else the public endpoint. Optional
/// $FORK_BLOCK pins the fork.
abstract contract ForkBase is Test {
    CurvePad pad;
    PositionLocker locker;
    IPositionManager posm = IPositionManager(Addresses.POSITION_MANAGER);
    IStateView stateView = IStateView(Addresses.STATE_VIEW);
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

        // Fresh deployer, so the locker and pad land on addresses that can't already hold mainnet funds.
        // (Forge's default sender deploys to 0x5615...b72f, which holds 0.12 WOKB on X Layer.)
        address deployer = makeAddr("circDeployer");
        vm.startPrank(deployer);
        (pad, locker) = CircDeploy.deploy(deployer, protocol, sink);
        vm.stopPrank();
        address[5] memory fresh = [
            address(pad),
            address(locker),
            address(pad.graduator()),
            address(pad.tokenDeployer()),
            address(pad.hook())
        ];
        for (uint256 i; i < fresh.length; ++i) {
            assertEq(wokb.balanceOf(fresh[i]), 0, "fresh deploy holds no WOKB");
            assertEq(bem.balanceOf(fresh[i]), 0, "fresh deploy holds no BEM");
        }
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

    function _key(LaunchToken t) internal view returns (PoolKey memory) {
        (address quote,,,,,,,,,) = pad.curves(address(t));
        return pad.graduator().poolKey(address(t), quote);
    }

    function _poolId(LaunchToken t) internal view returns (bytes32) {
        return keccak256(abi.encode(_key(t)));
    }

    /// @dev The filling buy: sells the rest of the curve, which must leave it Complete (not graduated) with trading closed.
    function _complete(LaunchToken t, address buyer) internal {
        (,,,, uint128 left,,,,,) = pad.curves(address(t));
        assertGt(left, 0);
        (, uint256 need) = pad.previewBuy(address(t), type(uint128).max);
        vm.expectEmit(true, false, false, false, address(pad));
        emit CurvePad.CurveCompleted(address(t));
        vm.prank(buyer);
        pad.buy(address(t), need, 0, block.timestamp);

        CurvePad.Status st;
        (,,,, left,,,,, st) = pad.curves(address(t));
        assertEq(left, 0);
        assertEq(uint8(st), uint8(CurvePad.Status.Complete), "filling buy -> Complete");
        (uint160 sqrtP,,,) = stateView.getSlot0(_poolId(t));
        assertEq(sqrtP, 0, "filling buy does not graduate: pool not initialized");
        vm.prank(bob);
        vm.expectRevert(CurvePad.CurveClosed.selector);
        pad.buy(address(t), 1e6, 0, block.timestamp);
        vm.startPrank(buyer);
        t.approve(address(pad), 1 ether);
        vm.expectRevert(CurvePad.CurveClosed.selector);
        pad.sell(address(t), 1 ether, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Permissionless graduate() by a third-party keeper; returns the Graduated event's position id and pool id.
    function _graduateNow(LaunchToken t) internal returns (uint256 positionId, bytes32 poolId) {
        (address quote,,,,,,,,,) = pad.curves(address(t));
        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        pad.graduate(address(t));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Graduated(address,bytes32,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == sig) {
                poolId = logs[i].topics[2];
                (positionId,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertTrue(poolId != bytes32(0), "graduated");
        assertEq(poolId, _poolId(t), "graduated into the CircHook pool");
        (,,,,,,,,, CurvePad.Status st) = pad.curves(address(t));
        assertEq(uint8(st), uint8(CurvePad.Status.Graduated));
        _assertGraduatorEmpty(address(t), quote);
        vm.expectRevert(CurvePad.AlreadyGraduated.selector);
        pad.graduate(address(t));
    }

    /// @dev Filling buy, then graduate().
    function _graduate(LaunchToken t, address buyer) internal returns (uint256 positionId, bytes32 poolId) {
        _complete(t, buyer);
        return _graduateNow(t);
    }

    /// @dev Graduator must hold nothing between calls.
    function _assertGraduatorEmpty(address token, address quote) internal view {
        address g = address(pad.graduator());
        assertEq(IERC20(token).balanceOf(g), 0, "graduator token balance");
        assertEq(IERC20(quote).balanceOf(g), 0, "graduator quote balance");
        assertEq(IERC20(Addresses.WOKB).balanceOf(g), 0, "graduator WOKB balance");
        assertEq(IERC20(Addresses.BEM).balanceOf(g), 0, "graduator BEM balance");
        assertEq(g.balance, 0, "graduator native balance");
        (bool ok, bytes memory r) = address(posm).staticcall(abi.encodeWithSignature("balanceOf(address)", g));
        require(ok);
        assertEq(abi.decode(r, (uint256)), 0, "graduator holds no position NFT");
    }

    /// @dev Pool price check: the pool's sqrt price squared vs the curve's final vQuote / vToken, within `relE18`.
    function _assertOpensAtCurvePrice(LaunchToken t, bytes32 poolId, uint256 relE18) internal view {
        (address quote, uint128 vQuote, uint128 vToken,,,,,,,) = pad.curves(address(t));
        uint256 expectX192 =
            address(t) < quote ? Math.mulDiv(vQuote, 1 << 192, vToken) : Math.mulDiv(vToken, 1 << 192, vQuote);
        (uint160 sqrtP,,,) = stateView.getSlot0(poolId);
        assertApproxEqRel(Math.mulDiv(sqrtP, sqrtP, 1), expectX192, relE18, "pool price ~ P_end");
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

    /// @dev Exact-in single-hop swap through Universal Router 2.1.2 (V4_SWAP: SWAP_EXACT_IN_SINGLE, SETTLE_ALL,
    /// TAKE_ALL), paid via Permit2. Returns the amount of the other currency received.
    function _routerSwap(address who, PoolKey memory key, address tokenIn, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        bool zeroForOne = tokenIn == key.currency0;
        address tokenOut = zeroForOne ? key.currency1 : key.currency0;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, uint128(amountIn), 0, 0, bytes("")));
        params[1] = abi.encode(tokenIn, amountIn);
        params[2] = abi.encode(tokenOut, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);

        uint256 before = IERC20(tokenOut).balanceOf(who);
        vm.startPrank(who);
        IERC20(tokenIn).approve(Addresses.PERMIT2, type(uint256).max);
        IAllowanceTransfer(Addresses.PERMIT2).approve(
            tokenIn, Addresses.UNIVERSAL_ROUTER, uint160(amountIn), uint48(block.timestamp + 1 hours)
        );
        IUniversalRouter(Addresses.UNIVERSAL_ROUTER).execute(
            abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 1 hours
        );
        vm.stopPrank();
        out = IERC20(tokenOut).balanceOf(who) - before;
    }
}
