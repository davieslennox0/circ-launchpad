// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {FeeVault} from "./FeeVault.sol";
import {IPositionManager, V4Actions} from "./interfaces/IUniswapV4.sol";

interface ICurvePadGraduator {
    function graduator() external view returns (address);
}

/// @title PositionLocker
/// @notice Holds graduated Uniswap v4 position NFTs forever. There is no path to decrease liquidity, burn, or move a
/// position out; no owner; no upgrade. Anyone may collect swap fees, which are split like curve fees.
contract PositionLocker is FeeVault, IERC721Receiver {
    IPositionManager public immutable positionManager;
    address public immutable pad;

    struct Lock {
        address container;
        address currency0;
        address currency1;
    }

    mapping(uint256 positionId => Lock) public locks;

    event Locked(uint256 indexed positionId, address indexed token, address indexed container);
    event Collected(uint256 indexed positionId, uint256 amount0, uint256 amount1);

    error NotPad();
    error NotLocked();

    constructor(IPositionManager positionManager_, address pad_, address protocol_, address sink_)
        FeeVault(protocol_, sink_)
    {
        if (address(positionManager_) == address(0) || pad_ == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
        pad = pad_;
    }

    /// @notice The launch's Container for a locked position (zero if not locked here).
    function containerOf(uint256 positionId) external view returns (address) {
        return locks[positionId].container;
    }

    /// @dev Only position NFTs sent by CurvePad's Graduator through the position manager are accepted.
    function onERC721Received(address operator, address from, uint256 positionId, bytes calldata data)
        external
        returns (bytes4)
    {
        address graduator = ICurvePadGraduator(pad).graduator();
        if (msg.sender != address(positionManager) || operator != graduator || from != graduator) revert NotPad();
        (address token, address container, address nft, uint256 circuitId, address currency0, address currency1) =
            abi.decode(data, (address, address, address, uint256, address, address));
        locks[positionId] = Lock(container, currency0, currency1);
        _registerContainer(container, nft, circuitId);
        emit Locked(positionId, token, container);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Collect all swap fees owed to a locked position and accrue them by the fee split. Permissionless.
    /// @dev v4 collects fees with DECREASE_LIQUIDITY(0) + TAKE_PAIR; PositionManager returns no amounts, so the split
    /// uses this call's own balance change. Funds already sitting here (donations) are never part of it.
    function collect(uint256 positionId) public nonReentrant {
        Lock memory l = locks[positionId];
        if (l.container == address(0)) revert NotLocked();
        uint256 before0 = IERC20(l.currency0).balanceOf(address(this));
        uint256 before1 = IERC20(l.currency1).balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(l.currency0, l.currency1, address(this));
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(V4Actions.DECREASE_LIQUIDITY, V4Actions.TAKE_PAIR), params), block.timestamp
        );

        uint256 amount0 = IERC20(l.currency0).balanceOf(address(this)) - before0;
        uint256 amount1 = IERC20(l.currency1).balanceOf(address(this)) - before1;
        _accrueSplit(l.currency0, l.container, amount0);
        _accrueSplit(l.currency1, l.container, amount1);
        emit Collected(positionId, amount0, amount1);
    }

    function collectMany(uint256[] calldata positionIds) external {
        for (uint256 i; i < positionIds.length; ++i) {
            collect(positionIds[i]);
        }
    }
}
