# Administration

Admin privileges and their scope in nana-core-v6.

## Roles

### Project Owner

- **How assigned:** Holds the ERC-721 NFT minted by `JBProjects.createFor()`. Transferable via standard ERC-721 transfer.
- **Scope:** Controls a single project. The owner's address is `PROJECTS.ownerOf(projectId)`. Operators can be granted subsets of the owner's permissions via `JBPermissions`.

### Controller

- **How assigned:** Set via `JBDirectory.setControllerOf()`. The controller is stored as `controllerOf[projectId]` in JBDirectory. Typically a `JBController` instance.
- **Scope:** Manages a single project's rulesets, tokens, splits, and fund access limits. Contracts gated by `onlyControllerOf(projectId)` (from `JBControlled`) only accept calls from the address registered as the project's controller in the directory.

### Terminal

- **How assigned:** Set via `JBDirectory.setTerminalsOf()`. Stored in the directory's `_terminalsOf[projectId]` array.
- **Scope:** Manages fund inflows and outflows for a single project. Terminal identity is verified via `DIRECTORY.isTerminalOf()`. Terminals interact with `JBTerminalStore` using `msg.sender`-scoped bookkeeping -- each terminal can only modify its own balances.

### Operator

- **How assigned:** Granted permissions by any address via `JBPermissions.setPermissionsFor()`. Permissions are stored as a packed `uint256` bitmap per `(operator, account, projectId)` tuple.
- **Scope:** Can execute specific functions on behalf of the account that granted them permissions, scoped to a specific project ID (or all projects if `projectId = 0` wildcard is used).

### ROOT Permission Holder

- **How assigned:** Granted the ROOT permission (ID 255) by an account via `JBPermissions`. ROOT on a specific project grants all permissions for that project. ROOT cannot be granted on the wildcard project ID (0) to prevent unlimited cross-project access.
- **Scope:** ROOT holders for a project can do anything the project owner can do for that project. ROOT holders can also grant non-ROOT permissions to other operators for the same project but cannot grant ROOT to others or set wildcard permissions.

### Directory Owner

- **How assigned:** Set at JBDirectory deployment via the Ownable constructor. Transferable via `Ownable.transferOwnership()`.
- **Scope:** Protocol-wide. Controls which addresses are allowed to set a project's first controller (`isAllowedToSetFirstController`).

### JBProjects Owner

- **How assigned:** Set at JBProjects deployment via the Ownable constructor. Transferable via `Ownable.transferOwnership()`.
- **Scope:** Protocol-wide. Can set the `tokenUriResolver` that resolves project NFT metadata URIs.

### JBPrices Owner

- **How assigned:** Set at JBPrices deployment via the Ownable constructor. Transferable via `Ownable.transferOwnership()`.
- **Scope:** Protocol-wide. Can add default price feeds (project ID 0) that apply to all projects as fallback.

### JBFeelessAddresses Owner

- **How assigned:** Set at JBFeelessAddresses deployment via the Ownable constructor. Transferable via `Ownable.transferOwnership()`.
- **Scope:** Protocol-wide. Controls which addresses are exempt from protocol fees.

### JBERC20 Owner

- **How assigned:** Set to the `JBTokens` contract address when a project's ERC-20 is deployed or initialized.
- **Scope:** Single token contract. Only the owner (JBTokens) can mint and burn tokens.

### Omnichain Ruleset Operator

- **How assigned:** Immutable address set in the `JBController` constructor as `OMNICHAIN_RULESET_OPERATOR`.
- **Scope:** Can call `launchRulesetsFor` and `queueRulesetsOf` on any project, bypassing owner permission checks. This allows the omnichain deployer to synchronize rulesets across chains.

### Data Hook

- **How assigned:** Specified in a ruleset's metadata as the `dataHook` address. Active only during the ruleset it is configured for.
- **Scope:** Can mint tokens via `JBController.mintTokensOf()` when the data hook reports `hasMintPermissionFor()` returns true. Also controls pay/cashout hook specifications returned from `JBTerminalStore`.

### Fee Beneficiary (Project ID 1)

