// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICircuitNFT} from "./interfaces/ITapeOut.sol";

/// @title FeeVault
/// @notice Pull-based fee accounting shared by CurvePad and PositionLocker.
/// Fees split Container 50% / protocol 30% / sink 20%; rounding remainders go to the protocol.
/// Protocol and sink balances can be pushed by anyone. Creator (Container) balances can only be moved by the
/// Circuit's current holder, to either the Container or the holder's own wallet. The wallet route is a fallback
/// in case a TapeOut upgrade breaks Container withdrawals; holder-gating stops anyone forcing funds into a broken Container.
abstract contract FeeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant CONTAINER_BPS = 5_000;
    uint256 internal constant SINK_BPS = 2_000;
    // protocol share = remainder (3_000 bps plus rounding)

    struct CircuitRef {
        address nft;
        uint256 id;
    }

    address public immutable protocol;
    address public immutable sink;

    mapping(address asset => mapping(address recipient => uint256)) public accrued;
    mapping(address asset => uint256) public totalAccrued;
    mapping(address container => CircuitRef) public circuitOf;

    event Claimed(address indexed asset, address indexed recipient, uint256 amount);
    event CreatorClaimed(address indexed container, address indexed asset, address indexed to, uint256 amount);

    error ZeroAddress();
    error CreatorClaimOnly();
    error UnknownContainer();
    error NotHolder();

    constructor(address protocol_, address sink_) {
        if (protocol_ == address(0) || sink_ == address(0)) revert ZeroAddress();
        protocol = protocol_;
        sink = sink_;
    }

    /// @notice How trade and LP fees are split, in basis points of the fee. Rounding remainders go to the protocol.
    function feeSplitBps() external pure returns (uint256 containerBps, uint256 protocolBps, uint256 sinkBps) {
        return (CONTAINER_BPS, BPS - CONTAINER_BPS - SINK_BPS, SINK_BPS);
    }

    /// @notice Push accrued protocol or sink fees. Permissionless.
    function claim(address asset, address recipient) external nonReentrant {
        if (circuitOf[recipient].nft != address(0)) revert CreatorClaimOnly();
        _pay(asset, recipient, recipient);
    }

    /// @notice Move a Circuit's creator fees. Only the Circuit NFT's holder at claim time may call this.
    /// @param toHolder true sends to msg.sender (fallback), false sends to the Container.
    function claimCreator(address container, address asset, bool toHolder) external nonReentrant {
        CircuitRef memory ref = circuitOf[container];
        if (ref.nft == address(0)) revert UnknownContainer();
        if (ICircuitNFT(ref.nft).ownerOf(ref.id) != msg.sender) revert NotHolder();
        address to = toHolder ? msg.sender : container;
        uint256 amount = _pay(asset, container, to);
        emit CreatorClaimed(container, asset, to, amount);
    }

    function _registerContainer(address container, address nft, uint256 id) internal {
        if (circuitOf[container].nft == address(0)) circuitOf[container] = CircuitRef(nft, id);
    }

    function _accrueSplit(address asset, address container, uint256 amount) internal {
        if (amount == 0) return;
        uint256 toContainer = amount * CONTAINER_BPS / BPS;
        uint256 toSink = amount * SINK_BPS / BPS;
        accrued[asset][container] += toContainer;
        accrued[asset][sink] += toSink;
        accrued[asset][protocol] += amount - toContainer - toSink;
        totalAccrued[asset] += amount;
    }

    function _accrueProtocol(address asset, uint256 amount) internal {
        if (amount == 0) return;
        accrued[asset][protocol] += amount;
        totalAccrued[asset] += amount;
    }

    function _pay(address asset, address account, address to) private returns (uint256 amount) {
        amount = accrued[asset][account];
        if (amount == 0) return 0;
        accrued[asset][account] = 0;
        totalAccrued[asset] -= amount;
        IERC20(asset).safeTransfer(to, amount);
        emit Claimed(asset, to, amount);
    }
}
