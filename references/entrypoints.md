# Core Entry Points

Use this file when you already know the task is in `nana-core-v6` and need the concrete contract/function surface to open next.

## Purpose

The core Juicebox V6 protocol on EVM: a modular system for launching treasury-backed tokens with configurable rulesets that govern payments, payouts, cash outs, and token issuance.

## Contracts

| Contract | Role |
|----------|------|
| `JBProjects` | ERC-721 project registry. Each NFT mint creates a new project ID. |
| `JBPermissions` | Packed `uint256` bitmap permissions. Operators get specific permission IDs scoped to projects. |
| `JBDirectory` | Maps project IDs to their controller (`IERC165`) and terminals (`IJBTerminal[]`). |
| `JBController` | Orchestrates rulesets, tokens, splits, fund access limits. Entry point for project lifecycle. |
| `JBMultiTerminal` | Handles ETH/ERC-20 payments, cash outs, payouts, surplus allowance, fees. Permit2 integration. |
| `JBTerminalStore` | Bookkeeping: balances, payout limit tracking, surplus calculation, bonding curve reclaim math. |
| `JBRulesets` | Stores/cycles rulesets with weight decay, approval hooks, and weight cache for gas-efficient long-running cycles. |
| `JBTokens` | Dual-balance system: credits (internal) + ERC-20. Credits burned first on burn. |
| `JBSplits` | Split configurations per project/ruleset/group. Packed storage for gas efficiency. |
| `JBFundAccessLimits` | Payout limits and surplus allowances per project/ruleset/terminal/token. |
| `JBPrices` | Price feed registry with project-specific and protocol-wide default feeds. Immutable once set. |
| `JBERC20` | Cloneable ERC-20 with Votes + Permit + ERC-1271. Controlled by `JBTokens` via `onlyTokens`. Deployed via `Clones.clone()`. |
| `JBFeelessAddresses` | Allowlist for fee-exempt addresses. |
| `JBChainlinkV3PriceFeed` | Chainlink AggregatorV3 price feed with staleness threshold. Rejects negative/zero prices, incomplete rounds (`updatedAt == 0`), and stale answers carried from previous rounds (`answeredInRound < roundId`). |
| `JBChainlinkV3SequencerPriceFeed` | L2 sequencer-aware Chainlink feed (Optimism/Arbitrum) with grace period after restart. Treats any non-zero sequencer answer as down (`answer != 0`). |
| `JBDeadline` | Approval hook: rejects rulesets queued within `DURATION` seconds of start. Ships as `JBDeadline3Hours`, `JBDeadline1Day`, `JBDeadline3Days`, `JBDeadline7Days`. |
| `JBMatchingPriceFeed` | Always returns 1:1. For equivalent currencies (e.g. ETH/NATIVE_TOKEN). |

## Key Functions

### JBController