- **How assigned:** Hardcoded as `_FEE_BENEFICIARY_PROJECT_ID = 1` in JBMultiTerminal.
- **Scope:** Receives all protocol fees (2.5%) from payouts, surplus allowance usage, and cash outs with non-zero tax rates. This is the first project created during deployment.

## Privileged Functions

### JBPermissions

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `setPermissionsFor` | Account owner, or ROOT operator for that account+project | ROOT (1) | Per account + project | Sets the permission bitmap for an operator. ROOT operators can set non-ROOT permissions for the same project but cannot grant ROOT or set wildcard project permissions. |

### JBProjects

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `setTokenUriResolver` | Contract owner | N/A (onlyOwner) | Protocol-wide | Sets the contract that resolves token URIs for all project NFTs. |
| `createFor` | Anyone | N/A | N/A | Creates a new project NFT. No permission required -- anyone can create a project for any owner. |

### JBDirectory

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `setControllerOf` | Project owner or operator, OR an `isAllowedToSetFirstController` address (for first controller only) | SET_CONTROLLER (14) | Per project | Sets or migrates a project's controller. Also requires the current ruleset's `allowSetController` flag to be true (unless setting the first controller). Triggers migration lifecycle hooks on both old and new controllers. |
| `setIsAllowedToSetFirstController` | Contract owner | N/A (onlyOwner) | Protocol-wide | Adds or removes an address from the allowlist of addresses that can set a project's first controller. |
| `setPrimaryTerminalOf` | Project owner or operator | SET_PRIMARY_TERMINAL (16) | Per project | Sets which terminal is the default for a given token. Adds the terminal to the project if not already present. |
| `setTerminalsOf` | Project owner, operator, or the project's controller | SET_TERMINALS (15) | Per project | Replaces the entire list of terminals for a project. If the caller is not the controller, the ruleset must have `allowSetTerminals` enabled. |

### JBController

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `addPriceFeed` | Project owner or operator | ADD_PRICE_FEED (19) | Per project | Adds a price feed for a project. Requires the ruleset's `allowAddPriceFeed` flag. Price feeds are immutable once set. |
| `burnTokensOf` | Token holder, operator with BURN_TOKENS, or a project terminal | BURN_TOKENS (11) | Per project | Burns tokens or credits from a holder's balance. Terminals can burn without explicit permission (for cash outs). |
| `claimTokensFor` | Credit holder or operator | CLAIM_TOKENS (12) | Per project | Redeems internal credits for ERC-20 tokens. |
| `deployERC20For` | Project owner or operator | DEPLOY_ERC20 (8) | Per project | Deploys a new ERC-20 token contract for the project. Can only be called once per project. |
| `launchProjectFor` | Anyone | N/A | N/A | Creates a new project, sets this controller, configures terminals, and queues initial rulesets. No permission required. |
| `launchRulesetsFor` | Project owner, operator, or OMNICHAIN_RULESET_OPERATOR | LAUNCH_RULESETS (3) + SET_TERMINALS (15) | Per project | Queues initial rulesets and configures terminals for an existing project that has no rulesets yet. Also sets this contract as the project's controller. |
| `mintTokensOf` | Project owner, operator, terminal, or data hook (with mint permission) | MINT_TOKENS (10) | Per project | Mints new tokens. If the caller is not a terminal or data hook, the ruleset must have `allowOwnerMinting` enabled. |
| `queueRulesetsOf` | Project owner, operator, or OMNICHAIN_RULESET_OPERATOR | QUEUE_RULESETS (2) | Per project | Queues new rulesets at the end of the project's ruleset queue. |
| `sendReservedTokensToSplitsOf` | Anyone | N/A | Per project | Distributes accumulated reserved tokens to the project's reserved token split group. No permission required -- anyone can trigger this. |
| `setSplitGroupsOf` | Project owner or operator | SET_SPLIT_GROUPS (18) | Per project | Sets split groups for a project. Must preserve any currently locked splits. |
| `setTokenFor` | Project owner or operator | SET_TOKEN (9) | Per project | Assigns an external ERC-20 token to the project. Requires the ruleset's `allowSetCustomToken` flag. Can only be called once (before any token is set). |
| `setUriOf` | Project owner or operator | SET_PROJECT_URI (7) | Per project | Updates the project's metadata URI. |
| `transferCreditsFrom` | Credit holder or operator | TRANSFER_CREDITS (13) | Per project | Transfers internal token credits between addresses. Requires the ruleset's `pauseCreditTransfers` flag to be false. |
| `migrate` | JBDirectory only | N/A (msg.sender == DIRECTORY) | Per project | Called by the directory during controller migration. Reverts if there are pending reserved tokens. |
| `beforeReceiveMigrationFrom` | JBDirectory only | N/A (msg.sender == DIRECTORY) | Per project | Called before migration to prepare the new controller. Copies metadata URI and distributes pending reserved tokens from the old controller. |
| `afterReceiveMigrationFrom` | JBDirectory only | N/A (msg.sender == DIRECTORY) | Per project | Called after migration completes. Currently a no-op. |
| `executePayReservedTokenToTerminal` | Self only | N/A (msg.sender == address(this)) | Internal | Pays a terminal with reserved tokens. Called internally via try-catch during reserved token distribution. |

