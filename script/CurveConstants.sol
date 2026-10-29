// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CurvePad} from "../src/CurvePad.sol";

/// @notice Curve constants from script/solve_constants.py.
/// Targets: launch MC $4,000, graduation MC $69,000 (MC = price x 1B), curveSupply + lpTokens = 1e27.
/// Prices at solve time (2026-10-29): OKB $113.2322547, BEM $21.8777713. Raise R = $13,389.45 for either quote.
library CurveConstants {
    uint128 internal constant V_TOKEN0 = 1_061_538_461_538_461_538_461_538_462;
    uint128 internal constant CURVE_SUPPLY = 805_950_034_987_136_158_382_022_685;
    uint128 internal constant LP_TOKENS = 194_049_965_012_863_841_617_977_315;

    uint128 internal constant WOKB_V_QUOTE0 = 37_499_508_045_686_262_872; // 37.4995 WOKB (18 dp)
    uint128 internal constant BEM_V_QUOTE0 = 19_408_530_183; // 194.0853 BEM (8 dp)

    function wokb() internal pure returns (CurvePad.QuoteConfig memory) {
        return CurvePad.QuoteConfig(WOKB_V_QUOTE0, V_TOKEN0, CURVE_SUPPLY, LP_TOKENS);
    }

    function bem() internal pure returns (CurvePad.QuoteConfig memory) {
        return CurvePad.QuoteConfig(BEM_V_QUOTE0, V_TOKEN0, CURVE_SUPPLY, LP_TOKENS);
    }
}
