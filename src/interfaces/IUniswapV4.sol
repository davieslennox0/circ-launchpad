// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap v4 surfaces used by Circ. Field types mirror v4-core / v4-periphery exactly; `Currency` and
/// `IHooks` are user-defined wrappers around `address`, so these structs are ABI- and selector-identical.

/// @dev v4-core PoolKey. PoolId = keccak256(abi.encode(key)).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev v4-core types/PoolOperation.sol ModifyLiquidityParams.
struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface IPoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
}

/// @dev v4-periphery PositionManager (ERC-721 positions, action-encoded liquidity changes).
interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external;
}

/// @dev Permit2 allowance-transfer surface (PositionManager pulls settlement funds through Permit2).
interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev v4-periphery libraries/Actions.sol (subset).
library V4Actions {
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;
}

interface IWOKB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