### JBMultiTerminal

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `addAccountingContextsFor` | Project owner, operator, or the project's controller | ADD_ACCOUNTING_CONTEXTS (20) | Per project | Adds tokens that the terminal will accept for a project. Requires the ruleset's `allowAddAccountingContext` flag (if a ruleset exists). |
| `cashOutTokensOf` | Token holder or operator | CASH_OUT_TOKENS (4) | Per project | Cashes out project tokens for a share of the project's surplus. Fees are charged unless the beneficiary is feeless or the cash out tax rate is zero. |
| `migrateBalanceOf` | Project owner or operator | MIGRATE_TERMINAL (6) | Per project | Migrates a project's balance from this terminal to another. The destination terminal must accept the same token. The ruleset must have `allowTerminalMigration` enabled (checked in JBTerminalStore). |
| `sendPayoutsOf` | Anyone (unless `ownerMustSendPayouts` is set) | SEND_PAYOUTS (5) if `ownerMustSendPayouts` | Per project | Sends payouts to the project's payout split group up to the payout limit. Anyone can call unless the ruleset has `ownerMustSendPayouts` enabled, which requires the project owner or an operator with SEND_PAYOUTS permission. |
| `useAllowanceOf` | Project owner or operator | USE_ALLOWANCE (17) | Per project | Withdraws funds from the project's surplus up to the surplus allowance. Fees are charged unless the owner or beneficiary is feeless. |
| `pay` | Anyone | N/A | N/A | Pays a project with tokens. No permission required. |
| `addToBalanceOf` | Anyone | N/A | N/A | Adds funds to a project's balance without minting tokens. Can optionally return held fees. No permission required. |
| `processHeldFeesOf` | Anyone | N/A | Per project | Processes held fees that have passed their 28-day unlock period. No permission required. |
| `executePayout` | Self only | N/A (msg.sender == address(this)) | Internal | Executes a single payout to a split. Called internally via try-catch during payout distribution. |
| `executeProcessFee` | Self only | N/A (msg.sender == address(this)) | Internal | Processes a fee payment to the fee beneficiary project. Called internally via try-catch. |
| `executeTransferTo` | Self only | N/A (msg.sender == address(this)) | Internal | Transfers tokens to an address. Called internally via try-catch during payout leftover distribution. |

### JBTokens

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `burnFrom` | Project's controller | N/A (onlyControllerOf) | Per project | Burns tokens and/or credits from a holder. Credits are burned first, then ERC-20 tokens. |
| `claimTokensFor` | Project's controller | N/A (onlyControllerOf) | Per project | Converts credits to ERC-20 tokens for a holder. |
| `deployERC20For` | Project's controller | N/A (onlyControllerOf) | Per project | Deploys a cloned JBERC20 token for the project. |
| `mintFor` | Project's controller | N/A (onlyControllerOf) | Per project | Mints new tokens (ERC-20 if deployed) or credits for a holder. |
| `setTokenFor` | Project's controller | N/A (onlyControllerOf) | Per project | Sets an external ERC-20 token for the project. Cannot be changed once set. |
| `transferCreditsFrom` | Project's controller | N/A (onlyControllerOf) | Per project | Transfers credits between addresses. |

