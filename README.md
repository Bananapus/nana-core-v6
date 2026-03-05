# nana-core-v6

The core protocol contracts for Juicebox V5 on EVM. A flexible toolkit for launching and managing a treasury-backed token on Ethereum and L2s.

For full documentation, see [docs.juicebox.money](https://docs.juicebox.money/). If you have questions, reach out on [Discord](https://discord.com/invite/ErQYmth4dS).

## Conceptual Overview

Juicebox projects have two main entry points:

- **Terminals** handle inflows and outflows of funds — payments, cash outs, payouts, and surplus allowance usage. Each project can use multiple terminals, and a single terminal can serve many projects. `JBMultiTerminal` is the standard implementation.
- **Controllers** manage rulesets and tokens. `JBController` is the standard implementation that coordinates ruleset queuing, token minting/burning, splits, and fund access limits.

`JBDirectory` maps each project to its controller and terminals.

### Rulesets

A project's behavior is governed by a queue of **rulesets**. Each ruleset defines the rules that apply for a specific duration: payment weight (tokens minted per unit paid), cash out rate, reserved rate, payout limits, approval hooks, and more. When a ruleset ends, the next one in the queue takes effect. If the queue is empty, the current ruleset keeps cycling with weight decay applied each cycle. Rulesets give project creators the ability to evolve their project's rules while offering supporters contractual guarantees about the future.

### Fund Distribution

Funds can be accessed through **payouts** (distributed to splits within payout limits, resetting each ruleset) or **surplus allowance** (discretionary withdrawal of surplus funds, does not reset). Funds beyond payout limits are surplus — available for cash outs if the project's cash out rate allows it.

### Payments, Tokens, and Cash Outs

Payments mint credits (or ERC-20 tokens if deployed) for the payer. Credits and tokens can be **cashed out** to reclaim surplus funds along a bonding curve determined by the cash out rate. A 100% rate gives 1:1 redemption; lower rates incentivize holding by giving later redeemers a better rate.

### Permissions

`JBPermissions` lets addresses delegate specific capabilities to operators, scoped by project ID. Each permission ID grants access to specific functions (see [`JBPermissionIds`](https://github.com/Bananapus/nana-permission-ids-v6/blob/main/src/JBPermissionIds.sol) for the full list of 34 permission IDs used across the protocol).

### Hooks

Hooks are customizable contracts that plug into protocol flows:

- **Approval hooks** — Gate whether the next queued ruleset can take effect (e.g., `JBDeadline` enforces a minimum queue time).
- **Data hooks** — Override payment/cash-out weight or memo, and specify pay/cash-out hooks to call.
- **Pay hooks** — Custom logic triggered after a payment is recorded (e.g., `JB721TiersHook` mints NFTs).
- **Cash out hooks** — Custom logic triggered after a cash out is recorded.
- **Split hooks** — Custom logic triggered when a payout is routed to a split.

### Fees

`JBMultiTerminal` charges a 2.5% fee on payouts to addresses (not to other projects), surplus allowance usage, and cash outs when the cash out rate is below 100%.

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
| `JBRulesets` | Stores and manages project rulesets. Handles queuing, cycling, weight decay, and approval hook validation. |
| `JBRulesets5_1` | V5.1 rulesets implementation with weight cache optimization for long-running projects with many cycles. |
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
