// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/FairToken.sol";
import "../src/FairMinter.sol";
import "../src/test/MockAgentIdRegistry.sol";

/// @notice Deploy $FAIR token + minter.
/// @dev TESTNET ONLY by default: this script refuses BSC mainnet (chain 56)
///      unless the env var ALLOW_MAINNET is set to "1", and even then it
///      must be run by the parent agent after a full preview review.
///      Env vars:
///        REGISTRY       Agent ID registry address
///                        (mainnet: 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F)
///        ROUTER         Pancake V2 router address
///        WBNB           WBNB address
///        START_TIME     mint start unix timestamp
///                        (mainnet: 1794715200 = 2026-11-15 12:00 CST)
///        BUYBACK_THRESHOLD_WEI  default 0.05 ether
///        MOCK_REGISTRY  "1" = deploy a MockAgentIdRegistry and register the
///                        deployer as "deployer.ai" (testnet only)
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address registry = vm.envAddress("REGISTRY");
        address router = vm.envAddress("ROUTER");
        address wbnb = vm.envAddress("WBNB");
        uint256 startTime = vm.envUint("START_TIME");
        uint256 threshold = vm.envOr("BUYBACK_THRESHOLD_WEI", uint256(0.05 ether));
        bool mockRegistry = vm.envOr("MOCK_REGISTRY", false);

        require(block.chainid != 56 || vm.envOr("ALLOW_MAINNET", false), "mainnet blocked: set ALLOW_MAINNET=1 only after preview review");
        require(startTime > block.timestamp, "start in the past");

        vm.startBroadcast(deployerKey);
        if (mockRegistry) {
            require(block.chainid != 56, "mock registry is testnet-only");
            MockAgentIdRegistry mock = new MockAgentIdRegistry();
            mock.register(vm.addr(deployerKey), "deployer.ai");
            registry = address(mock);
            console.log("MockAgentIdRegistry:", registry);
        }
        FairToken token = new FairToken(router, wbnb, threshold);
        console.log("FairToken:", address(token));
        FairMinter minter = new FairMinter(
            address(token), registry, router, startTime,
            100_000, 5_000_000 * 1e18, 0.001 ether, 500_000_000_000 * 1e18
        );
        console.log("FairMinter:", address(minter));
        token.setMinter(address(minter));
        token.transfer(address(minter), token.TOTAL_SUPPLY());
        console.log("minter FAIR balance:", token.balanceOf(address(minter)));
        vm.stopBroadcast();
    }
}
