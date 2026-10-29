// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice TapeOut CircuitFactory (X Layer 0x1f09DAeFA827f02CBb40967cc91b259763760761). Only the provenance check is used.
interface ICircuitFactory {
    function isCPU(address processor) external view returns (bool);
}

/// @notice A TapeOut processor's Circuits contract: one ERC-721 per processor.
interface ICircuitNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Canonical ERC-6551 registry. A Circuit's Container = account(containerImpl, 0, chainid, processor, circuitId).
interface IERC6551Registry {
    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address);
}