| Function | What it does |
|----------|--------------|
| `launchProjectFor(address owner, string uri, JBRulesetConfig[] rulesetConfigs, JBTerminalConfig[] terminalConfigs, string memo)` | Creates a project, queues its first rulesets, and configures terminals. Returns `projectId`. |
| `launchRulesetsFor(uint256 projectId, JBRulesetConfig[] rulesetConfigs, JBTerminalConfig[] terminalConfigs, string memo)` | Launches the first rulesets for an existing project that has none. |
| `queueRulesetsOf(uint256 projectId, JBRulesetConfig[] rulesetConfigs, string memo)` | Queues new rulesets for a project. Takes effect after the current ruleset ends (or immediately if duration is 0). |
| `mintTokensOf(uint256 projectId, uint256 tokenCount, address beneficiary, string memo, bool useReservedPercent)` | Mints project tokens. Requires `allowOwnerMinting` in the current ruleset or caller must be a terminal/hook with mint permission. |
| `burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string memo)` | Burns tokens from a holder. Requires holder's permission (`BURN_TOKENS`). |
| `sendReservedTokensToSplitsOf(uint256 projectId)` | Distributes accumulated reserved tokens to the reserved token split group. Returns token count sent. |
| `deployERC20For(uint256 projectId, string name, string symbol, bytes32 salt)` | Deploys a cloneable `JBERC20` for the project. Credits become claimable. |
| `claimTokensFor(address holder, uint256 projectId, uint256 count, address beneficiary)` | Redeems credits for ERC-20 tokens into beneficiary's wallet. |
| `setSplitGroupsOf(uint256 projectId, uint256 rulesetId, JBSplitGroup[] splitGroups)` | Sets the split groups for a project's ruleset. |
| `setTokenFor(uint256 projectId, IJBToken token)` | Sets an existing ERC-20 token for the project (requires `allowSetCustomToken` in ruleset). External token supply changes affect only that project's supply-sensitive pricing and cash-out math. |
| `setTokenMetadataOf(uint256 projectId, string name, string symbol)` | Sets the name and symbol of a project's ERC-20 token. Requires `SET_TOKEN_METADATA` permission. |
| `setUriOf(uint256 projectId, string uri)` | Sets the project's metadata URI. |
| `transferCreditsFrom(address holder, uint256 projectId, address recipient, uint256 creditCount)` | Transfers credits between addresses (reverts if `pauseCreditTransfers` is set in ruleset). |
| `addPriceFeedFor(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed)` | Registers a price feed (requires `allowAddPriceFeed` in ruleset). |
| `migrate(uint256 projectId, IERC165 to)` | Migrates the project to a new controller. Calls `beforeReceiveMigrationFrom`, `migrate`, updates directory, then `afterReceiveMigrationFrom`. |
| `currentRulesetOf(uint256 projectId)` | Returns the current ruleset and unpacked metadata. |
| `upcomingRulesetOf(uint256 projectId)` | Returns the upcoming ruleset and unpacked metadata. |
| `allRulesetsOf(uint256 projectId, uint256 startingId, uint256 size)` | Returns an array of rulesets with metadata, paginated. |
| `pendingReservedTokenBalanceOf(uint256 projectId)` | Returns accumulated reserved tokens not yet distributed. |
| `totalTokenSupplyWithReservedTokensOf(uint256 projectId)` | Returns total supply including pending reserved tokens. |
| `previewMintOf(uint256 projectId, uint256 tokenCount, bool useReservedPercent)` | Simulates a mint under the current ruleset. Returns `(beneficiaryTokenCount, reservedTokenCount)`. Reverts if `tokenCount` is 0. |

### JBMultiTerminal

| Function | What it does |
|----------|--------------|
| `pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)` | Pays a project. Mints project tokens to beneficiary based on ruleset weight. Returns token count. |
| `cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address payable beneficiary, bytes metadata)` | Burns project tokens and reclaims surplus terminal tokens via bonding curve. |
| `sendPayoutsOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut)` | Distributes payouts from the project's balance to its payout split group, up to the payout limit. |
| `useAllowanceOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut, address payable beneficiary, address payable feeBeneficiary, string memo)` | Withdraws from the project's surplus allowance to a beneficiary. The `feeBeneficiary` receives tokens minted by the fee payment. |
| `addToBalanceOf(uint256 projectId, address token, uint256 amount, bool shouldReturnHeldFees, string memo, bytes metadata)` | Adds funds to a project's balance without minting tokens. Can unlock held fees. |
| `migrateBalanceOf(uint256 projectId, address token, IJBTerminal to)` | Migrates a project's token balance to another terminal. Requires `allowTerminalMigration`. |
| `processHeldFeesOf(uint256 projectId, address token, uint256 count)` | Processes up to `count` held fees for a project, sending them to the fee beneficiary project. |
| `addAccountingContextsFor(uint256 projectId, JBAccountingContext[] accountingContexts)` | Adds new accounting contexts (token types) to a terminal for a project. |
| `currentSurplusOf(uint256 projectId, address[] tokens, uint256 decimals, uint256 currency)` | Returns the project's current surplus in this terminal. Empty `tokens` = all tokens. |
| `accountingContextForTokenOf(uint256 projectId, address token)` | Returns the accounting context for a specific token. |
| `accountingContextsOf(uint256 projectId)` | Returns all accounting contexts for a project. |
| `previewPayFor(uint256 projectId, address token, uint256 amount, address beneficiary, bytes metadata)` | Simulates a full payment including the reserved/beneficiary token split. Returns `(ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications)`. Composes `STORE.previewPayFrom` + `controller.previewMintOf`. |
| `previewCashOutFrom(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, address payable beneficiary, bytes metadata)` | Simulates a full cash out including bonding curve and data hook effects. Cash-out data hooks may alter pricing inputs, but not the caller-supplied burn count. Returns `(ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications)`. Delegates to `STORE.previewCashOutFrom`. |
| `heldFeesOf(uint256 projectId, address token, uint256 count)` | Returns up to `count` held fees for a project/token. |

