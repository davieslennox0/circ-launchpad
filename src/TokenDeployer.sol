// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchToken} from "./LaunchToken.sol";

/// @title TokenDeployer
/// @notice CREATE2 factory for LaunchToken, deployed by CurvePad in its constructor. Exists only to keep LaunchToken's
/// init code out of CurvePad (EIP-170). No admin; only CurvePad may deploy, and every token mints its supply to CurvePad.
contract TokenDeployer {
    address public immutable pad;

    error OnlyPad();

    constructor() {
        pad = msg.sender;
    }

    function deploy(bytes32 salt, string calldata name, string calldata symbol) external returns (address) {
        if (msg.sender != pad) revert OnlyPad();
        return address(new LaunchToken{salt: salt}(name, symbol, pad));
    }
}
