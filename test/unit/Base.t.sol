// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {PositionLocker} from "../../src/PositionLocker.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
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
    address npm;

    address constant V3_FACTORY = address(0xF4C7); // only used to derive the predicted pool in unit tests
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
        npm = address(new MockNPM());
        cfactory.setCPU(address(nft), true);
        nft.mint(creator, 1);
        nft.mint(creator, 2);
        fakeNft.mint(creator, 1);

        address predictedPad = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        locker = new PositionLocker(INonfungiblePositionManager(npm), predictedPad, protocol, sink);
        pad = new CurvePad(
            CurvePad.Params({
                wokb: address(wokb),
                bem: address(bem),
                wokbConfig: CurveConstants.wokb(),
                bemConfig: CurveConstants.bem(),
                circuitFactory: address(cfactory),
                registry: address(registry),
                containerImpl: IMPL,
                v3Factory: V3_FACTORY,
                npm: npm,
                locker: address(locker),
                protocol: protocol,
                sink: sink
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
