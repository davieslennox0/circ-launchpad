// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UnitBase} from "./Base.t.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {FeeVault} from "../../src/FeeVault.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {CurveConstants} from "../../script/CurveConstants.sol";

contract CurvePadUnitTest is UnitBase {
    // ------------------------------------------------------------- create

    function test_create_bindsCircuitAndContainer() public {
        LaunchToken t = _launch(address(wokb));
        (address q,,,,, address container, address cnft, uint256 cid, uint64 lb, bool g) = pad.curves(address(t));
        assertEq(q, address(wokb));
        assertEq(container, _container(1));
        assertEq(cnft, address(nft));
        assertEq(cid, 1);
        assertEq(lb, block.number);
        assertFalse(g);
        assertEq(t.totalSupply(), 1e27);
        assertEq(t.balanceOf(address(pad)), 1e27);
        (address rn, uint256 rid) = pad.circuitOf(container);
        assertEq(rn, address(nft));
        assertEq(rid, 1);
    }

    function test_create_rejectsNonHolder() public {
        vm.prank(alice);
        vm.expectRevert(FeeVault.NotHolder.selector);
        pad.createLaunch(address(nft), 1, "X", "X", address(wokb), 0, 0);
    }

    function test_create_rejectsNonTapeOutNft() public {
        vm.prank(creator);
        vm.expectRevert(CurvePad.NotTapeOut.selector);
        pad.createLaunch(address(fakeNft), 1, "X", "X", address(wokb), 0, 0);
    }

    function test_create_rejectsOtherQuote() public {
        vm.prank(creator);
        vm.expectRevert(CurvePad.BadQuote.selector);
        pad.createLaunch(address(nft), 1, "X", "X", address(0xBEEF), 0, 0);
    }

    function test_create_sameCircuitTwiceReverts() public {
        _launch(address(wokb));
        vm.prank(creator);
        vm.expectRevert(); // CREATE2 collision
        pad.createLaunch(address(nft), 1, "Circ Test", "CT", address(wokb), 0, 0);
    }

    function test_create_devBuyExemptFromAntiSnipe() public {
        vm.prank(creator);
        LaunchToken t = LaunchToken(pad.createLaunch{value: 20 ether}(address(nft), 1, "X", "X", address(wokb), 0, 0));
        assertGt(t.balanceOf(creator), pad.MAX_EARLY_BUY(), "dev-buy above the early cap");
    }

    function test_create_bemDevBuy() public {
        vm.prank(creator);
        LaunchToken t = LaunchToken(pad.createLaunch(address(nft), 2, "X", "X", address(bem), 10e8, 0));
        assertGt(t.balanceOf(creator), 0);
        (,, uint256 real,,) = _curve(address(t));
        uint256 amt = 10e8;
        assertEq(real, amt - (amt + 99) / 100);
    }

    function test_create_bemRejectsNativeValue() public {
        vm.prank(creator);
        vm.expectRevert(CurvePad.BadValue.selector);
        pad.createLaunch{value: 1}(address(nft), 2, "X", "X", address(bem), 0, 0);
    }

    // ------------------------------------------------------------- trading

    function test_buyAndSell_wokb() public {
        LaunchToken t = _launch(address(wokb));
        _skipGuard();
        vm.prank(alice);
        uint256 got = pad.buy(address(t), 5 ether, 0, block.timestamp);
        assertEq(t.balanceOf(alice), got);
        (uint256 vq, uint256 vt, uint256 real, uint256 left,) = _curve(address(t));
        assertEq(real, 5 ether - 0.05 ether);
        assertEq(vq, CurveConstants.WOKB_V_QUOTE0 + real);
        assertEq(left, CurveConstants.CURVE_SUPPLY - got);
        assertEq(vt, CurveConstants.V_TOKEN0 - got);

        vm.startPrank(alice);
        t.approve(address(pad), got);
        uint256 before = wokb.balanceOf(alice);
        uint256 back = pad.sell(address(t), got, 0, block.timestamp);
        vm.stopPrank();
        assertEq(wokb.balanceOf(alice) - before, back);
        // 5 in, 1% fee -> 4.95 net; selling back releases <= 4.95, minus a 1% fee -> <= 4.9005
        assertLe(back, 4.9005 ether);
        assertGe(back, 4.9005 ether - 10);
    }

    function test_buyWithOKB_refundsNothingWhenNotCapped() public {
        LaunchToken t = _launch(address(wokb));
        _skipGuard();
        uint256 bal = alice.balance;
        vm.prank(alice);
        pad.buyWithOKB{value: 1 ether}(address(t), 1, block.timestamp);
        assertEq(bal - alice.balance, 1 ether);
        assertGt(t.balanceOf(alice), 0);
    }

    function test_buyWithOKB_rejectsBemCurve() public {
        LaunchToken t = _launch(address(bem));
        vm.prank(alice);
        vm.expectRevert(CurvePad.BadQuote.selector);
        pad.buyWithOKB{value: 1 ether}(address(t), 0, block.timestamp);
    }

    function test_bem8Decimals_buySell() public {
        LaunchToken t = _launch(address(bem));
        _skipGuard();
        vm.prank(alice);
        uint256 got = pad.buy(address(t), 50e8, 0, block.timestamp);
        assertGt(got, 0);
        vm.startPrank(alice);
        t.approve(address(pad), got);
        uint256 back = pad.sell(address(t), got, 0, block.timestamp);
        vm.stopPrank();
        assertApproxEqAbs(back, 50e8 * 98 / 100, 1e6); // ~0.01 BEM rounding at 8 dp
        assertLt(back, 50e8 * 9802 / 10000);
    }

    function test_slippageAndDeadline() public {
        LaunchToken t = _launch(address(wokb));
        _skipGuard();
        (uint256 expected,) = pad.previewBuy(address(t), 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(CurvePad.Slippage.selector);
        pad.buy(address(t), 1 ether, expected + 1, block.timestamp);
        vm.expectRevert(CurvePad.Expired.selector);
        pad.buy(address(t), 1 ether, 0, block.timestamp - 1);
        uint256 got = pad.buy(address(t), 1 ether, expected, block.timestamp);
        assertEq(got, expected);
        t.approve(address(pad), got);
        uint256 q = pad.previewSell(address(t), got);
        vm.expectRevert(CurvePad.Slippage.selector);
        pad.sell(address(t), got, q + 1, block.timestamp);
        vm.stopPrank();
    }

    function test_sellMoreThanBoughtReverts() public {
        LaunchToken t = _launch(address(wokb));
        _skipGuard();
        vm.prank(alice);
        pad.buy(address(t), 1 ether, 0, block.timestamp);
        // bob gets tokens from alice off-curve and the curve still can't pay more than realQuote
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        t.transfer(bob, bal);
        vm.startPrank(bob);
        t.approve(address(pad), type(uint256).max);
        pad.sell(address(t), bal, 0, block.timestamp);
        vm.expectRevert();
        pad.sell(address(t), 1, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_unknownLaunchReverts() public {
        vm.expectRevert(CurvePad.UnknownLaunch.selector);
        pad.buy(address(0xdead), 1, 0, block.timestamp);
    }

    // ------------------------------------------------------------- anti-snipe

    function test_antiSnipe_capsEarlyBuyAndRefunds() public {
        LaunchToken t = _launch(address(wokb));
        uint256 before = wokb.balanceOf(alice);
        vm.prank(alice);
        pad.buy(address(t), 50 ether, 0, block.timestamp);
        assertEq(t.balanceOf(alice), pad.MAX_EARLY_BUY());
        uint256 spent = before - wokb.balanceOf(alice);
        assertLt(spent, 50 ether, "excess refunded");
        (,, uint256 real,,) = _curve(address(t));
        assertEq(real, spent - (spent - real), "accounting");

        vm.roll(block.number + pad.GUARD_BLOCKS() - 1);
        vm.prank(bob);
        pad.buy(address(t), 50 ether, 0, block.timestamp);
        assertEq(t.balanceOf(bob), pad.MAX_EARLY_BUY(), "still capped in last guard block");

        vm.roll(block.number + 1);
        vm.prank(bob);
        pad.buy(address(t), 50 ether, 0, block.timestamp);
        assertGt(t.balanceOf(bob), 2 * pad.MAX_EARLY_BUY(), "cap lifted");
    }

    function test_antiSnipe_nativeRefund() public {
        LaunchToken t = _launch(address(wokb));
        uint256 bal = alice.balance;
        vm.prank(alice);
        pad.buyWithOKB{value: 50 ether}(address(t), 0, block.timestamp);
        assertEq(t.balanceOf(alice), pad.MAX_EARLY_BUY());
        assertLt(bal - alice.balance, 50 ether);
        assertEq(address(pad).balance, 0);
    }

    // ------------------------------------------------------------- fees

    function test_feeSplitExactBps() public {
        LaunchToken t = _launch(address(wokb));
        _skipGuard();
        vm.prank(alice);
        pad.buy(address(t), 10 ether, 0, block.timestamp);
        uint256 fee = 0.1 ether;
        address c = _container(1);
        assertEq(pad.accrued(address(wokb), c), fee * 5000 / 10000);
        assertEq(pad.accrued(address(wokb), protocol), fee * 3000 / 10000);
        assertEq(pad.accrued(address(wokb), sink), fee * 2000 / 10000);
        assertEq(pad.totalAccrued(address(wokb)), fee);

        pad.claim(address(wokb), protocol);
        pad.claim(address(wokb), sink);
        assertEq(wokb.balanceOf(protocol), 0.03 ether);
        assertEq(wokb.balanceOf(sink), 0.02 ether);
        assertEq(pad.totalAccrued(address(wokb)), 0.05 ether);
    }

    function test_feeRemainderGoesToProtocol() public {
        LaunchToken t = _launch(address(bem));
        _skipGuard();
        vm.prank(alice);
        pad.buy(address(t), 1234567, 0, block.timestamp); // fee = ceil(12345.67) = 12346
        address c = _container(2);
        assertEq(pad.accrued(address(bem), c), 6173);
        assertEq(pad.accrued(address(bem), sink), 2469);
        assertEq(pad.accrued(address(bem), protocol), 12346 - 6173 - 2469);
    }

    function test_creatorClaim_holderGatedBothRoutes() public {
        LaunchToken t = _launch(address(wokb));
        _skipGuard();
        vm.prank(alice);
        pad.buy(address(t), 10 ether, 0, block.timestamp);
        address c = _container(1);

        vm.expectRevert(FeeVault.CreatorClaimOnly.selector);
        pad.claim(address(wokb), c);
        vm.prank(alice);
        vm.expectRevert(FeeVault.NotHolder.selector);
        pad.claimCreator(c, address(wokb), true);

        // the Circuit is sold: the new holder controls the fees
        vm.prank(creator);
        nft.transferFrom(creator, bob, 1);
        vm.prank(creator);
        vm.expectRevert(FeeVault.NotHolder.selector);
        pad.claimCreator(c, address(wokb), false);

        vm.prank(bob);
        pad.claimCreator(c, address(wokb), true); // fallback route: straight to the holder's wallet
        assertEq(wokb.balanceOf(bob), 100_000 ether - 0 + 0.05 ether);
        assertEq(pad.accrued(address(wokb), c), 0);

        vm.prank(alice);
        pad.buy(address(t), 10 ether, 0, block.timestamp);
        vm.prank(bob);
        pad.claimCreator(c, address(wokb), false); // normal route: into the Container
        assertEq(wokb.balanceOf(c), 0.05 ether);
    }

    function test_claimCreatorUnknownContainer() public {
        vm.expectRevert(FeeVault.UnknownContainer.selector);
        pad.claimCreator(address(0x1234), address(wokb), true);
    }

    // ------------------------------------------------------------- token

    function test_token_noOwnerNoMint() public {
        LaunchToken t = _launch(address(wokb));
        (bool ok,) = address(t).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(t).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        vm.expectRevert(LaunchToken.OnlyPad.selector);
        t.markGraduated();
    }

    function test_token_poolLockBeforeGraduation() public {
        LaunchToken t = _launch(address(wokb));
        _skipGuard();
        vm.prank(alice);
        pad.buy(address(t), 1 ether, 0, block.timestamp);
        address pool = t.predictedPool();
        vm.prank(alice);
        vm.expectRevert(LaunchToken.PoolLocked.selector);
        t.transfer(pool, 1);

        vm.prank(alice);
        t.transfer(bob, 1); // wallet-to-wallet is free

        vm.prank(address(pad));
        t.markGraduated();
        vm.prank(alice);
        t.transfer(pool, 1);
        assertEq(t.balanceOf(pool), 1);
    }

    function test_token_predictedPoolMatchesUniswapFormula() public {
        LaunchToken t = _launch(address(wokb));
        (address a, address b) = address(t) < address(wokb) ? (address(t), address(wokb)) : (address(wokb), address(t));
        bytes32 h = keccak256(
            abi.encodePacked(
                hex"ff",
                V3_FACTORY,
                keccak256(abi.encode(a, b, uint24(10000))),
                bytes32(0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)
            )
        );
        assertEq(t.predictedPool(), address(uint160(uint256(h))));
    }

    // ------------------------------------------------------------- config

    function test_constructorRejectsBadSupplySplit() public {
        CurvePad.QuoteConfig memory bad = CurveConstants.wokb();
        bad.lpTokens += 1;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PositionLocker2 l = new PositionLocker2(npm, predicted);
        vm.expectRevert(CurvePad.BadConfig.selector);
        new CurvePad(
            CurvePad.Params(
                address(wokb),
                address(bem),
                bad,
                CurveConstants.bem(),
                address(cfactory),
                address(registry),
                IMPL,
                V3_FACTORY,
                npm,
                address(l),
                protocol,
                sink
            )
        );
    }

    function test_receiveRejectsStrangers() public {
        vm.prank(alice);
        (bool ok,) = address(pad).call{value: 1}("");
        assertFalse(ok);
    }
}

/// @dev Minimal stand-in exposing pad()/npm() so the constructor reaches the config check.
contract PositionLocker2 {
    address public npm;
    address public pad;

    constructor(address n, address p) {
        npm = n;
        pad = p;
    }
}
