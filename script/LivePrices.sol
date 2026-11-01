// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurvePad} from "../src/CurvePad.sol";
import {Addresses} from "./Addresses.sol";
import {CurveConstants} from "./CurveConstants.sol";

interface IV3PoolPrice {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Deploy-time curve constants from live on-chain prices. Token-side constants (vToken0, curveSupply, lpTokens)
/// depend only on the launch/graduation market-cap ratio and stay as in CurveConstants; vQuote0 is re-solved per quote
/// asset so graduation lands at GRAD_MC_USD at the prices read here. Spot prices: only for a human-approved deploy.
library LivePrices {
    uint256 internal constant GRAD_MC_USD = 69_000;
    uint256 internal constant LAUNCH_MC_USD = 4_000;

    /// @return okbUsdE18 USD per OKB, 1e18 fixed point (USD₮0/WOKB pool)
    /// @return bemUsdE18 USD per BEM, 1e18 fixed point (BEM/WOKB pool x OKB/USD)
    function read() internal view returns (uint256 okbUsdE18, uint256 bemUsdE18) {
        okbUsdE18 = priceE18(Addresses.WOKB_USDT0_POOL, Addresses.WOKB);
        uint256 bemInOkbE18 = priceE18(Addresses.BEM_WOKB_POOL, Addresses.BEM);
        bemUsdE18 = Math.mulDiv(bemInOkbE18, okbUsdE18, 1e18);
    }

    /// @dev Human price of one `base` in the pool's other token, 1e18 fixed point, from slot0.
    function priceE18(address pool, address base) internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IV3PoolPrice(pool).slot0();
        address t0 = IV3PoolPrice(pool).token0();
        address t1 = IV3PoolPrice(pool).token1();
        require(base == t0 || base == t1, "base not in pool");
        uint256 d0 = 10 ** IDecimals(t0).decimals();
        uint256 d1 = 10 ** IDecimals(t1).decimals();
        uint256 ratioX128 = Math.mulDiv(sqrtP, sqrtP, 1 << 64); // raw token1 per raw token0, Q128
        // base = token0: token1 per token0 = ratio * d0 / d1;  base = token1: token0 per token1 = d1 / (ratio * d0)
        return base == t0
            ? Math.mulDiv(ratioX128, d0 * 1e18, (1 << 128) * d1)
            : Math.mulDiv((1 << 128) * d1, 1e18, ratioX128 * d0);
    }

    /// @notice vQuote0 for a quote asset priced at `usdE18` with `dec` decimals (graduation MC = GRAD_MC_USD).
    function vQuote0(uint256 usdE18, uint8 dec) internal pure returns (uint128) {
        uint256 vT0 = CurveConstants.V_TOKEN0;
        uint256 tEnd = vT0 - CurveConstants.CURVE_SUPPLY;
        // vQuote0 = P_end * T_end^2 / vT0, P_end = GRAD_MC * 10^dec / (1e9 tokens * price)
        return uint128(Math.mulDiv(GRAD_MC_USD * 10 ** dec, Math.mulDiv(tEnd, tEnd, vT0), 1e9 * usdE18));
    }

    function config(uint128 vQ0) internal pure returns (CurvePad.QuoteConfig memory) {
        return CurvePad.QuoteConfig(vQ0, CurveConstants.V_TOKEN0, CurveConstants.CURVE_SUPPLY, CurveConstants.LP_TOKENS);
    }

    /// @notice Raise R at graduation for a given vQuote0 (quote-wei).
    function raise(uint128 vQ0) internal pure returns (uint256) {
        uint256 vT0 = CurveConstants.V_TOKEN0;
        return Math.mulDiv(vQ0, vT0, vT0 - CurveConstants.CURVE_SUPPLY) - vQ0;
    }
}
