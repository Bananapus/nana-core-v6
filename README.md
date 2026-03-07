# nana-core-v6

The core protocol contracts for Juicebox V6 on EVM. A flexible toolkit for launching and managing a treasury-backed token on Ethereum and L2s.

For full documentation, see [docs.juicebox.money](https://docs.juicebox.money/). If you have questions, reach out on [Discord](https://discord.com/invite/ErQYmth4dS).

## Conceptual Overview

Juicebox projects have two main entry points:

- **Terminals** handle inflows and outflows of funds -- payments, cash outs, payouts, and surplus allowance usage. Each project can use multiple terminals, and a single terminal can serve many projects. `JBMultiTerminal` is the standard implementation.
- **Controllers** manage rulesets and tokens. `JBController` is the standard implementation that coordinates ruleset queuing, token minting/burning, splits, and fund access limits.

`JBDirectory` maps each project to its controller and terminals.

### Rulesets

A project's behavior is governed by a queue of **rulesets**. Each ruleset defines the rules that apply for a specific duration: payment weight (tokens minted per unit paid), cash out tax rate, reserved percent, payout limits, approval hooks, and more. When a ruleset ends, the next one in the queue takes effect. If the queue is empty, the current ruleset keeps cycling with weight decay applied each cycle. Rulesets give project creators the ability to evolve their project's rules while offering supporters contractual guarantees about the future.

Key ruleset behaviors:
- **Weight** determines token issuance per unit paid. A weight of 1 means "inherit decayed weight from the previous ruleset". A weight of 0 means "no issuance".
- **Weight decay** is controlled by `weightCutPercent`. Each cycle, the weight is reduced by this percent (9-decimal precision out of `1_000_000_000`).
- **Duration of 0** means the ruleset never expires and must be explicitly replaced by a new queued ruleset (which takes effect immediately).
- **Approval hooks** can gate whether queued rulesets take effect. For example, `JBDeadline` requires rulesets to be queued a minimum number of seconds before the current ruleset ends.

### Fund Distribution

Funds can be accessed through **payouts** (distributed to splits within payout limits, resetting each ruleset cycle) or **surplus allowance** (discretionary withdrawal of surplus funds, does not reset each cycle). Funds beyond payout limits are surplus -- available for cash outs if the project's cash out tax rate allows it.

- **Payout limits** are denominated in configurable currencies and can be set per terminal/token. Multiple limits in different currencies can be active simultaneously.
- **Surplus allowances** allow project owners to withdraw surplus funds up to a configured amount, also denominated in configurable currencies.

### Payments, Tokens, and Cash Outs

Payments mint credits (or ERC-20 tokens if an ERC-20 has been deployed for the project) for the payer based on the current ruleset's weight. The number of tokens minted can be influenced by a data hook.

Credits and tokens can be **cashed out** to reclaim surplus funds along a bonding curve determined by the cash out tax rate:
- A **0% tax rate** gives proportional (1:1) redemption of surplus.
- A **100% tax rate** means nothing can be reclaimed (all surplus is locked).
- Tax rates between 0% and 100% create a bonding curve that incentivizes holding -- later cashers-out get a better rate per token.

### Reserved Tokens

Each ruleset can define a `reservedPercent` (0-10,000 basis points). When tokens are minted from payments, this percentage is set aside. Reserved tokens accumulate in `pendingReservedTokenBalanceOf` and are distributed to the reserved token split group when `sendReservedTokensToSplitsOf` is called.

### Permissions

`JBPermissions` lets addresses delegate specific capabilities to operators, scoped by project ID. Each permission ID grants access to specific functions. See [`JBPermissionIds`](https://github.com/Bananapus/nana-permission-ids-v6/blob/main/src/JBPermissionIds.sol) for the full list.

- Permission ID `255` is `ROOT` and grants all permissions for the scoped project.
- Project ID `0` is a wildcard, granting permissions across all projects (cannot be combined with `ROOT` for safety).
- ROOT operators can set non-ROOT permissions for other operators, but cannot grant ROOT or set wildcard-project permissions.

### Hooks

Hooks are customizable contracts that plug into protocol flows:

- **Approval hooks** -- Gate whether the next queued ruleset can take effect (e.g., `JBDeadline` enforces a minimum queue time).
- **Data hooks** -- Override payment/cash-out weight, cash out tax rate, token counts, and specify pay/cash-out hooks to call. Data hooks can also grant `hasMintPermissionFor` to allow addresses to mint tokens on demand.
- **Pay hooks** -- Custom logic triggered after a payment is recorded (e.g., `JB721TiersHook` mints NFTs). Receive tokens and `JBAfterPayRecordedContext`.
- **Cash out hooks** -- Custom logic triggered after a cash out is recorded. Receive tokens and `JBAfterCashOutRecordedContext`.
- **Split hooks** -- Custom logic triggered when a payout or reserved token distribution is routed to a split. Receive tokens and `JBSplitHookContext`.

### Fees

`JBMultiTerminal` charges a 2.5% fee (`FEE = 25` out of `MAX_FEE = 1000`) on:
- Payouts to external addresses (not to other Juicebox projects).
- Surplus allowance usage.
- Cash outs when the cash out tax rate is below 100%.

Fees are paid to **project #1** (the fee beneficiary project, minted in the `JBProjects` constructor). Addresses on the `JBFeelessAddresses` allowlist are exempt from fees.

When a ruleset has `holdFees` enabled, fees are held for 28 days before being processed. During this period, if funds are returned to the project via `addToBalanceOf`, held fees can be unlocked and returned.

### Meta-Transactions

`JBController`, `JBMultiTerminal`, `JBProjects`, `JBPrices`, and `JBPermissions` support ERC-2771 meta-transactions through a trusted forwarder. This allows gasless interactions where a relayer submits transactions on behalf of users.

### Permit2

`JBMultiTerminal` integrates with Uniswap's [Permit2](https://github.com/Uniswap/permit2) for gas-efficient ERC-20 token approvals. Payers can include a `JBSingleAllowance` in the payment metadata to authorize token transfers without a separate approval transaction.

### Controller Migration

Projects can migrate between controllers using the `IJBMigratable` interface. The migration lifecycle calls `beforeReceiveMigrationFrom` on the new controller, then `migrate` on the old controller (while the directory still points to it), then updates the directory, and finally calls `afterReceiveMigrationFrom`. Terminal migration is also supported via `migrateBalanceOf`.

## Architecture

Juicebox V6 separates concerns across specialized contracts that coordinate through a central directory. Projects are represented as ERC-721 NFTs. Each project configures rulesets that dictate how payments, payouts, cash outs, and token minting behave over time.

All contracts use Solidity `0.8.26`.

### Core Contracts

| Contract | Description |
|----------|-------------|
| `JBProjects` | ERC-721 registry of projects. Minting an NFT creates a project. Optionally mints project #1 to a fee beneficiary owner. |
| `JBPermissions` | Bitmap-based permission system. Accounts grant operators specific permissions scoped to project IDs. Supports ROOT (255) for all-permissions and wildcard project ID (0). |
| `JBDirectory` | Maps each project to its controller and terminals. Entry point for looking up where to interact with a project. Manages an allowlist of addresses permitted to set a project's first controller. |
| `JBController` | Coordinates rulesets, tokens, splits, and fund access limits. Entry point for launching projects, queuing rulesets, minting/burning tokens, deploying ERC-20s, sending reserved tokens, setting project URIs, adding price feeds, and transferring credits. |
| `JBMultiTerminal` | Accepts payments (native ETH and ERC-20s), processes cash outs, distributes payouts, manages surplus allowances, and handles fees. Integrates with Permit2 for ERC-20 approvals. |
| `JBTerminalStore` | Bookkeeping engine for all terminal inflows and outflows. Tracks balances, enforces payout limits and surplus allowances, computes cash out reclaim amounts via a bonding curve, and integrates with data hooks. |
| `JBRulesets` | Stores and manages project rulesets. Handles queuing, cycling, weight decay, approval hook validation, and weight caching for long-running projects. |
| `JBTokens` | Manages dual-balance token accounting (credits + ERC-20). Credits are minted by default; once an ERC-20 is deployed or set, credits can be claimed as tokens. Credits are burned before ERC-20 tokens. |
| `JBSplits` | Stores split configurations per project, ruleset, and group. Splits route percentages of payouts or reserved tokens to beneficiaries, projects, or hooks. Packed storage for gas efficiency. Falls back to ruleset ID 0 if no splits are set for a specific ruleset. |
| `JBFundAccessLimits` | Stores payout limits and surplus allowances per project, ruleset, terminal, and token. Limits are denominated in configurable currencies and must be set in strictly increasing currency order to prevent duplicates. |
| `JBPrices` | Price feed registry. Maps currency pairs to `IJBPriceFeed` implementations, with per-project overrides and protocol-wide defaults. Feeds are immutable once set. Inverse prices are auto-calculated. |

### Token and Price Feed Contracts

| Contract | Description |
|----------|-------------|
| `JBERC20` | Cloneable ERC-20 with ERC20Votes and ERC20Permit. Deployed by `JBTokens` via `Clones.clone()`. Owned by `JBTokens`. |
| `JBChainlinkV3PriceFeed` | `IJBPriceFeed` backed by a Chainlink `AggregatorV3Interface` with staleness threshold. Rejects negative/zero prices and incomplete rounds. |
| `JBChainlinkV3SequencerPriceFeed` | Extends `JBChainlinkV3PriceFeed` with L2 sequencer uptime validation and grace period for Optimism/Arbitrum. |
| `JBMatchingPriceFeed` | Returns 1:1 price (e.g., ETH/NATIVE_TOKEN on applicable chains). Lives in `src/periphery/`. |

### Utility Contracts

| Contract | Description |
|----------|-------------|
| `JBFeelessAddresses` | Owner-managed allowlist of addresses exempt from terminal fees. Supports `IERC165`. |
| `JBDeadline` | Approval hook that rejects rulesets queued too close to the current ruleset's end. Ships as `JBDeadline3Hours`, `JBDeadline1Day`, `JBDeadline3Days`, `JBDeadline7Days`. |

### Abstract Contracts

| Contract | Description |
|----------|-------------|
| `JBControlled` | Provides `onlyControllerOf(projectId)` modifier. Used by `JBRulesets`, `JBTokens`, `JBSplits`, `JBFundAccessLimits`, and `JBPrices`. |
| `JBPermissioned` | Provides `_requirePermissionFrom` and `_requirePermissionAllowingOverrideFrom` helpers. Used by `JBController`, `JBMultiTerminal`, `JBDirectory`, and `JBPrices`. |

### Libraries

| Library | Description |
|---------|-------------|
| `JBConstants` | Protocol-wide constants: `NATIVE_TOKEN` address, max percentages, max fee. |
| `JBCurrencyIds` | Currency identifiers (`ETH = 1`, `USD = 2`). |
| `JBSplitGroupIds` | Group identifiers (`RESERVED_TOKENS = 1`). |
| `JBCashOuts` | Bonding curve math for computing cash out reclaim amounts. Includes `minCashOutCountFor` inverse via binary search. |
| `JBSurplus` | Calculates a project's surplus across all terminals. |
| `JBFees` | Fee calculation helpers. `feeAmountFrom` (forward) and `feeAmountResultingIn` (backward). |
| `JBFixedPointNumber` | Decimal adjustment between fixed-point number precisions. |
| `JBMetadataResolver` | Packs and unpacks variable-length `{id: data}` metadata entries with a lookup table. Used by pay/cash-out hooks. |
| `JBRulesetMetadataResolver` | Packs and unpacks the `uint256 metadata` field on `JBRuleset` into `JBRulesetMetadata`. Bit layout: version (4 bits), reservedPercent (16), cashOutTaxRate (16), baseCurrency (32), 14 boolean flags (1 bit each), dataHook address (160), metadata (14). |

### Hook Interfaces

| Interface | Description |
|-----------|-------------|
| `IJBRulesetApprovalHook` | Determines whether the next queued ruleset is approved or rejected. Must implement `approvalStatusOf` and `DURATION`. |
| `IJBRulesetDataHook` | Overrides payment/cash-out parameters. Implements `beforePayRecordedWith`, `beforeCashOutRecordedWith`, and `hasMintPermissionFor`. |
| `IJBPayHook` | Called after a payment is recorded. Implements `afterPayRecordedWith`. |
| `IJBCashOutHook` | Called after a cash out is recorded. Implements `afterCashOutRecordedWith`. |
| `IJBSplitHook` | Called when processing a split. Implements `processSplitWith`. |

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
| `forge fmt` | Format code |
| `forge fmt --check` | Check formatting (CI lint) |
| `FOUNDRY_PROFILE=fork forge test` | Run fork tests |
| `forge coverage --match-path "./src/*.sol"` | Generate coverage report |