### JBSplits

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `setSplitGroupsOf` | Project's controller, OR the address whose first 160 bits match the group ID (for self-namespaced splits) | N/A (onlyControllerOf or msg.sender namespace) | Per project | Sets split groups for a project/ruleset. Must preserve any currently locked splits. Percentage total per group must not exceed 100%. |

### JBFundAccessLimits

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `setFundAccessLimitsFor` | Project's controller | N/A (onlyControllerOf) | Per project | Sets payout limits and surplus allowances for a project's ruleset. Limits must be in strictly increasing currency order. |

### JBRulesets

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `queueFor` | Project's controller | N/A (onlyControllerOf) | Per project | Queues a new ruleset with specified duration, weight, weight cut percent, approval hook, and metadata. |
| `updateRulesetWeightCache` | Anyone | N/A | Per project | Updates the cached weight for a ruleset to avoid excessive iteration. No permission required -- anyone can call this maintenance function. |

### JBPrices

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `addPriceFeedFor` | Contract owner (for project ID 0 defaults) or project's controller (for project-specific feeds) | N/A (onlyOwner or onlyControllerOf) | Protocol-wide or per project | Adds an immutable price feed for a currency pair. Default feeds (project 0) apply as fallback for all projects. |

### JBFeelessAddresses

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `setFeelessAddress` | Contract owner | N/A (onlyOwner) | Protocol-wide | Marks an address as feeless or not. Feeless addresses do not incur the 2.5% protocol fee on payouts, surplus allowance usage, or cash outs. |

### JBERC20

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `mint` | Contract owner (JBTokens) | N/A (onlyOwner) | Per token | Mints new tokens to an address. |
| `burn` | Contract owner (JBTokens) | N/A (onlyOwner) | Per token | Burns tokens from an address. |
| `initialize` | Anyone (once) | N/A | Per token | Initializes the token name, symbol, and owner. Can only be called once. |

### JBTerminalStore

JBTerminalStore has no explicit access control modifiers. Instead, it uses `msg.sender`-scoped storage -- each terminal can only read and write its own balance slots. The functions are designed to be called by terminal contracts:

| Function | Implicit Caller | What It Does |
|----------|----------------|-------------|
| `recordAddedBalanceFor` | Any address (terminal) | Increments the caller's recorded balance for a project/token. |
| `recordCashOutFor` | Any address (terminal) | Records a cash out, calculating reclaim amounts via bonding curve. Decrements the caller's balance. |
| `recordPaymentFrom` | Any address (terminal) | Records a payment, calculating token issuance via weight. Increments the caller's balance. |
| `recordPayoutFor` | Any address (terminal) | Records a payout against payout limits. Decrements the caller's balance. |
| `recordTerminalMigration` | Any address (terminal) | Records a full balance migration. Requires the ruleset's `allowTerminalMigration` flag. Zeros out the caller's balance. |
| `recordUsedAllowanceOf` | Any address (terminal) | Records surplus allowance usage. Decrements the caller's balance. |

## Permission System

JBPermissions implements a 256-bit packed permission bitmap system:

- **256 permission slots**: Each bit in a `uint256` represents one permission. Bit 0 is reserved (cannot be set). Bits 1-255 are available for permission IDs.
- **ROOT permission (ID 1)**: Acts as a superuser for the granted project. A ROOT operator passes all permission checks for that project via `includeRoot: true`.
- **Wildcard project ID (0)**: Granting a permission on project ID 0 makes it apply to all projects for that account. ROOT cannot be granted on the wildcard project ID to prevent unlimited cross-project access.
- **Operator delegation**: Any address can grant any other address specific permissions. The `_requirePermissionFrom` check passes if `msg.sender == account` OR if the sender has the required permission (with ROOT fallback and wildcard fallback).
- **Override pattern**: `_requirePermissionAllowingOverrideFrom` adds an `alsoGrantAccessIf` boolean that bypasses the permission check entirely when true. This is used to allow terminals, controllers, and data hooks to call privileged functions without explicit operator permissions.

