// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only stand-in for PancakeSwap V2 (factory + router).
///         Fixed price: 1 FAIR (1e18 base units) = 2e8 wei BNB, i.e. the
///         locked mint price 2e-10 BNB per token. The mock is pre-funded
///         with ETH and FAIR so swaps can settle. NEVER use on mainnet.
contract MockPancake {
    address public immutable pair;
    address public immutable wbnb;
    address public fair; // set once after the token is deployed (circular deploy)
    // price: amountOut = amountIn * PRICE_NUM / PRICE_DEN, token->BNB
    uint256 public constant PRICE_NUM = 2e8;
    uint256 public constant PRICE_DEN = 1e18;

    mapping(address => uint256) public lpMintedTo;

    event LiquidityAdded(address indexed to, uint256 tokenAmount, uint256 ethAmount);

    constructor(address pair_, address wbnb_) payable {
        pair = pair_;
        wbnb = wbnb_;
    }

    function setFair(address fair_) external {
        require(fair == address(0), "fair already set");
        require(fair_ != address(0), "zero address");
        fair = fair_;
    }

    receive() external payable {}

    function factory() external view returns (address) {
        return address(this);
    }

    function WETH() external view returns (address) {
        return wbnb;
    }

    function getPair(address, address) external view returns (address) {
        return pair;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        if (path[0] == fair) {
            amounts[1] = (amountIn * PRICE_NUM) / PRICE_DEN; // FAIR -> BNB
        } else {
            amounts[1] = (amountIn * PRICE_DEN) / PRICE_NUM; // BNB -> FAIR
        }
    }

    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        uint256 out = (amountIn * PRICE_NUM) / PRICE_DEN;
        require(out >= amountOutMin, "slippage");
        require(IERC20(fair).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
        (bool ok, ) = to.call{value: out}("");
        require(ok, "eth send failed");
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata, address to, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        uint256 out = (msg.value * PRICE_DEN) / PRICE_NUM;
        require(out >= amountOutMin, "slippage");
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
        require(IERC20(fair).transfer(to, out), "fair send failed");
    }

    function addLiquidityETH(address, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        require(IERC20(fair).transferFrom(msg.sender, address(this), amountTokenDesired), "pull failed");
        lpMintedTo[to] += amountTokenDesired; // LP tokens recorded as sent to `to`
        emit LiquidityAdded(to, amountTokenDesired, msg.value);
        return (amountTokenDesired, msg.value, amountTokenDesired);
    }
}
