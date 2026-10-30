// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UnitBase} from "./Base.t.sol";
import {MockNPM} from "./Mocks.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {FeeVault} from "../../src/FeeVault.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TokenDeployer} from "../../src/TokenDeployer.sol";
import {Graduator} from "../../src/Graduator.sol";
import {CircHook} from "../../src/CircHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {PositionLocker} from "../../src/PositionLocker.sol";
import {CurveConstants} from "../../script/CurveConstants.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

contract CurvePadUnitTest is UnitBase {
    // ------------------------------------------------------------- create

    function test_create_bindsCircuitAndContainer() public {
        LaunchToken t = _launch(address(wokb));
        (address q,,,,, address container, address cnft, uint256 cid, uint64 lb, CurvePad.Status g) = pad.curves(address(t));
        assertEq(q, address(wokb));
        assertEq(container, _container(1));
        assertEq(cnft, address(nft));
        assertEq(cid, 1);
        assertEq(lb, block.number);
        assertEq(uint8(g), uint8(CurvePad.Status.Trading));
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

    function test_token_noOwnerNoMintNoRestrictions() public {
        LaunchToken t = _launch(address(wokb));
        (bool ok,) = address(t).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(t).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        _skipGuard();
        vm.prank(alice);
        uint256 got = pad.buy(address(t), 1 ether, 0, block.timestamp);
        vm.prank(alice);
        t.transfer(bob, got); // plain ERC-20: no transfer restrictions
        assertEq(t.balanceOf(bob), got);
        vm.prank(bob);
        t.burn(1);
        assertEq(t.totalSupply(), 1e27 - 1);
    }

    // ------------------------------------------------------------- config

    function test_constructorRejectsBadSupplySplit() public {
        CurvePad.QuoteConfig memory bad = CurveConstants.wokb();
        bad.lpTokens += 1;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PositionLocker2 l = new PositionLocker2(posm, predicted);
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
                POOL_MANAGER,
                posm,
                PERMIT2,
                address(l),
                protocol,
                sink,
                bytes32(0)
            )
        );
    }

    function test_receiveRejectsStrangers() public {
        vm.prank(alice);
        (bool ok,) = address(pad).call{value: 1}("");
        assertFalse(ok);
    }

    function test_antiSnipe_capIsCurveWidePerBlock_multiWallet() public {
        LaunchToken t = _launch(address(wokb));
        uint256 cap = pad.MAX_EARLY_BUY();
        vm.prank(alice);
        pad.buy(address(t), 0.1 ether, 0, block.timestamp); // ~2.8M tokens at the launch price: under the 5M (0.5%) cap
        uint256 a = t.balanceOf(alice);
        assertLt(a, cap);
        vm.prank(bob);
        pad.buy(address(t), 50 ether, 0, block.timestamp); // capped at what's left of this block's allowance
        assertEq(a + t.balanceOf(bob), cap, "alice + bob == one block's cap");
        vm.prank(creator);
        vm.expectRevert(CurvePad.EarlyBlockCapReached.selector);
        pad.buy(address(t), 1 ether, 0, block.timestamp);

        vm.roll(block.number + 1); // fresh allowance next block, still inside the guard window
        vm.prank(creator);
        pad.buy(address(t), 50 ether, 0, block.timestamp);
        assertEq(t.balanceOf(creator), cap);
    }

    function test_antiSnipe_batchedBuysInOneTxCapped() public {
        LaunchToken t = _launch(address(wokb));
        BatchBuyer bb = new BatchBuyer(pad, address(wokb));
        vm.prank(alice);
        wokb.transfer(address(bb), 1_000 ether);
        bb.buyMany(address(t), 100, 1 ether); // 100 sequential buys in one tx, same block
        assertEq(t.balanceOf(address(bb)), pad.MAX_EARLY_BUY(), "batch can't exceed the block cap");
        (uint64 blk, uint192 sold) = pad.earlyBlock(address(t));
        assertEq(blk, block.number);
        assertEq(sold, pad.MAX_EARLY_BUY());
    }

    function test_antiSnipe_devBuyNotCounted() public {
        vm.prank(creator);
        LaunchToken t = LaunchToken(pad.createLaunch{value: 20 ether}(address(nft), 1, "X", "X", address(wokb), 0, 0));
        assertGt(t.balanceOf(creator), pad.MAX_EARLY_BUY());
        vm.prank(alice);
        pad.buy(address(t), 50 ether, 0, block.timestamp);
        assertEq(t.balanceOf(alice), pad.MAX_EARLY_BUY(), "dev-buy didn't use up the launch block's allowance");
    }

    function test_antiSnipe_liftsAfterGuard() public {
        LaunchToken t = _launch(address(wokb));
        _skipGuard();
        vm.prank(alice);
        pad.buy(address(t), 50 ether, 0, block.timestamp);
        vm.prank(bob);
        pad.buy(address(t), 50 ether, 0, block.timestamp);
        assertGt(t.balanceOf(alice) + t.balanceOf(bob), 2 * pad.MAX_EARLY_BUY());
    }

    // ------------------------------------------------------------- completion

    function _fill(LaunchToken t, address who) internal returns (uint256 spent) {
        _skipGuard();
        (, uint256 need) = pad.previewBuy(address(t), type(uint128).max);
        address q = _quoteOf(t);
        uint256 before = IERC20Like(q).balanceOf(who);
        vm.prank(who);
        pad.buy(address(t), need * 2, 0, block.timestamp); // overshoot: excess refunded
        spent = before - IERC20Like(q).balanceOf(who);
        assertEq(spent, need, "capped buy spends exactly the remaining curve");
    }

    function _quoteOf(LaunchToken t) internal view returns (address q) {
        (q,,,,,,,,,) = pad.curves(address(t));
    }

    function test_fillingBuy_marksCompleteAndDoesNotGraduate() public {
        LaunchToken t = _launch(address(wokb));
        vm.expectEmit(true, false, false, false, address(pad));
        emit CurvePad.CurveCompleted(address(t));
        _fill(t, alice);
        (,, uint256 real, uint256 left, CurvePad.Status st) = _curve(address(t));
        assertEq(left, 0);
        assertEq(uint8(st), uint8(CurvePad.Status.Complete));
        assertEq(t.balanceOf(address(pad)), CurveConstants.LP_TOKENS, "LP reserve still in the pad");
        assertGe(wokb.balanceOf(address(pad)), real + pad.totalAccrued(address(wokb)), "funds stay in the pad");
        assertEq(t.balanceOf(alice), CurveConstants.CURVE_SUPPLY);
    }

    function test_complete_tradesRevert() public {
        LaunchToken t = _launch(address(wokb));
        _fill(t, alice);
        vm.startPrank(bob);
        vm.expectRevert(CurvePad.CurveClosed.selector);
        pad.buy(address(t), 1 ether, 0, block.timestamp);
        vm.expectRevert(CurvePad.CurveClosed.selector);
        pad.buyWithOKB{value: 1 ether}(address(t), 0, block.timestamp);
        vm.stopPrank();
        vm.startPrank(alice);
        t.approve(address(pad), 1 ether);
        vm.expectRevert(CurvePad.CurveClosed.selector);
        pad.sell(address(t), 1 ether, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_bem_fillingBuy_marksComplete() public {
        LaunchToken t = _launch(address(bem));
        _fill(t, alice);
        (,,,, CurvePad.Status st) = _curve(address(t));
        assertEq(uint8(st), uint8(CurvePad.Status.Complete));
    }

    function test_devBuyCanCompleteCurve() public {
        vm.prank(creator);
        LaunchToken t =
            LaunchToken(pad.createLaunch{value: 1_000 ether}(address(nft), 1, "X", "X", address(wokb), 0, 0));
        (,,, uint256 left, CurvePad.Status st) = _curve(address(t));
        assertEq(left, 0);
        assertEq(uint8(st), uint8(CurvePad.Status.Complete));
    }

    function test_graduate_requiresComplete() public {
        LaunchToken t = _launch(address(wokb));
        vm.expectRevert(CurvePad.NotComplete.selector);
        pad.graduate(address(t));
        vm.expectRevert(CurvePad.UnknownLaunch.selector);
        pad.graduate(address(0xdead));
    }

    // ------------------------------------------------------------- helpers wiring

    function test_helpers_deployedAndOwnedByPad() public view {
        TokenDeployer d = pad.tokenDeployer();
        Graduator g = pad.graduator();
        CircHook h = pad.hook();
        assertEq(d.pad(), address(pad));
        assertEq(g.pad(), address(pad));
        assertEq(address(g.poolManager()), POOL_MANAGER);
        assertEq(address(g.positionManager()), posm);
        assertEq(address(g.permit2()), PERMIT2);
        assertEq(address(g.hook()), address(h));
        assertEq(g.locker(), address(locker));
        assertEq(h.graduator(), address(g));
        assertEq(h.poolManager(), POOL_MANAGER);
        assertEq(h.positionManager(), posm);
        uint160 a = uint160(address(h));
        assertEq(a & ((1 << 14) - 1), (1 << 13) | (1 << 11), "hook flags: beforeInitialize + beforeAddLiquidity only");
        assertTrue(a >> 152 != 0x91, "not on the 0x91 manual-review prefix");
    }

    function test_constructorRejectsBadHookSalt() public {
        // A salt that doesn't produce the flag bits must be refused.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PositionLocker2 l = new PositionLocker2(posm, predicted);
        (bytes32 good,) = HookMiner.mine(predicted, POOL_MANAGER, posm);
        vm.expectRevert(CurvePad.BadHookAddress.selector);
        new CurvePad(
            CurvePad.Params(
                address(wokb),
                address(bem),
                CurveConstants.wokb(),
                CurveConstants.bem(),
                address(cfactory),
                address(registry),
                IMPL,
                POOL_MANAGER,
                posm,
                PERMIT2,
                address(l),
                protocol,
                sink,
                bytes32(uint256(good) + 1)
            )
        );
    }

    function test_constructorRejectsMismatchedV4Wiring() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        address wrongPosm = address(new MockNPM(address(0xBAD), PERMIT2)); // posm wired to another PoolManager
        PositionLocker2 l = new PositionLocker2(wrongPosm, predicted);
        vm.expectRevert(CurvePad.BadConfig.selector);
        new CurvePad(
            CurvePad.Params(
                address(wokb),
                address(bem),
                CurveConstants.wokb(),
                CurveConstants.bem(),
                address(cfactory),
                address(registry),
                IMPL,
                POOL_MANAGER,
                wrongPosm,
                PERMIT2,
                address(l),
                protocol,
                sink,
                bytes32(0)
            )
        );
    }

    function test_constructorRejectsUnrepresentableGraduationPrice() public {
        CurvePad.QuoteConfig memory bad = CurveConstants.wokb();
        // 1 wei of virtual quote: P_end is so small that the inverse ordering's price doesn't fit Q64.96 at all. The
        // constructor refuses it (range check, or overflow while computing it); either way no deploy.
        bad.vQuote0 = 1;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PositionLocker2 l = new PositionLocker2(posm, predicted);
        vm.expectRevert();
        new CurvePad(
            CurvePad.Params(
                address(wokb),
                address(bem),
                bad,
                CurveConstants.bem(),
                address(cfactory),
                address(registry),
                IMPL,
                POOL_MANAGER,
                posm,
                PERMIT2,
                address(l),
                protocol,
                sink,
                bytes32(0)
            )
        );
    }

    function test_tokenDeployer_onlyPad() public {
        TokenDeployer d = pad.tokenDeployer();
        vm.prank(alice);
        vm.expectRevert(TokenDeployer.OnlyPad.selector);
        d.deploy(bytes32(0), "X", "X");
    }

    function test_graduator_onlyPad() public {
        Graduator g = pad.graduator();
        vm.prank(alice);
        vm.expectRevert(Graduator.OnlyPad.selector);
        g.graduate(address(1), address(wokb), 1, 1, 0, 0, "");
    }

    function test_token_supplyToPad_andAddressFromDeployer() public {
        LaunchToken t = _launch(address(wokb));
        assertEq(t.balanceOf(address(pad)), 1e27, "full supply minted to pad");
        bytes32 salt = keccak256(abi.encode(creator, address(nft), uint256(1)));
        bytes memory init = abi.encodePacked(type(LaunchToken).creationCode, abi.encode("Circ Test", "CT", address(pad)));
        assertEq(address(t), vm.computeCreate2Address(salt, keccak256(init), address(pad.tokenDeployer())));
    }

    function test_locker_rejectsNftsNotFromGraduator() public {
        bytes memory data = abi.encode(address(1), address(2), address(nft), uint256(1), address(3), address(4));
        vm.prank(posm);
        vm.expectRevert(PositionLocker.NotPad.selector);
        locker.onERC721Received(address(pad), address(pad), 1, data);
        address g = address(pad.graduator()); // resolve before prank: an external call would consume it
        vm.prank(alice);
        vm.expectRevert(PositionLocker.NotPad.selector);
        locker.onERC721Received(g, g, 1, data); // right operator, wrong NFT contract
        vm.prank(posm);
        locker.onERC721Received(g, g, 1, data);
        assertEq(locker.containerOf(1), address(2));
        (address c, address c0, address c1) = locker.locks(1);
        assertEq(c, address(2));
        assertEq(c0, address(3));
        assertEq(c1, address(4));
    }
}

/// @dev Minimal stand-in exposing pad()/positionManager() so the constructor reaches the config check.
contract PositionLocker2 {
    address public positionManager;
    address public pad;

    constructor(address n, address p) {
        positionManager = n;
        pad = p;
    }
}

/// @dev Splits one large buy into many sequential buys inside a single transaction.
contract BatchBuyer {
    CurvePad immutable pad;
    address immutable quote;

    constructor(CurvePad pad_, address quote_) {
        pad = pad_;
        quote = quote_;
    }

    function buyMany(address token, uint256 n, uint256 each) external {
        IApprove(quote).approve(address(pad), type(uint256).max);
        for (uint256 i; i < n; ++i) {
            try pad.buy(token, each, 0, block.timestamp) {} catch {}
        }
    }
}

interface IApprove {
    function approve(address, uint256) external returns (bool);
}
