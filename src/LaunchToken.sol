// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice Fixed 1,000,000,000 supply, minted once to CurvePad (`pad`). No owner, no mint, no pause, no blacklist.
/// Until graduation, transfers to or from this token's future Uniswap v3 pool (token/quote, 1% tier) revert,
/// so nobody can seed or trade that pool before the curve hands over. Wallet-to-wallet transfers are always free.
contract LaunchToken is ERC20 {
    /// @dev Canonical Uniswap v3 pool init code hash, checked against a live X Layer pool (RECON.md section 1).
    bytes32 internal constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    uint24 internal constant POOL_FEE = 10_000;

    /// @notice CurvePad: holds the supply and is the only address that can flip `graduated`.
    address public immutable pad;
    address public immutable predictedPool;
    bool public graduated;

    error PoolLocked();
    error OnlyPad();

    /// @dev Deployed by CurvePad's TokenDeployer, which passes CurvePad as `pad_`. The predicted pool depends only on
    /// this token's own address, so it is correct whoever deploys it.
    constructor(string memory name_, string memory symbol_, address quote, address v3Factory, address pad_)
        ERC20(name_, symbol_)
    {
        pad = pad_;
        (address token0, address token1) = address(this) < quote ? (address(this), quote) : (quote, address(this));
        predictedPool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", v3Factory, keccak256(abi.encode(token0, token1, POOL_FEE)), POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
        _mint(pad_, 1_000_000_000 ether);
    }

    /// @notice One-way switch, called by CurvePad when the curve sells out.
    function markGraduated() external {
        if (msg.sender != pad) revert OnlyPad();
        graduated = true;
    }

    /// @notice Anyone may burn their own tokens (used for rounding dust at graduation).
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!graduated && (from == predictedPool || to == predictedPool)) revert PoolLocked();
        super._update(from, to, value);
    }
}
