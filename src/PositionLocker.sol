// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {FeeVault} from "./FeeVault.sol";
import {INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";

/// @title PositionLocker
/// @notice Holds graduated Uniswap v3 LP NFTs forever. There is no path to decrease liquidity, burn, or move a
/// position out; no owner; no upgrade. Anyone may collect swap fees, which are split like curve fees.
contract PositionLocker is FeeVault, IERC721Receiver {
    INonfungiblePositionManager public immutable npm;
    address public immutable pad;

    /// @notice positionId => the launch's Container (zero if not locked here).
    mapping(uint256 positionId => address container) public containerOf;

    event Locked(uint256 indexed positionId, address indexed token, address indexed container);
    event Collected(uint256 indexed positionId, uint256 amount0, uint256 amount1);

    error NotPad();
    error NotLocked();

    constructor(INonfungiblePositionManager npm_, address pad_, address protocol_, address sink_)
        FeeVault(protocol_, sink_)
    {
        if (address(npm_) == address(0) || pad_ == address(0)) revert ZeroAddress();
        npm = npm_;
        pad = pad_;
    }

    /// @dev Only position NFTs sent by CurvePad through the position manager are accepted.
    function onERC721Received(address operator, address from, uint256 positionId, bytes calldata data)
        external
        returns (bytes4)
    {
        if (msg.sender != address(npm) || operator != pad || from != pad) revert NotPad();
        (address token, address container, address nft, uint256 circuitId) =
            abi.decode(data, (address, address, address, uint256));
        containerOf[positionId] = container;
        _registerContainer(container, nft, circuitId);
        emit Locked(positionId, token, container);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Collect all swap fees owed to a locked position and accrue them by the fee split. Permissionless.
    function collect(uint256 positionId) public nonReentrant {
        address container = containerOf[positionId];
        if (container == address(0)) revert NotLocked();
        (uint256 amount0, uint256 amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams(positionId, address(this), type(uint128).max, type(uint128).max)
        );
        (,, address token0, address token1,,,,,,,,) = npm.positions(positionId);
        _accrueSplit(token0, container, amount0);
        _accrueSplit(token1, container, amount1);
        emit Collected(positionId, amount0, amount1);
    }

    function collectMany(uint256[] calldata positionIds) external {
        for (uint256 i; i < positionIds.length; ++i) {
            collect(positionIds[i]);
        }
    }
}
