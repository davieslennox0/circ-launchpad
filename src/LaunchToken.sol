// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice Fixed 1,000,000,000 supply, minted once to CurvePad. No owner, no mint, no pause, no blacklist, no transfer
/// restrictions. Anyone may burn their own tokens (CurvePad's Graduator burns rounding dust at graduation).
contract LaunchToken is ERC20 {
    constructor(string memory name_, string memory symbol_, address pad) ERC20(name_, symbol_) {
        _mint(pad, 1_000_000_000 ether);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
