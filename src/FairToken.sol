// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FAIR — BNB AI Agent fair-mint token
/// @notice ERC-20, fixed 1e12 total supply, buy tax 2% / sell tax 4% in token,
///         only on PancakeSwap pair trades. No owner, no mint, no pause,
///         no blacklist, no setTax — the rates are constants.
/// @dev Tax is collected in FAIR to this contract, swapped to BNB once its
///      value reaches the threshold (anyone may call), and the BNB is used
///      to buy back FAIR and send it straight to the dead address.
interface IRouter {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory amounts);
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

contract FairToken is ERC20, ReentrancyGuard {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant BUY_TAX_BPS = 200; // 2%
    uint256 public constant SELL_TAX_BPS = 400; // 4%
    uint256 public constant SLIPPAGE_BPS = 100; // 1% max slippage on swaps
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000_000 * 1e18; // 1 trillion

    IRouter public immutable router;
    address public immutable wbnb;
    /// @notice BNB value the tax pool must reach before it may be swapped.
    /// @dev Mainnet deployment passes 0.05 ether. Constructor param (not a
    ///      setter) so tests can use a small value without changing mainnet.
    uint256 public immutable buybackThreshold;

    address public immutable deployer;
    address public minter;
    bool private _inSwap;

    event TaxSwapped(uint256 fairIn, uint256 bnbOut);
    event BuybackBurned(uint256 bnbIn, uint256 fairOut);

    constructor(address router_, address wbnb_, uint256 buybackThreshold_) ERC20("FAIR", "FAIR") {
        require(router_ != address(0) && wbnb_ != address(0), "zero address");
        router = IRouter(router_);
        wbnb = wbnb_;
        buybackThreshold = buybackThreshold_;
        deployer = msg.sender;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice One-time wiring of the minter contract, only by the deployer.
    /// @dev Needed because token and minter reference each other (circular
    ///      deploy). After this call the minter can never be changed, and the
    ///      deployer has no other power over this contract.
    function setMinter(address minter_) external {
        require(msg.sender == deployer, "not deployer");
        require(minter == address(0), "minter already set");
        require(minter_ != address(0), "zero address");
        minter = minter_;
    }

    function pair() public view returns (address) {
        return IFactory(router.factory()).getPair(address(this), wbnb);
    }

    function _isTaxExempt(address a) internal view returns (bool) {
        // Technical exemptions only: the token contract itself (holds the
        // tax pool), the minter (adds the LP in finalize()), and the router.
        // The PAIR is deliberately NOT exempt — it is the tax trigger:
        // pair -> buyer is a buy (2%), seller -> pair is a sell (4%).
        return a == address(this) || a == minter || a == address(router);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || _inSwap) {
            super._update(from, to, value);
            return;
        }
        if (_isTaxExempt(from) || _isTaxExempt(to)) {
            super._update(from, to, value);
            return;
        }
        address p = pair();
        uint256 taxBps = 0;
        if (from == p) taxBps = BUY_TAX_BPS; // buy: pair -> buyer
        else if (to == p) taxBps = SELL_TAX_BPS; // sell: seller -> pair
        if (taxBps == 0) {
            // ordinary wallet-to-wallet transfer: no tax, per the plan
            super._update(from, to, value);
            return;
        }
        uint256 tax = (value * taxBps) / 10_000;
        super._update(from, to, value - tax);
        super._update(from, address(this), tax);
    }

    /// @notice BNB value of the accumulated tax pool, via the router quote.
    function taxPoolValueBNB() public view returns (uint256) {
        uint256 bal = balanceOf(address(this));
        if (bal == 0) return 0;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;
        return router.getAmountsOut(bal, path)[1];
    }

    /// @notice Swap accumulated tax FAIR to BNB. Anyone may call, only when
    ///         the pool is worth >= buybackThreshold. BNB stays in this
    ///         contract as the buyback pool; it never goes to a wallet.
    function swapTaxToBNB() external nonReentrant {
        uint256 bal = balanceOf(address(this));
        require(bal > 0, "no tax");
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;
        uint256 quote = router.getAmountsOut(bal, path)[1];
        require(quote >= buybackThreshold, "below threshold");
        uint256 minOut = (quote * (10_000 - SLIPPAGE_BPS)) / 10_000;
        _inSwap = true;
        _approve(address(this), address(router), bal);
        uint256[] memory amounts = router.swapExactTokensForETH(bal, minOut, path, address(this), block.timestamp);
        _inSwap = false;
        emit TaxSwapped(bal, amounts[1]);
    }

    /// @notice Buy back FAIR with the BNB buyback pool and send it straight
    ///         to the dead address. Anyone may call, only when the pool
    ///         holds >= buybackThreshold BNB.
    function buybackAndBurn() external nonReentrant {
        uint256 bnbBal = address(this).balance;
        require(bnbBal >= buybackThreshold, "below threshold");
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = address(this);
        uint256 quote = router.getAmountsOut(bnbBal, path)[1];
        uint256 minOut = (quote * (10_000 - SLIPPAGE_BPS)) / 10_000;
        _inSwap = true;
        uint256[] memory amounts = router.swapExactETHForTokens{value: bnbBal}(minOut, path, DEAD, block.timestamp);
        _inSwap = false;
        emit BuybackBurned(bnbBal, amounts[1]);
    }

    receive() external payable {}
}