### JBTerminalStore

| Function | What it does |
|----------|--------------|
| `recordPaymentFrom(address payer, JBTokenAmount amount, uint256 projectId, address beneficiary, bytes metadata)` | Records a payment. Applies data hook if enabled. Returns ruleset, token count, hook specifications. |
| `recordPayoutFor(uint256 projectId, address token, uint256 amount, uint256 currency)` | Records a payout. Enforces payout limits. Returns ruleset and amount paid out. |
| `recordCashOutFor(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, bool beneficiaryIsFeeless, bytes metadata)` | Records a cash out. Computes reclaim via the bonding curve, including any pricing-only adjustments returned by the cash-out data hook. Returns ruleset, reclaim amount, tax rate, and hook specifications. |
| `recordUsedAllowanceOf(uint256 projectId, address token, uint256 amount, uint256 currency)` | Records surplus allowance usage. Enforces allowance limits. Returns ruleset and used amount. |
| `recordAddedBalanceFor(uint256 projectId, address token, uint256 amount)` | Records funds added to a project's balance. |
| `recordTerminalMigration(uint256 projectId, address token)` | Records a terminal migration, returning the full balance. |
| `balanceOf(address terminal, uint256 projectId, address token)` | Returns the balance of a project at a terminal for a given token. |
| `usedPayoutLimitOf(address terminal, uint256 projectId, address token, uint256 rulesetCycleNumber, uint256 currency)` | Returns the used payout limit for a project in a given cycle. |
| `usedSurplusAllowanceOf(address terminal, uint256 projectId, address token, uint256 rulesetId, uint256 currency)` | Returns the used surplus allowance for a project in a given ruleset. |
| `currentReclaimableSurplusOf(uint256 projectId, uint256 cashOutCount, uint256 totalSupply, uint256 surplus)` | Returns the reclaimable surplus given raw total supply and surplus values. Applies bonding curve from current ruleset. |
| `currentReclaimableSurplusOf(uint256 projectId, uint256 cashOutCount, IJBTerminal[] terminals, address[] tokens, uint256 decimals, uint256 currency)` | Returns the reclaimable surplus across specified terminals and tokens. Empty arrays default to all. |
| `currentTotalReclaimableSurplusOf(uint256 projectId, uint256 cashOutCount, uint256 decimals, uint256 currency)` | Convenience view: reclaimable surplus across all terminals and all tokens. |
| `currentSurplusOf(uint256 projectId, IJBTerminal[] terminals, address[] tokens, uint256 decimals, uint256 currency)` | Returns the current surplus across specified terminals and tokens. Empty arrays default to all. |
| `currentTotalSurplusOf(uint256 projectId, uint256 decimals, uint256 currency)` | Convenience view: total surplus across all terminals and all tokens. |
| `previewPayFrom(address terminal, address payer, JBTokenAmount amount, uint256 projectId, address beneficiary, bytes metadata)` | Simulates a payment without modifying state. Uses the explicit `terminal` parameter for balance/surplus lookups. Invokes data hooks if configured. Returns ruleset, token count, and hook specifications. |
| `previewCashOutFrom(address terminal, address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, bool beneficiaryIsFeeless, bytes metadata)` | Simulates a cash out without modifying state. Uses the explicit `terminal` parameter for balance/surplus lookups. Invokes data hooks if configured, including any pricing-only adjustments they return. Returns ruleset, reclaim amount, tax rate, and hook specifications. |

### JBRulesets

