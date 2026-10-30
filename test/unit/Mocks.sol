// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockCircuitFactory {
    mapping(address => bool) public isCPU;

    function setCPU(address cpu, bool ok) external {
        isCPU[cpu] = ok;
    }
}

contract MockCircuitNFT is ERC721 {
    constructor() ERC721("Circuits", "CIRC") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @dev Deterministic stand-in for the ERC-6551 registry.
contract MockRegistry {
    function account(address impl, bytes32 salt, uint256 chainId, address nft, uint256 id)
        external
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encode(impl, salt, chainId, nft, id)))));
    }
}

contract MockQuote is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory sym, uint8 dec_) ERC20(sym, sym) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev WETH9-style wrapper.
contract MockWOKB is ERC20 {
    constructor() ERC20("Wrapped OKB", "WOKB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

/// @dev Stands in for the v4 PositionManager's wiring getters (graduation itself is covered by fork tests).
contract MockNPM {
    address public poolManager;
    address public permit2;

    constructor(address poolManager_, address permit2_) {
        poolManager = poolManager_;
        permit2 = permit2_;
    }
}
