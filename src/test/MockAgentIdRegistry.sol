// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only stand-in for the SPACE ID Agent ID registry
///         (mainnet 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F).
///         BSC testnet has no such registry, so tests deploy this mock.
///         NEVER use on mainnet.
contract MockAgentIdRegistry {
    mapping(address => string) private _handles;
    mapping(address => bool) private _hasId;

    function register(address account, string calldata handle) external {
        _handles[account] = handle;
        _hasId[account] = true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _hasId[account] ? 1 : 0;
    }

    function handleOf(address account) external view returns (string memory) {
        return _handles[account];
    }
}