| Function | What it does |
|----------|--------------|
| `currentOf(uint256 projectId)` | Returns the currently active ruleset with decayed weight and correct cycle number. |
| `latestQueuedOf(uint256 projectId)` | Returns the latest queued ruleset and its approval status. |
| `queueFor(uint256 projectId, uint256 duration, uint256 weight, uint256 weightCutPercent, IJBRulesetApprovalHook approvalHook, uint256 metadata, uint256 mustStartAtOrAfter)` | Queues a new ruleset. Only callable by the project's controller. |
| `updateRulesetWeightCache(uint256 projectId, uint256 rulesetId)` | Updates the weight cache for long-running rulesets. Required when `weightCutMultiple > 20,000` to avoid gas limits. |

### JBPermissions

| Function | What it does |
|----------|--------------|
| `setPermissionsFor(address account, JBPermissionsData permissionsData)` | Grants or revokes operator permissions. ROOT operators can set non-ROOT permissions for others. |
| `hasPermission(address operator, address account, uint256 projectId, uint256 permissionId, bool includeRoot, bool includeWildcardProjectId)` | Checks if an operator has a specific permission. |
| `hasPermissions(address operator, address account, uint256 projectId, uint256[] permissionIds, bool includeRoot, bool includeWildcardProjectId)` | Checks if an operator has all specified permissions. |

### JBDirectory

| Function | What it does |
|----------|--------------|
| `controllerOf(uint256 projectId)` | Returns the project's controller as `IERC165`. |
| `terminalsOf(uint256 projectId)` | Returns the project's terminals as `IJBTerminal[]`. |
| `primaryTerminalOf(uint256 projectId, address token)` | Returns the project's primary terminal for a given token. |
| `isTerminalOf(uint256 projectId, IJBTerminal terminal)` | Checks if a terminal belongs to a project. |
| `setControllerOf(uint256 projectId, IERC165 controller)` | Sets the project's controller. |
| `setTerminalsOf(uint256 projectId, IJBTerminal[] terminals)` | Sets the project's terminals. |
| `setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal)` | Sets the primary terminal for a token. Requires `ADD_TERMINALS` permission if the terminal is not already in the project's terminal list (implicit addition). |
| `setIsAllowedToSetFirstController(address addr, bool flag)` | Allows/disallows an address to set a project's first controller. Owner-only. |

### JBPrices

| Function | What it does |
|----------|--------------|
| `pricePerUnitOf(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, uint256 decimals)` | Returns the price of 1 `unitCurrency` in `pricingCurrency`. Checks project-specific, inverse, then default feeds. |
| `addPriceFeedFor(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed)` | Registers a price feed. Project ID 0 sets protocol-wide defaults (owner-only). Immutable once set. |

### JBTokens

| Function | What it does |
|----------|--------------|
| `totalSupplyOf(uint256 projectId)` | Returns total supply: credits + ERC-20 tokens. |
| `totalBalanceOf(address holder, uint256 projectId)` | Returns combined credit + ERC-20 balance. |
| `creditBalanceOf(address holder, uint256 projectId)` | Returns the holder's credit balance. |
| `tokenOf(uint256 projectId)` | Returns the ERC-20 token for a project (`IJBToken`). |
| `setTokenMetadataFor(uint256 projectId, string name, string symbol)` | Sets the name and symbol of a project's token. Controller-only. |

### JBSplits

| Function | What it does |
|----------|--------------|
| `splitsOf(uint256 projectId, uint256 rulesetId, uint256 groupId)` | Returns splits for a project/ruleset/group. Falls back to ruleset ID 0 if none set. |

**Self-auth for `setSplitGroupsOf`**: A contract can set its own split groups without controller authorization if the lower 160 bits of the `groupId` match `msg.sender` AND the upper 96 bits are non-zero. GroupIds with zero upper 96 bits (bare addresses like `uint256(uint160(token))`) are protocol-reserved for terminal payout groups and always require controller auth.

### Other

| Function | What it does |
|----------|--------------|
| `setFeelessAddress(address addr, bool flag)` | Adds or removes an address from the fee exemption list. Owner-only. (`JBFeelessAddresses`) |
| `setControllerAllowed(uint256 projectId)` | Returns whether a project's controller can currently be set. (`IJBDirectoryAccessControl`) |
| `setTerminalsAllowed(uint256 projectId)` | Returns whether a project's terminals can currently be set. (`IJBDirectoryAccessControl`) |
