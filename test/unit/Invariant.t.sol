// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnitBase} from "./Base.t.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

/// @dev Random buys, sells, transfers and claims across a WOKB curve and a BEM curve (stops short of graduation,
/// which needs real Uniswap v3 and is covered by the fork suite).
contract PadHandler is Test {
    CurvePad pad;
    LaunchToken[2] public tokens;
    address[2] public quotes;
    address[3] actors;
    address creator;
    address container0;
    address container1;

    constructor(CurvePad pad_, LaunchToken[2] memory ts, address[2] memory qs, address[3] memory as_, address creator_) {
        pad = pad_;
        tokens = ts;
        quotes = qs;
        actors = as_;
        creator = creator_;
        (,,,,, container0,,,,) = pad.curves(address(ts[0]));
        (,,,,, container1,,,,) = pad.curves(address(ts[1]));
    }

    function buy(uint256 who, uint256 which, uint256 amount) external {
        which %= 2;
        address a = actors[who % 3];
        // Keep each buy well below a full sell-out: <= 30 WOKB / <= 150 BEM.
        amount = bound(amount, 1e4, which == 0 ? 30 ether : 150e8);
        if (IERC20(quotes[which]).balanceOf(a) < amount) return;
        (,,,, uint128 left,,,,,) = pad.curves(address(tokens[which]));
        (uint256 out,) = pad.previewBuy(address(tokens[which]), amount);
        if (out == 0 || out >= left) return; // never trigger graduation here
        vm.prank(a);
        pad.buy(address(tokens[which]), amount, 0, block.timestamp);
    }

    function sell(uint256 who, uint256 which, uint256 frac) external {
        which %= 2;
        address a = actors[who % 3];
        uint256 bal = tokens[which].balanceOf(a);
        uint256 amt = bal * bound(frac, 1, 100) / 100;
        if (amt == 0 || pad.previewSell(address(tokens[which]), amt) == 0) return;
        vm.startPrank(a);
        tokens[which].approve(address(pad), amt);
        pad.sell(address(tokens[which]), amt, 0, block.timestamp);
        vm.stopPrank();
    }

    function transferTokens(uint256 from, uint256 to, uint256 which, uint256 frac) external {
        which %= 2;
        address f = actors[from % 3];
        uint256 amt = tokens[which].balanceOf(f) * bound(frac, 0, 100) / 100;
        vm.prank(f);
        tokens[which].transfer(actors[to % 3], amt);
    }

    function claimFees(uint256 which, uint256 route) external {
        address q = quotes[which % 2];
        route %= 4;
        if (route == 0) pad.claim(q, pad.protocol());
        else if (route == 1) pad.claim(q, pad.sink());
        else {
            vm.prank(creator);
            pad.claimCreator(which % 2 == 0 ? container0 : container1, q, route == 3);
        }
    }

    function roll(uint256 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 10));
    }
}

contract PadInvariantTest is UnitBase {
    PadHandler handler;
    LaunchToken[2] ts;

    function setUp() public override {
        super.setUp();
        ts[0] = _launch(address(wokb));
        ts[1] = _launch(address(bem));
        handler = new PadHandler(
            pad, ts, [address(wokb), address(bem)], [alice, bob, creator], creator
        );
        targetContract(address(handler));
    }

    /// CurvePad's quote balance always covers every curve's real quote plus every accrued (unclaimed) fee.
    function invariant_padSolvent() public view {
        _solvent(address(wokb), ts[0]);
        _solvent(address(bem), ts[1]);
    }

    /// Sum of per-recipient accruals equals the tracked total.
    function invariant_accrualsAddUp() public view {
        for (uint256 i; i < 2; ++i) {
            address q = i == 0 ? address(wokb) : address(bem);
            (,,,,, address c,,,,) = pad.curves(address(ts[i]));
            assertEq(
                pad.accrued(q, c) + pad.accrued(q, protocol) + pad.accrued(q, sink), pad.totalAccrued(q), "accrual sum"
            );
        }
    }

    /// Curve state stays consistent: tokens held by the pad == tokensLeft + LP reserve; vQuote == vQuote0 + realQuote.
    function invariant_curveState() public view {
        for (uint256 i; i < 2; ++i) {
            address q = i == 0 ? address(wokb) : address(bem);
            CurvePad.QuoteConfig memory cfg = pad.quoteConfig(q);
            (, uint128 vQuote, uint128 vToken, uint128 real, uint128 left,,,,,) = pad.curves(address(ts[i]));
            assertEq(vQuote, cfg.vQuote0 + real, "vQuote");
            assertEq(cfg.vToken0 - vToken, cfg.curveSupply - left, "tokens sold");
            assertEq(ts[i].balanceOf(address(pad)), uint256(left) + cfg.lpTokens, "pad token balance");
        }
    }

    function _solvent(address q, LaunchToken t) internal view {
        (,,, uint128 real,,,,,,) = pad.curves(address(t));
        assertGe(IERC20(q).balanceOf(address(pad)), uint256(real) + pad.totalAccrued(q), "solvent");
    }
}
