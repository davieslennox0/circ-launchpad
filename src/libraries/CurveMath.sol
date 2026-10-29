// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CurveMath
/// @notice Virtual constant-product (x * y = k) curve math. Q = virtual + real quote reserve, T = virtual token reserve.
/// Every rounding goes the protocol's way: token outputs round down, quote requirements and fees round up.
library CurveMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE_BPS = 100; // 1% of quote, on buys and sells

    /// @notice Trade fee on a quote amount, rounded up.
    function feeOn(uint256 quoteAmount) internal pure returns (uint256) {
        return Math.mulDiv(quoteAmount, FEE_BPS, BPS, Math.Rounding.Ceil);
    }

    /// @notice Smallest gross quote whose post-fee remainder covers `net`.
    function grossForNet(uint256 net) internal pure returns (uint256 gross) {
        gross = Math.mulDiv(net, BPS, BPS - FEE_BPS, Math.Rounding.Ceil);
        while (gross - feeOn(gross) < net) ++gross; // at most one step, from fee rounding
    }

    /// @notice Tokens out for `netIn` quote added to the reserve: T - ceil(k / (Q + netIn)).
    function tokensOut(uint256 q, uint256 t, uint256 netIn) internal pure returns (uint256) {
        return t - Math.mulDiv(q, t, q + netIn, Math.Rounding.Ceil);
    }

    /// @notice Net quote the reserve must receive to release exactly `out` tokens: ceil(k / (T - out)) - Q.
    function quoteForTokens(uint256 q, uint256 t, uint256 out) internal pure returns (uint256) {
        return Math.mulDiv(q, t, t - out, Math.Rounding.Ceil) - q;
    }

    /// @notice Quote released (before fee) for `tokensIn` returned to the curve: Q - ceil(k / (T + tokensIn)).
    function quoteOut(uint256 q, uint256 t, uint256 tokensIn) internal pure returns (uint256) {
        return q - Math.mulDiv(q, t, t + tokensIn, Math.Rounding.Ceil);
    }
}