### Permission IDs Used in nana-core-v6

| ID | Name | Function It Gates |
|----|------|-------------------|
| 1 | ROOT | All permissions. Also allows setting non-ROOT permissions for others on the same project. |
| 2 | QUEUE_RULESETS | `JBController.queueRulesetsOf` |
| 3 | LAUNCH_RULESETS | `JBController.launchRulesetsFor` |
| 4 | CASH_OUT_TOKENS | `JBMultiTerminal.cashOutTokensOf` |
| 5 | SEND_PAYOUTS | `JBMultiTerminal.sendPayoutsOf` (only when `ownerMustSendPayouts` is set) |
| 6 | MIGRATE_TERMINAL | `JBMultiTerminal.migrateBalanceOf` |
| 7 | SET_PROJECT_URI | `JBController.setUriOf` |
| 8 | DEPLOY_ERC20 | `JBController.deployERC20For` |
| 9 | SET_TOKEN | `JBController.setTokenFor` |
| 10 | MINT_TOKENS | `JBController.mintTokensOf` |
| 11 | BURN_TOKENS | `JBController.burnTokensOf` |
| 12 | CLAIM_TOKENS | `JBController.claimTokensFor` |
| 13 | TRANSFER_CREDITS | `JBController.transferCreditsFrom` |
| 14 | SET_CONTROLLER | `JBDirectory.setControllerOf` |
| 15 | SET_TERMINALS | `JBDirectory.setTerminalsOf` |
| 16 | SET_PRIMARY_TERMINAL | `JBDirectory.setPrimaryTerminalOf` |
| 17 | USE_ALLOWANCE | `JBMultiTerminal.useAllowanceOf` |
| 18 | SET_SPLIT_GROUPS | `JBController.setSplitGroupsOf` |
| 19 | ADD_PRICE_FEED | `JBController.addPriceFeed` |
| 20 | ADD_ACCOUNTING_CONTEXTS | `JBMultiTerminal.addAccountingContextsFor` |

## Immutable Configuration

The following values are set at deploy time and cannot be changed:

### JBController
- `DIRECTORY` -- the directory contract
- `FUND_ACCESS_LIMITS` -- the fund access limits contract
- `PERMISSIONS` -- the permissions contract (from JBPermissioned)
- `PRICES` -- the prices contract
- `PROJECTS` -- the projects NFT contract
- `RULESETS` -- the rulesets contract
- `SPLITS` -- the splits contract
- `TOKENS` -- the tokens contract
- `OMNICHAIN_RULESET_OPERATOR` -- the address allowed to launch/queue rulesets for any project

### JBMultiTerminal
- `DIRECTORY` -- derived from STORE.DIRECTORY()
- `FEELESS_ADDRESSES` -- the feeless addresses registry
- `FEE` -- hardcoded at 25 (2.5% of MAX_FEE=1000)
- `PERMISSIONS` -- the permissions contract
- `PERMIT2` -- the Uniswap Permit2 contract
- `PROJECTS` -- the projects NFT contract
- `RULESETS` -- derived from STORE.RULESETS()
- `SPLITS` -- the splits contract
- `STORE` -- the terminal store contract
- `TOKENS` -- the tokens contract
- `_FEE_BENEFICIARY_PROJECT_ID` -- hardcoded as 1
- `_FEE_HOLDING_SECONDS` -- hardcoded as 2,419,200 (28 days)

### JBDirectory
- `PERMISSIONS` -- the permissions contract
- `PROJECTS` -- the projects NFT contract

### JBPrices
- `DIRECTORY` -- the directory contract
- `PERMISSIONS` -- the permissions contract
- `PROJECTS` -- the projects NFT contract
- Price feeds are immutable once set (cannot be replaced or removed)

### JBTokens
- `DIRECTORY` -- the directory contract
- `TOKEN` -- the JBERC20 implementation used for cloning
- Project token assignments are immutable once set (cannot be changed to a different token)

