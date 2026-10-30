// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey, ModifyLiquidityParams} from "./interfaces/IUniswapV4.sol";

/// @title CircHook
/// @notice Uniswap v4 hook for Circ graduation pools. Immutable, no admin. Only two permissions (no swap, donate or
/// delta-returning hooks, so swaps behave exactly like a vanilla v4 pool):
/// - beforeInitialize: only Circ's Graduator may initialize a pool that uses this hook, so nobody can create a
///   graduation pool early or at a wrong price.
/// - beforeAddLiquidity: liquidity can only be added by Graduator's own mint. Graduator authorises exactly one add for
///   one pool (transient, same transaction) and then mints through the v4 PositionManager, which is the `sender` the
///   PoolManager reports. Every other add, before or after graduation, reverts.
/// The address must carry exactly the BEFORE_INITIALIZE (1 << 13) and BEFORE_ADD_LIQUIDITY (1 << 11) flag bits; CurvePad
/// checks this when it deploys the hook with a mined CREATE2 salt.
contract CircHook {
    /// @dev Transient slot holding the one pool id Graduator has authorised for its next add.
    /// = uint256(keccak256("circ.hook.allowedAdd")) - 1
    bytes32 private constant ALLOWED_ADD_SLOT = 0x30d9ea838684cad4a64cd5c04a7d741f6881aa5907fc85223f416ca03cb47e4c;

    address public immutable graduator;
    address public immutable poolManager;
    address public immutable positionManager;

    error NotPoolManager();
    error NotGraduator();
    error AddLiquidityNotAllowed();

    constructor(address graduator_, address poolManager_, address positionManager_) {
        graduator = graduator_;
        poolManager = poolManager_;
        positionManager = positionManager_;
    }

    /// @notice Graduator authorises one liquidity add to `poolId` for the rest of this transaction.
    function allowAdd(bytes32 poolId) external {
        if (msg.sender != graduator) revert NotGraduator();
        assembly ("memory-safe") {
            tstore(ALLOWED_ADD_SLOT, poolId)
        }
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != poolManager) revert NotPoolManager();
        if (sender != graduator) revert NotGraduator();
        return this.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        if (msg.sender != poolManager) revert NotPoolManager();
        bytes32 allowed;
        assembly ("memory-safe") {
            allowed := tload(ALLOWED_ADD_SLOT)
        }
        if (sender != positionManager || allowed == bytes32(0) || allowed != keccak256(abi.encode(key))) {
            revert AddLiquidityNotAllowed();
        }
        assembly ("memory-safe") {
            tstore(ALLOWED_ADD_SLOT, 0)
        }
        return this.beforeAddLiquidity.selector;
    }
}
