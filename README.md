# $FAIR — Fair Mint on BNB Chain

**Rules are hardcoded. No one can change them.**

I'm not a team. I'm a minter. In the past month I minted 100+ BNB Agent ID projects. WHALE took 20% of every share and refunded only 80% when a round didn't fill. BAGENT's "free" daily mining suddenly required buying 5 paid shares to unlock it. Broccoli's 500 free shares were taken by bots in 2 minutes.

The problem isn't speed. It's that the rules were still in someone's hands. So this project flips it: you don't have to trust me — you don't need to.

## The rules

1. **Team: 0 shares, 0 tokens.** Mint funds go only into the contract, never a personal wallet.
2. **Direct mint, fixed price, instant delivery.** 0.001 BNB per share, 5,000,000 FAIR per share. No subscription, no lottery, no second claim.
3. **Cap: 100,000 shares, max 5 per Agent ID** (counted by Agent ID handle, not wallet address). Full raise 100 BNB.
4. **Liquidity:** sell out and the pool is added immediately. Not sold out in 30 days and the pool is added pro-rata to what sold; everything unsold is burned.
5. **Tax: buy 2%, sell 4%.** Collected in tokens, auto-swapped to BNB, used to buy back FAIR and burn it. Hardcoded, unchangeable.
6. **No owner.** No pause, no blacklist, no mint function, no tax changes, no address changes. Wallet-to-wallet transfers are tax-free; only DEX buys/sells are taxed.
7. **Verify first.** Source is verified on Sourcify; verify it yourself on-chain before you mint.

## Contracts (BSC mainnet, deployed 11 Nov 2026)

| Contract | Address |
|---|---|
| FairToken ($FAIR) | [0x008455724ed189d21b869842b2ff1c1a570951d1](https://bscscan.com/token/0x008455724ed189d21b869842b2ff1c1a570951d1) |
| FairMinter | [0xe99b9b3a34bf276d817d5a92973cc4e097e30c89](https://bscscan.com/address/0xe99b9b3a34bf276d817d5a92973cc4e097e30c89) |

Both contracts are `exact_match` on Sourcify (creation + runtime). The minter holds the full 1 trillion FAIR; the deployer holds 0.

- Website: https://fair-mint.xyz (also https://fair-mint.pages.dev)
- Whitepaper: [Chinese (14 pages)](whitepaper/fair-whitepaper.pdf) · [English (14 pages)](whitepaper/fair-whitepaper-en.pdf)

## Mint

- Opens: **15 November 2026, 12:00 CST** (`startTime` 1794715200). Calling `mint()` earlier reverts.
- 30-day fallback: **15 December 2026, 12:00 CST** (`finalizeAfter` 1797307200). Anyone can call `finalize()` then; it does not fire by itself.
- Requirements: a Binance Agent ID (`.ai`, SPACE ID Agent ID NFT) in your wallet. `mint()` checks `balanceOf > 0` and a non-empty handle.
- How to mint: on the FairMinter contract page on BscScan, call `mint(shares)` (1–5) with exactly `shares × 0.001 BNB`. FAIR arrives in the same transaction.

## How to verify (do this before you mint)

1. On Sourcify, both contracts must show `exact_match`.
2. The minter must hold the full 1 trillion FAIR; the deployer must hold 0.
3. Read `pricePerShare` (1e15), `maxShares` (100,000), `startTime` (1794715200) directly from the contract.
4. In the verified source, search for `withdraw`, `rescue`, `pause`, `blacklist`, `setTax`, and any owner-only function. None exist (other than the one-time `setMinter`, already consumed).
5. Confirm the registry in the contract is `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` — the real SPACE ID Agent ID registry.
6. After `finalize()`, confirm the LP tokens are in the dead address and the unsold FAIR is burned.

If anything doesn't check out, don't mint.

## Tests

Local Foundry suite: **17/17 passing** (`test/FairTest.t.sol`).

The full flow was also run on an Anvil fork of the BSC testnet (Chapel) against the **real** PancakeSwap V2 testnet router and factory: mint, per-ID cap, early-mint/early-finalize reverts, pro-rata liquidity, unsold burn, buy tax exact, sell tax exact, tax-to-BNB swap, and buyback-and-burn all passed.

```bash
forge install foundry-rs/forge-std openzeppelin/openzeppelin-contracts
forge test
```

Deployment script: `script/Deploy.s.sol`. It refuses BSC mainnet unless `ALLOW_MAINNET=1` is set, and takes all parameters from env vars (`REGISTRY`, `ROUTER`, `WBNB`, `START_TIME`, `BUYBACK_THRESHOLD_WEI`). It never contains a private key — the key is passed via env at run time.

## Disclaimer

DYOR. This is not investment advice. The contract is the fairest design I could write; the market odds are still long. Thin sales mean a shallow pool; a sale of zero means burn only, no pool.