### JBRulesets
- `DIRECTORY` -- the directory contract

### JBSplits
- `DIRECTORY` -- the directory contract

### JBFundAccessLimits
- `DIRECTORY` -- the directory contract

### JBTerminalStore
- `DIRECTORY` -- the directory contract
- `PRICES` -- the prices contract
- `RULESETS` -- the rulesets contract

### JBPermissions
- Trusted forwarder for ERC-2771 meta-transactions

## Ruleset Flags That Gate Admin Actions

Several admin functions are further gated by boolean flags in the active ruleset's metadata. These flags are set when the ruleset is queued and cannot be changed until a new ruleset takes effect:

| Flag | What It Gates |
|------|--------------|
| `allowOwnerMinting` | Whether the project owner/operator can call `mintTokensOf`. Terminals and data hooks can always mint regardless. |
| `allowSetCustomToken` | Whether `setTokenFor` can be called. |
| `allowTerminalMigration` | Whether `migrateBalanceOf` / `recordTerminalMigration` can proceed. |
| `allowSetTerminals` | Whether `setTerminalsOf` can be called by non-controller callers. |
| `allowSetController` | Whether `setControllerOf` can be called (checked via `IJBDirectoryAccessControl`). |
| `allowAddAccountingContext` | Whether `addAccountingContextsFor` can add new token contexts. |
| `allowAddPriceFeed` | Whether `addPriceFeed` can add new price feeds. |
| `ownerMustSendPayouts` | Whether `sendPayoutsOf` requires SEND_PAYOUTS permission (otherwise anyone can call it). |
| `pausePay` | Whether payments are paused (checked in JBTerminalStore). |
| `pauseCreditTransfers` | Whether credit transfers are paused. |
| `holdFees` | Whether fees are held (deferred for 28 days) instead of being processed immediately. |

## Admin Boundaries

What admins CANNOT do:

- **Project owners cannot access other projects' funds.** All permission checks are scoped to a specific `projectId`. A project owner's permissions only apply to their own project.
- **Controllers cannot bypass terminal accounting.** JBTerminalStore uses `msg.sender`-scoped balances. A controller cannot directly manipulate a terminal's recorded balances -- only the terminal itself can update its own balance slots.
- **Terminals cannot mint tokens without controller involvement.** Token minting goes through the controller's `mintTokensOf`, which enforces ruleset rules (reserved percent, `allowOwnerMinting`).
- **No single admin can change the fee rate.** The fee (2.5%) is hardcoded as a constant in JBMultiTerminal. Changing it requires deploying a new terminal contract.
- **No admin can change the fee beneficiary.** Project ID 1 is hardcoded as the fee recipient. This cannot be changed.
- **Price feeds cannot be replaced.** Once a price feed is set for a currency pair (in either direction), it is permanent for that project ID. Recovery requires deploying a new JBPrices contract.
- **Token assignments are one-way.** Once a project's ERC-20 token is set (via `deployERC20For` or `setTokenFor`), it cannot be changed to a different token.
- **Locked splits cannot be removed.** Splits with a `lockedUntil` timestamp in the future must be preserved (with the same or extended lock) when updating split groups.
- **Operators cannot escalate to ROOT via ROOT.** A ROOT operator can set permissions for other operators on the same project but cannot grant ROOT to them or set permissions on the wildcard project ID.
- **The directory owner cannot set controllers directly.** The directory owner can only manage the `isAllowedToSetFirstController` allowlist. They cannot set or change a project's controller.
- **Ruleset approval hooks can block changes.** If a ruleset specifies an approval hook, queued rulesets must be approved by that hook before they take effect. A rejected ruleset falls back to the previous approved ruleset's cycling behavior.
- **Reserved tokens must be distributed before controller migration.** The `migrate` function reverts if `pendingReservedTokenBalanceOf[projectId] > 0`, preventing loss of reserved tokens during migration.
- **The JBTerminalStore has no admin functions.** It has no owner, no permission checks, and no special roles. Access is controlled entirely by the msg.sender-scoped storage pattern -- callers can only affect their own balance slots.
