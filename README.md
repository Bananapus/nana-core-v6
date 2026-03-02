# nana-core-v5

The core protocol contracts for Juicebox V5 on EVM. A flexible toolkit for launching and managing a treasury-backed token on Ethereum and L2s.

## Architecture

Juicebox V5 separates concerns across specialized contracts that coordinate through a central directory. Projects are represented as ERC-721 NFTs. Each project configures rulesets that dictate how payments, payouts, cash outs, and token minting behave over time.

### Core Contracts

| Contract | Description |
|----------|-------------|
| `JBProjects` | ERC-721 registry of projects. Minting an NFT creates a project. |
| `JBPermissions` | Bitmap-based permission system. Accounts grant operators specific permissions scoped to project IDs. |
| `JBDirectory` | Maps each project to its controller and terminals. Entry point for looking up where to interact with a project. |
| `JBController` | Coordinates rulesets, tokens, splits, and fund access limits. Entry point for launching projects, queuing rulesets, minting/burning tokens, and sending reserved tokens. |
| `JBMultiTerminal` | Accepts payments (native ETH and ERC-20s), processes cash outs, distributes payouts, and manages surplus allowances. Charges a 2.5% fee on payouts and surplus usage. |
| `JBTerminalStore` | Bookkeeping engine for all terminal inflows and outflows. Tracks balances, enforces payout limits and surplus allowances, and computes cash out reclaim amounts via a bonding curve. |
| `JBRulesets` | Stores and manages project rulesets. Handles queuing, cycling, weight decay, approval hook validation, and weight cache optimization for long-running projects with many cycles. |
| `JBTokens` | Manages dual-balance token accounting (credits + ERC-20). Credits are minted by default; once an ERC-20 is deployed, credits can be claimed as tokens. |
| `JBSplits` | Stores split configurations per project, ruleset, and group. Splits route percentages of payouts or reserved tokens to beneficiaries, projects, or hooks. |
| `JBFundAccessLimits` | Stores payout limits and surplus allowances per project, ruleset, terminal, and token. Limits are denominated in configurable currencies. |
| `JBPrices` | Price feed registry. Maps currency pairs to `IJBPriceFeed` implementations, with per-project overrides and protocol-wide defaults. |

### Token & Price Feed Contracts

| Contract | Description |
|----------|-------------|
| `JBERC20` | Cloneable ERC-20 with ERC20Votes and ERC20Permit. Deployed by `JBTokens` when a project calls `deployERC20For`. |
| `JBChainlinkV3PriceFeed` | `IJBPriceFeed` backed by a Chainlink `AggregatorV3Interface` with staleness checks. |
| `JBChainlinkV3SequencerPriceFeed` | Extends `JBChainlinkV3PriceFeed` with L2 sequencer uptime validation for Optimism/Arbitrum. |
| `JBMatchingPriceFeed` | Returns 1:1 price. Used when two currencies are equivalent. |

### Utility Contracts

| Contract | Description |
|----------|-------------|
| `JBFeelessAddresses` | Owner-managed allowlist of addresses exempt from terminal fees. |
| `JBDeadline` | Approval hook that rejects rulesets queued too close to the current ruleset's end. Ships as `JBDeadline3Hours`, `JBDeadline1Day`, `JBDeadline3Days`, `JBDeadline7Days`. |

### Libraries

| Library | Description |
|---------|-------------|
| `JBConstants` | Protocol-wide constants: `NATIVE_TOKEN` address, max percentages, max fee. |
| `JBCurrencyIds` | Currency identifiers (`ETH = 1`, `USD = 2`). |
| `JBSplitGroupIds` | Group identifiers (`RESERVED_TOKENS = 1`). |
| `JBCashOuts` | Bonding curve math for computing cash out reclaim amounts. |
| `JBSurplus` | Calculates a project's surplus across terminals. |
| `JBFees` | Fee calculation helpers. |
| `JBFixedPointNumber` | Decimal adjustment for fixed-point numbers. |
| `JBMetadataResolver` | Packs and unpacks metadata bytes for pay/cash-out hooks. |
| `JBRulesetMetadataResolver` | Packs and unpacks the `uint256 metadata` field on `JBRuleset` into `JBRulesetMetadata`. |

## Install

```bash
npm install
```

## Develop

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts |
| `forge test` | Run local tests |
| `forge test -vvvv` | Run tests with full traces |
| `FOUNDRY_PROFILE=fork forge test` | Run fork tests |
| `forge coverage --match-path "./src/*.sol"` | Generate coverage report |
