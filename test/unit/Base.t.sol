// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {PositionLocker} from "../../src/PositionLocker.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {IPositionManager} from "../../src/interfaces/IUniswapV4.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {CurveConstants} from "../../script/CurveConstants.sol";
import "./Mocks.sol";

abstract contract UnitBase is Test {
    CurvePad pad;
    PositionLocker locker;
    MockCircuitFactory cfactory;
    MockCircuitNFT nft;
    MockCircuitNFT fakeNft;
    MockRegistry registry;
    MockWOKB wokb;
    MockQuote bem;
    address posm;

    // v4 stand-ins: graduation itself needs real Uniswap v4 and is covered by the fork suite.
    address constant POOL_MANAGER = address(0xF4C7);
    address constant PERMIT2 = address(0x9E2);
    address constant IMPL = address(0x1111);
    address protocol = makeAddr("protocol");
    address sink = makeAddr("sink");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        cfactory = new MockCircuitFactory();
        nft = new MockCircuitNFT();
        fakeNft = new MockCircuitNFT();
        registry = new MockRegistry();
        wokb = new MockWOKB();
        bem = new MockQuote("BEM", 8);
        posm = address(new MockNPM(POOL_MANAGER, PERMIT2));
        cfactory.setCPU(address(nft), true);
        nft.mint(creator, 1);
        nft.mint(creator, 2);
        fakeNft.mint(creator, 1);

        address predictedPad = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        (bytes32 hookSalt,) = HookMiner.mine(predictedPad, POOL_MANAGER, posm);
        locker = new PositionLocker(IPositionManager(posm), predictedPad, protocol, sink);
        pad = new CurvePad(
            CurvePad.Params({
                wokb: address(wokb),
                bem: address(bem),
                wokbConfig: CurveConstants.wokb(),
                bemConfig: CurveConstants.bem(),
                circuitFactory: address(cfactory),
                registry: address(registry),
                containerImpl: IMPL,
                poolManager: POOL_MANAGER,
                positionManager: posm,
                permit2: PERMIT2,
                locker: address(locker),
                protocol: protocol,
                sink: sink,
                hookSalt: hookSalt
            })
        );
        assertEq(address(pad), predictedPad);

        for (uint256 i; i < 3; ++i) {
            address u = [creator, alice, bob][i];
            vm.deal(u, 1_000_000 ether);
            bem.mint(u, 1e8 * 1e8);
            vm.startPrank(u);
            wokb.deposit{value: 100_000 ether}();
            wokb.approve(address(pad), type(uint256).max);
            bem.approve(address(pad), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _launch(address quote) internal returns (LaunchToken t) {
        vm.prank(creator);
        t = LaunchToken(pad.createLaunch(address(nft), quote == address(wokb) ? 1 : 2, "Circ Test", "CT", quote, 0, 0));
    }

    function _container(uint256 id) internal view returns (address) {
        return registry.account(IMPL, bytes32(0), block.chainid, address(nft), id);
    }

    function _curve(address token)
        internal
        view
        returns (uint256 vQuote, uint256 vToken, uint256 realQuote, uint256 tokensLeft, CurvePad.Status status)
    {
        address q;
        uint128 a;
        uint128 b;
        uint128 r;
        uint128 l;
        (q, a, b, r, l,,,,, status) = pad.curves(token);
        return (a, b, r, l, status);
    }

    function _skipGuard() internal {
        vm.roll(block.number + pad.GUARD_BLOCKS());
    }
}
