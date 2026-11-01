// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {CurveConstants} from "../../script/CurveConstants.sol";

contract CurveMathTest is Test {
    uint256 constant TOTAL = 1e27;

    function test_constantsSumToSupply() public pure {
        assertEq(uint256(CurveConstants.CURVE_SUPPLY) + CurveConstants.LP_TOKENS, TOTAL);
        assertGt(CurveConstants.V_TOKEN0, CurveConstants.CURVE_SUPPLY);
    }

    /// lpTokens must equal R * T_end / Q_end (pool opens at the curve's final price), to within 1 token-wei.
    function test_lpTokensMatchFinalPrice() public pure {
        _checkLp(CurveConstants.WOKB_V_QUOTE0);
        _checkLp(CurveConstants.BEM_V_QUOTE0);
    }

    function _checkLp(uint256 vQ0) internal pure {
        uint256 vT0 = CurveConstants.V_TOKEN0;
        uint256 tEnd = vT0 - CurveConstants.CURVE_SUPPLY;
        // R * T_end / Q_end = T_end - T_end^2 / vT0, independent of vQuote0
        uint256 ideal = tEnd - (tEnd * tEnd) / vT0;
        assertApproxEqAbs(ideal, CurveConstants.LP_TOKENS, 1);
        assertGt(vQ0, 0);
    }

    /// Graduation / launch price ratio = (vT0 / T_end)^2 = 69,000 / 4,000 = 17.25 (within 1e-12).
    function test_mcRatio() public pure {
        uint256 vT0 = CurveConstants.V_TOKEN0;
        uint256 tEnd = vT0 - CurveConstants.CURVE_SUPPLY;
        uint256 ratioE18 = Math.mulDiv(vT0 * vT0, 1e18, tEnd * tEnd);
        assertApproxEqRel(ratioE18, 17.25e18, 1e6);
    }

    /// Graduation MC = $69,000 at solve-time prices (USD with 1e18 precision; 1 ppm tolerance).
    function test_graduationMarketCapUsd() public pure {
        _checkMc(CurveConstants.WOKB_V_QUOTE0, 18, 113.2322547e7);
        _checkMc(CurveConstants.BEM_V_QUOTE0, 8, 21.8777713e7);
    }

    function _checkMc(uint256 vQ0, uint256 dec, uint256 usdE7) internal pure {
        uint256 vT0 = CurveConstants.V_TOKEN0;
        uint256 tEnd = vT0 - CurveConstants.CURVE_SUPPLY;
        // MC in quote-wei = price (quote-wei per token-wei) x 1e27 token-wei; then to USD with 1e18 precision.
        uint256 qEnd = Math.mulDiv(vQ0, vT0, tEnd);
        uint256 gradUsd = Math.mulDiv(Math.mulDiv(qEnd, TOTAL, tEnd), usdE7 * 1e11, 10 ** dec);
        uint256 launchUsd = Math.mulDiv(Math.mulDiv(vQ0, TOTAL, vT0), usdE7 * 1e11, 10 ** dec);
        assertApproxEqRel(gradUsd, 69_000e18, 1e12); // 1 ppm
        assertApproxEqRel(launchUsd, 4_000e18, 1e12);
    }

    function testFuzz_roundTripLosesExactlyFeesPlusRounding(uint256 q, uint256 quoteIn) public pure {
        uint256 t = CurveConstants.V_TOKEN0;
        q = bound(q, 1e8, 1e24);
        quoteIn = bound(quoteIn, 1000, q * 2);
        uint256 fee1 = CurveMath.feeOn(quoteIn);
        uint256 net = quoteIn - fee1;
        uint256 out = CurveMath.tokensOut(q, t, net);
        vm.assume(out > 0);
        uint256 q2 = q + net;
        uint256 t2 = t - out;
        uint256 back = CurveMath.quoteOut(q2, t2, out);
        uint256 fee2 = CurveMath.feeOn(back);
        uint256 returned = back - fee2;
        assertLe(back, net, "curve never pays back more than it took");
        assertLe(net - back, 2, "rounding loss <= 2 wei");
        assertLe(returned, quoteIn - fee1 - fee2 + 0); // loss >= both fees
        assertEq(quoteIn - returned, fee1 + fee2 + (net - back));
    }

    function testFuzz_buyRaisesPriceSellLowers(uint256 q, uint256 netIn, uint256 tokensIn) public pure {
        uint256 t = CurveConstants.V_TOKEN0;
        q = bound(q, 1e8, 1e24);
        netIn = bound(netIn, 1, q);
        uint256 out = CurveMath.tokensOut(q, t, netIn);
        vm.assume(out > 0);
        // price = q / t; after buy (q + net) / (t - out) > q / t
        assertGt((q + netIn) * t, q * (t - out));
        tokensIn = bound(tokensIn, 1, t);
        uint256 qOut = CurveMath.quoteOut(q, t, tokensIn);
        assertLt((q - qOut) * t, q * (t + tokensIn));
    }

    function testFuzz_quoteForTokensCoversOutput(uint256 q, uint256 out) public pure {
        uint256 t = CurveConstants.V_TOKEN0;
        q = bound(q, 1e8, 1e24);
        out = bound(out, 1, CurveConstants.CURVE_SUPPLY);
        uint256 net = CurveMath.quoteForTokens(q, t, out);
        assertGe(CurveMath.tokensOut(q, t, net), out, "paying the quoted net releases at least `out`");
        uint256 gross = CurveMath.grossForNet(net);
        assertGe(gross - CurveMath.feeOn(gross), net);
        assertLt(gross - 1 - CurveMath.feeOn(gross - 1), net, "grossForNet is minimal");
    }
}
