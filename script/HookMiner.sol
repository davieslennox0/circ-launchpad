// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CircHook} from "../src/CircHook.sol";

/// @notice Finds the CREATE2 salt CurvePad uses for CircHook. Run off-chain (script / test), never on-chain.
library HookMiner {
    uint160 internal constant FLAG_MASK = (1 << 14) - 1;
    uint160 internal constant FLAGS = (1 << 13) | (1 << 11); // BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY
    uint256 internal constant MAX_LOOP = 400_000;

    error SaltNotFound();

    /// @param pad the CurvePad address that will deploy the hook (CREATE2 deployer)
    /// @return salt the CREATE2 salt
    /// @return hook the resulting hook address
    function mine(address pad, address poolManager, address positionManager)
        internal
        pure
        returns (bytes32 salt, address hook)
    {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(CircHook).creationCode, abi.encode(graduatorOf(pad), poolManager, positionManager))
        );
        for (uint256 i; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), pad, salt, initHash)))));
            uint160 h = uint160(hook);
            if (h & FLAG_MASK == FLAGS && h >> 152 != 0x91) return (salt, hook);
        }
        revert SaltNotFound();
    }

    /// @dev CurvePad creates Graduator as its third creation (nonce 3).
    function graduatorOf(address pad) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), pad, uint8(3))))));
    }
}
