// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./FairToken.sol";

/// @title FAIR minter — direct mint, fixed price, immediate delivery
/// @notice 100,000 shares max, 0.001 BNB/share, 5,000,000 FAIR/share,
///         max 5 shares per Agent ID (keyed by the .ai handle hash).
///         finalize() is permissionless: on sell-out, or 30 days after
///         start, whichever comes first. LP tokens go to the dead address
///         in the same call; all unsold FAIR is burned to dead.
/// @dev No owner. Every parameter is immutable, set in the constructor.
///      Registry address is a constructor parameter so testnet can use a
///      mock registry and mainnet uses the verified SPACE ID Agent ID
///      registry 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F.
interface IAgentIdRegistry {
    function balanceOf(address account) external view returns (uint256);
    function handleOf(address account) external view returns (string memory);
}

contract FairMinter is ReentrancyGuard {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    FairToken public immutable token;
    IAgentIdRegistry public immutable registry;
    IRouter public immutable router;

    uint256 public immutable startTime;
    uint256 public immutable maxShares;
    uint256 public immutable tokensPerShare;
    uint256 public immutable pricePerShare;
    uint256 public immutable lpPool; // 500,000,000,000 FAIR, in base units
    uint256 public immutable finalizeAfter; // startTime + 30 days

    uint256 public constant MAX_PER_ID = 5;

    uint256 public totalSold;
    bool public finalized;
    mapping(bytes32 => uint256) public mintedByHandle;

    event Minted(address indexed buyer, bytes32 indexed handleHash, uint256 shares, uint256 fairAmount);
    event Finalized(uint256 soldShares, uint256 lpTokens, uint256 bnbRaised, uint256 burned);

    constructor(
        address token_,
        address registry_,
        address router_,
        uint256 startTime_,
        uint256 maxShares_,
        uint256 tokensPerShare_,
        uint256 pricePerShare_,
        uint256 lpPool_
    ) {
        require(token_ != address(0) && registry_ != address(0) && router_ != address(0), "zero address");
        require(maxShares_ > 0 && tokensPerShare_ > 0 && pricePerShare_ > 0, "zero param");
        token = FairToken(payable(token_));
        registry = IAgentIdRegistry(registry_);
        router = IRouter(router_);
        startTime = startTime_;
        maxShares = maxShares_;
        tokensPerShare = tokensPerShare_;
        pricePerShare = pricePerShare_;
        lpPool = lpPool_;
        finalizeAfter = startTime_ + 30 days;
        IERC20(token_).approve(router_, type(uint256).max);
    }

    /// @notice Mint `shares` (1..5 per call, 5 total per Agent ID) for
    ///         exactly shares * pricePerShare BNB. FAIR arrives immediately.
    function mint(uint256 shares) external payable nonReentrant {
        require(!finalized, "finalized");
        require(block.timestamp >= startTime, "not started");
        require(shares >= 1 && shares <= MAX_PER_ID, "shares 1..5");
        require(totalSold + shares <= maxShares, "sold out");
        require(msg.value == shares * pricePerShare, "wrong value");
        require(registry.balanceOf(msg.sender) > 0, "no agent id");
        string memory handle = registry.handleOf(msg.sender);
        require(bytes(handle).length > 0, "empty handle");
        bytes32 handleHash = keccak256(bytes(handle));
        require(mintedByHandle[handleHash] + shares <= MAX_PER_ID, "id cap 5");
        mintedByHandle[handleHash] += shares;
        totalSold += shares;
        uint256 fairAmount = shares * tokensPerShare;
        require(IERC20(address(token)).transfer(msg.sender, fairAmount), "transfer failed");
        emit Minted(msg.sender, handleHash, shares, fairAmount);
    }

    /// @notice Add the pool and burn the unsold supply. Anyone may call,
    ///         once, when sold out or 30 days have passed since start.
    function finalize() external nonReentrant {
        require(!finalized, "already finalized");
        require(totalSold == maxShares || block.timestamp >= finalizeAfter, "too early");
        finalized = true;

        uint256 sold = totalSold;
        uint256 lpTokens = (lpPool * sold) / maxShares;
        uint256 bnbRaised = address(this).balance;
        uint256 burned = 0;

        if (sold > 0) {
            router.addLiquidityETH{value: bnbRaised}(
                address(token), lpTokens, 0, 0, DEAD, block.timestamp
            );
        }
        uint256 remaining = IERC20(address(token)).balanceOf(address(this));
        if (remaining > 0) {
            require(IERC20(address(token)).transfer(DEAD, remaining), "burn failed");
            burned = remaining;
        }
        emit Finalized(sold, lpTokens, bnbRaised, burned);
    }

    /// @notice Reject plain BNB transfers so no BNB can get stuck here;
    ///         mint() is the only way BNB enters.
    receive() external payable {
        revert("use mint()");
    }
}
