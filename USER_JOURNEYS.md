# nana-core-v6 -- User Journeys

All user paths through the Juicebox V6 core protocol. For each journey: entry point, key parameters, state changes, events, and edge cases.

---

## 1. Launch Project

**Entry point**: `JBController.launchProjectFor(address owner, string projectUri, JBRulesetConfig[] rulesetConfigurations, JBTerminalConfig[] terminalConfigurations, string memo)`

**Who can call**: Anyone. The project ERC-721 is minted to the specified `owner`.

**Parameters**:
- `owner` -- Address that receives the project ERC-721 NFT
- `projectUri` -- Metadata URI (typically IPFS hash)
- `rulesetConfigurations` -- Array of `JBRulesetConfig` structs defining the project's economic rules
- `terminalConfigurations` -- Array of `JBTerminalConfig` structs specifying which terminals accept which tokens
- `memo` -- Arbitrary string emitted in the event

**State changes**:
1. `JBProjects.createFor(owner)` -- Mints ERC-721, increments project count, returns `projectId`
2. `uriOf[projectId] = projectUri` -- Stores metadata URI (if non-empty)
3. `JBDirectory.setControllerOf(projectId, controller)` -- Sets this controller as the project's controller
4. For each terminal config: `terminal.addAccountingContextsFor(projectId, contexts)` -- Registers accepted tokens
5. `JBDirectory.setTerminalsOf(projectId, terminals)` -- Registers terminals
6. For each ruleset config:
   - `JBRulesets.queueFor(...)` -- Creates ruleset with packed intrinsic/user properties and metadata
   - `JBSplits.setSplitGroupsOf(...)` -- Stores split groups for the ruleset
   - `JBFundAccessLimits.setFundAccessLimitsFor(...)` -- Stores payout limits and surplus allowances

**Events**: `LaunchProject(rulesetId, projectId, projectUri, memo, caller)`

**Edge cases**:
- Empty `rulesetConfigurations` array is valid -- project launches with no rulesets (cannot receive payments until rulesets are launched via `launchRulesetsFor`)
- Multiple rulesets can be queued in a single launch -- they form a linked list
- If `block.timestamp` collision occurs for rulesetId, the ID is incremented by 1

---

## 2. Pay a Project

**Entry point**: `JBMultiTerminal.pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)`

**Who can call**: Anyone.

**Parameters**:
- `projectId` -- The project to pay
- `token` -- Token address (`JBConstants.NATIVE_TOKEN` for ETH)
- `amount` -- Amount of tokens (ignored for native token; uses `msg.value`)
- `beneficiary` -- Address to receive minted project tokens
- `minReturnedTokens` -- Slippage protection; reverts if fewer tokens minted
- `memo` -- Arbitrary string
- `metadata` -- Bytes; may contain Permit2 data (keyed by `"permit2"` ID) and/or hook-specific data

**State changes**:
1. Tokens transferred to terminal (or `msg.value` accepted)
2. `JBTerminalStore.balanceOf[terminal][projectId][token]` incremented (minus any hook-diverted amounts)
3. `JBTokens` mints project tokens to beneficiary (credits or ERC-20)
4. `JBController.pendingReservedTokenBalanceOf[projectId]` incremented by reserved portion
5. Pay hooks execute (if data hook returns specifications)

**Events**: `Pay(rulesetId, rulesetCycleNumber, projectId, payer, beneficiary, amount, newlyIssuedTokenCount, memo, metadata, caller)`

**Edge cases**:
- `amount = 0` is valid -- records a zero payment, mints 0 tokens
- `beneficiary = address(0)` -- tokens minted to zero address (effectively burned on mint)
- If `pausePay` is set in ruleset metadata, `recordPaymentFrom` reverts
- Token count = `mulDiv(amount.value, weight, weightRatio)` -- if weight is 0, no tokens minted
- Data hook can return empty weight (0) to suppress minting while still recording payment
- Fee-on-transfer tokens: actual amount received is `_balanceOf(token) - balanceBefore` (measured via balance diff)

---

## 3. Cash Out Tokens

**Entry point**: `JBMultiTerminal.cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address payable beneficiary, bytes metadata)`

**Who can call**: The token holder, or an address with the holder's `CASH_OUT_TOKENS` permission.

**Parameters**:
- `holder` -- Address whose tokens are being cashed out
- `projectId` -- The project to cash out from
- `cashOutCount` -- Number of project tokens to burn (18 decimals)
- `tokenToReclaim` -- Terminal token to receive back
- `minTokensReclaimed` -- Slippage protection
- `beneficiary` -- Address to receive reclaimed tokens
- `metadata` -- Hook-specific data

**State changes**:
1. `JBTerminalStore.balanceOf[terminal][projectId][token]` decremented by `reclaimAmount + hookSpec amounts`
2. Project tokens burned via `JBController.burnTokensOf()` (credits first, then ERC-20)
3. Reclaimed tokens transferred to beneficiary
4. Cash out hooks execute (if data hook returns specifications)
5. Fee taken (2.5%) on total amount eligible for fees, unless beneficiary is feeless or (`cashOutTaxRate == 0` and the project has never received a fee-free intra-terminal payout)

**Events**: `CashOutTokens(rulesetId, rulesetCycleNumber, projectId, holder, beneficiary, cashOutCount, cashOutTaxRate, reclaimAmount, metadata, caller)`

**Edge cases**:
- `cashOutCount = 0` with `totalSupply = 0` -- returns entire surplus (C-5 known bug)
- `cashOutTaxRate = MAX (10,000)` -- returns 0 (all surplus locked)
- `cashOutTaxRate = 0` -- proportional (1:1 against supply) with no discount
- `cashOutCount >= totalSupply` -- returns entire surplus regardless of tax rate
- Data hook can override `cashOutTaxRate`, `cashOutCount`, `totalSupply` to arbitrary values
- Fee is NOT taken when `cashOutTaxRate == 0` UNLESS the project has received a fee-free intra-terminal payout (`_hasReceivedFeeFreePayout` flag). This prevents round-trip fee bypass.
- Pending reserved tokens inflate `totalSupply`, reducing individual cash out value (H-4)

---

## 4. Send Payouts to Splits

**Entry point**: `JBMultiTerminal.sendPayoutsOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut)`

**Who can call**: Anyone (unless `ownerMustSendPayouts` is set, then requires `SEND_PAYOUTS` permission from owner).

**Parameters**:
- `projectId` -- The project distributing payouts
- `token` -- Token being distributed
- `amount` -- Amount to distribute (in terms of `currency`)
- `currency` -- Currency denomination of the amount; must match a configured payout limit's currency
- `minTokensPaidOut` -- Slippage protection on the actual token amount paid out

**State changes**:
1. `JBTerminalStore.balanceOf` decremented by `amountPaidOut` (currency-converted)
2. `JBTerminalStore.usedPayoutLimitOf` incremented
3. For each split: funds transferred (split hooks, project terminals, or addresses)
4. Failed splits: amount returned to project balance via `recordAddedBalanceFor`
5. Leftover (if splits < 100%): sent to project owner
6. Fee taken on all non-feeless payouts

**Events**: `SendPayouts(rulesetId, rulesetCycleNumber, projectId, projectOwner, amount, amountPaidOut, fee, netLeftoverPayoutAmount, caller)`, `SendPayoutToSplit(...)` per split

**Edge cases**:
- `amount > payout limit` -- reverts with `InadequateControllerPayoutLimit`. Does NOT auto-cap.
- Empty `fundAccessLimitGroups` for the terminal/token = zero payout limit = always reverts
- Currency conversion uses `JBPrices` if `currency != accountingContext.currency`
- Payout limit resets each ruleset cycle (`cycleNumber`)
- `ownerMustSendPayouts` flag gates who can trigger payouts
- Individual split failures are caught by try-catch; the payout continues to remaining splits
- Split percentage uses `mulDiv(amount, split.percent, leftoverPercentage)` -- each split gets its proportion of the remaining amount, not of the original total

---

## 5. Use Surplus Allowance

**Entry point**: `JBMultiTerminal.useAllowanceOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut, address payable beneficiary, address payable feeBeneficiary, string memo)`

**Who can call**: Project owner or address with `USE_ALLOWANCE` permission.

**Parameters**:
- `projectId`, `token`, `amount`, `currency` -- What to withdraw and in what denomination
- `minTokensPaidOut` -- Slippage protection on net amount after fees
- `beneficiary` -- Receives the withdrawn surplus
- `feeBeneficiary` -- Receives project #1 tokens minted from the fee payment
- `memo` -- Arbitrary string

**State changes**:
1. `JBTerminalStore.balanceOf` decremented by `usedAmount`
2. `JBTerminalStore.usedSurplusAllowanceOf` incremented
3. Fee taken (unless owner or beneficiary is feeless)
4. Net amount transferred to beneficiary

**Events**: `UseAllowance(rulesetId, rulesetCycleNumber, projectId, beneficiary, feeBeneficiary, amount, amountPaidOut, netAmountPaidOut, memo, caller)`

**Edge cases**:
- `usedAmount > surplus` -- reverts (`InadequateTerminalStoreBalance`)
- Surplus allowance resets each ruleset (keyed by `rulesetId`, not `cycleNumber`)
- Amount validated against surplus BEFORE checking allowance limit
- If both owner and beneficiary are feeless, no fee is taken

---

## 6. Mint Tokens (Owner)

**Entry point**: `JBController.mintTokensOf(uint256 projectId, uint256 tokenCount, address beneficiary, string memo, bool useReservedPercent)`

**Who can call**: Project owner, address with `MINT_TOKENS` permission, a project terminal, the data hook, or an address with `hasMintPermissionFor` from the data hook.

**Parameters**:
- `projectId` -- Target project
- `tokenCount` -- Total tokens to mint (including reserved portion)
- `beneficiary` -- Receives the non-reserved tokens
- `memo` -- Arbitrary string
- `useReservedPercent` -- If true, applies the ruleset's `reservedPercent`; if false, all tokens go to beneficiary

**State changes**:
1. `JBTokens.mintFor(beneficiary, beneficiaryTokenCount)` -- Mints non-reserved portion
2. `pendingReservedTokenBalanceOf[projectId]` incremented by reserved portion

**Events**: `MintTokens(beneficiary, projectId, tokenCount, beneficiaryTokenCount, memo, reservedPercent, caller)`

**Edge cases**:
- `tokenCount = 0` -- reverts (`ZeroTokensToMint`)
- If `allowOwnerMinting` is false in ruleset, only terminals and data hooks can mint
- If `reservedPercent = 10,000` (100%), all tokens go to pending reserved balance, `beneficiaryTokenCount = 0`
- Terminal calls this with `useReservedPercent = true` during payments

---

## 7. Burn Tokens

**Entry point**: `JBController.burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string memo)`

**Who can call**: The token holder, an address with the holder's `BURN_TOKENS` permission, or a project terminal.

**Parameters**:
- `holder` -- Address whose tokens to burn
- `projectId` -- Project whose tokens are being burned
- `tokenCount` -- Number of tokens to burn
- `memo` -- Arbitrary string

**State changes**:
1. Credits burned first (up to credit balance)
2. Remaining amount burned from ERC-20 balance (if any)
3. `JBTokens` reduces credit and/or ERC-20 supply

**Events**: `BurnTokens(holder, projectId, tokenCount, memo, caller)`

**Edge cases**:
- `tokenCount = 0` -- reverts (`ZeroTokensToBurn`)
- Credits are always burned first. If holder has 100 credits and 50 ERC-20, burning 120 burns all 100 credits + 20 ERC-20.
- Terminal calls this during cash outs

---

## 8. Queue New Ruleset

**Entry point**: `JBController.queueRulesetsOf(uint256 projectId, JBRulesetConfig[] rulesetConfigurations, string memo)`

**Who can call**: Project owner, address with `QUEUE_RULESETS` permission, or the `OMNICHAIN_RULESET_OPERATOR`.

**Parameters**:
- `projectId` -- Target project
- `rulesetConfigurations` -- Array of ruleset configs to queue
- `memo` -- Arbitrary string

**State changes**:
1. For each config:
   - `JBRulesets.queueFor(...)` -- Creates new ruleset in linked list
   - `JBSplits.setSplitGroupsOf(...)` -- Sets splits for the new ruleset
   - `JBFundAccessLimits.setFundAccessLimitsFor(...)` -- Sets limits for the new ruleset
2. `latestRulesetIdOf[projectId]` updated

**Events**: `QueueRulesets(rulesetId, projectId, memo, caller)`, `RulesetQueued(rulesetId, projectId, ...)`

**Edge cases**:
- Empty array reverts (`RulesetsArrayEmpty`)
- `reservedPercent > 10,000` reverts
- `cashOutTaxRate > 10,000` reverts
- `weight > type(uint112).max` reverts
- `duration > type(uint32).max` reverts
- `mustStartAtOrAfter + duration > type(uint48).max` reverts
- If `mustStartAtOrAfter = 0`, it defaults to `block.timestamp`
- If `rulesetId` collides with current timestamp, it is incremented by 1
- Approval hook address is validated: must have code, must support `IJBRulesetApprovalHook` interface
- Queued rulesets take effect after the current ruleset expires (or immediately for `duration = 0`)

---

## 9. Set Splits

**Entry point**: `JBController.setSplitGroupsOf(uint256 projectId, uint256 rulesetId, JBSplitGroup[] splitGroups)`

**Who can call**: Project owner or address with `SET_SPLIT_GROUPS` permission.

**Parameters**:
- `projectId` -- Target project
- `rulesetId` -- The ruleset ID the splits apply to. Use `0` for default/fallback splits.
- `splitGroups` -- Array of `JBSplitGroup` structs, each containing a `groupId` and `JBSplit[]`

**State changes**:
1. `JBSplits` stores the new split groups for the project/ruleset/group combination
2. Locked splits from existing configuration must be preserved (validated by `JBSplits`)

**Events**: Emitted by `JBSplits` (not `JBController`)

**Edge cases**:
- Locked splits (`lockedUntil > block.timestamp`) cannot be removed or modified
- If no splits set for a rulesetId, `splitsOf()` falls back to `rulesetId = 0` (default splits)
- If no default splits either, all payouts/reserved tokens go to project owner
- Split `percent` values are out of `SPLITS_TOTAL_PERCENT` (1,000,000,000)
- Payout splits use `groupId = uint256(uint160(token))`, reserved token splits use `groupId = 1` (`JBSplitGroupIds.RESERVED_TOKENS`)

---

## 10. Migrate Terminal

**Entry point**: `JBMultiTerminal.migrateBalanceOf(uint256 projectId, address token, IJBTerminal to)`

**Who can call**: Project owner or address with `MIGRATE_TERMINAL` permission.

**Parameters**:
- `projectId` -- Project being migrated
- `token` -- Token balance to migrate
- `to` -- Destination terminal

**State changes**:
1. `JBTerminalStore.balanceOf[oldTerminal][projectId][token]` set to 0
2. Funds transferred to destination terminal via `to.addToBalanceOf()`
3. Destination terminal records the added balance

**Events**: `MigrateTerminal(projectId, token, to, amount, caller)`

**Edge cases**:
- Requires `allowTerminalMigration` in current ruleset
- Destination terminal must have accounting context for the token (validated via `accountingContextForTokenOf`)
- **Held fees are NOT transferred** -- they remain in the old terminal. Held fees belong to the fee beneficiary (project #1), not the migrating project.
- If balance is 0, no transfer occurs
- This only migrates one token's balance. Must be called once per token.

---

## 11. Migrate Controller

**Entry point**: `JBDirectory.setControllerOf(uint256 projectId, IERC165 controller)`

**Who can call**: Project owner, address with `SET_CONTROLLER` permission, or an address in `isAllowedToSetFirstController` (for first controller only). The current controller's ruleset must have `allowSetController` enabled.

**Flow**:
1. `JBDirectory.setControllerOf(projectId, newController)` is called
2. Directory calls `newController.beforeReceiveMigrationFrom(oldController, projectId)`:
   - Copies metadata URI from old controller
   - Distributes pending reserved tokens from old controller
3. Directory calls `oldController.migrate(projectId, newController)`:
   - Reverts if pending reserved tokens > 0 (must distribute first)
4. Directory updates `controllerOf[projectId] = newController`
5. Directory calls `newController.afterReceiveMigrationFrom(oldController, projectId)`

**Events**: `Migrate(projectId, to, caller)` from old controller; `SetController(projectId, controller, caller)` from directory

**Edge cases**:
- `pendingReservedTokenBalanceOf[projectId] != 0` causes revert in `migrate()` -- reserved tokens must be distributed first
- `beforeReceiveMigrationFrom` automatically distributes pending reserved tokens from the old controller
- The old controller's `migrate()` runs while the directory still points to it (prevents reentrancy window)
- First controller can be set by addresses in `isAllowedToSetFirstController` without owner permission

---

## 12. Deploy ERC-20 for Project Tokens

**Entry point**: `JBController.deployERC20For(uint256 projectId, string name, string symbol, bytes32 salt)`

**Who can call**: Project owner or address with `DEPLOY_ERC20` permission.

**Parameters**:
- `projectId` -- Target project
- `name` -- ERC-20 token name
- `symbol` -- ERC-20 token symbol
- `salt` -- For deterministic deployment (CREATE2). Pass `bytes32(0)` for non-deterministic.

**State changes**:
1. `JBTokens.deployERC20For()` clones `JBERC20` implementation via `Clones.clone()` (or `Clones.cloneDeterministic()` if salt provided)
2. Clone's `initialize(name, symbol, owner=JBTokens)` is called
3. `JBTokens.tokenOf[projectId]` set to the new token

**Events**: `DeployERC20(projectId, deployer, salt, saltHash, caller)`

**Edge cases**:
- Can only be called once per project. If a token is already set, `JBTokens` reverts.
- `salt` is hashed with `_msgSender()` to prevent front-running deterministic deployments
- The clone's constructor sets invalid name/symbol; real values come from `initialize()`

---

## 13. Claim Credits as ERC-20

**Entry point**: `JBController.claimTokensFor(address holder, uint256 projectId, uint256 tokenCount, address beneficiary)`

**Who can call**: The credit holder or address with `CLAIM_TOKENS` permission.

**Parameters**:
- `holder` -- Address whose credits to convert
- `projectId` -- Target project
- `tokenCount` -- Number of credits to convert to ERC-20
- `beneficiary` -- Address to receive the ERC-20 tokens

**State changes**:
1. `JBTokens.creditBalanceOf[holder][projectId]` decreased by `tokenCount`
2. ERC-20 tokens minted to `beneficiary` for `tokenCount`

**Edge cases**:
- Requires an ERC-20 token to be deployed for the project (reverts otherwise)
- Credits and ERC-20 tokens are fungible -- this is a one-way conversion from internal credits to on-chain ERC-20
- Does not require any ruleset flag (always allowed if ERC-20 exists)

---

## 14. Process Held Fees

**Entry point**: `JBMultiTerminal.processHeldFeesOf(uint256 projectId, address token, uint256 count)`

**Who can call**: Anyone.

**Parameters**:
- `projectId` -- Project whose held fees to process
- `token` -- Token the fees are denominated in
- `count` -- Maximum number of held fees to process

**State changes**:
1. For each processable fee (unlocked, i.e., `unlockTimestamp <= block.timestamp`):
   - Fee entry deleted from `_heldFeesOf` array
   - `_nextHeldFeeIndexOf` incremented
   - Fee amount sent to project #1's terminal via `_processFee` (try-catch)
   - On failure: fee amount returned to project's balance
2. If all fees processed: array and index are reset to 0

**Events**: `ProcessFee(projectId, token, amount, wasHeld, beneficiary, caller)` per fee, or `FeeReverted(...)` on failure

**Edge cases**:
- Fees unlock after 28 days from when they were held
- Processing stops at the first locked fee (fees are sequential)
- Re-reads storage index each iteration (reentrancy-safe)
- If fee terminal for project #1 does not exist for the token, `_processFee` reverts (caught by try-catch, returns to project balance)

---

## 15. Add Price Feeds

**Entry point**: `JBController.addPriceFeed(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed)`

**Who can call**: Project owner or address with `ADD_PRICE_FEED` permission.

**Parameters**:
- `projectId` -- Project the feed applies to (0 for protocol-wide default, owner-only)
- `pricingCurrency` -- Currency the feed's output is in
- `unitCurrency` -- Currency being priced
- `feed` -- The price feed contract address

**State changes**:
1. `JBPrices` stores the feed for the `(projectId, pricingCurrency, unitCurrency)` triple
2. Feed is **immutable** once set -- cannot be replaced or removed

**Events**: Emitted by `JBPrices`

**Edge cases**:
- Requires `allowAddPriceFeed` in current ruleset
- Protocol-wide defaults (`projectId = 0`) can only be set by the `JBPrices` owner
- `JBPrices` auto-calculates inverse: if A->B exists, B->A is derived. If both explicit and inverse exist, explicit takes priority.
- Lookup order: project-specific -> project-specific inverse -> default (projectId=0) -> default inverse

---

## 16. Set Permissions

**Entry point**: `JBPermissions.setPermissionsFor(address account, JBPermissionsData permissionsData)`

**Who can call**: The `account` itself, or a ROOT operator for the project (with restrictions).

**Parameters**:
- `account` -- The account granting permissions
- `permissionsData.operator` -- Address receiving the permissions
- `permissionsData.projectId` -- Project scope (0 = wildcard, all projects)
- `permissionsData.permissionIds` -- Array of `uint8` permission IDs to grant

**State changes**:
1. `permissionsOf[operator][account][projectId]` set to packed `uint256` bitmap

**Events**: `OperatorPermissionsSet(operator, account, projectId, permissionIds, packed, caller)`

**Edge cases**:
- Permission ID 0 cannot be set (reserved, always `NoZeroPermission` revert)
- ROOT (ID 1) cannot be set for wildcard `projectId = 0` (`CantSetRootPermissionForWildcardProject`)
- ROOT operators can set non-ROOT permissions for others on their scoped project
- ROOT operators CANNOT grant ROOT to other addresses
- ROOT operators CANNOT set permissions for wildcard `projectId = 0`
- Setting permissions replaces the entire bitmap (not additive) -- passing an empty array clears all permissions

---

## 17. Transfer Project Ownership

**Entry point**: `JBProjects.transferFrom(address from, address to, uint256 tokenId)` (standard ERC-721)

**Who can call**: The current owner, an approved address, or an operator approved for all.

**Parameters**:
- `from` -- Current owner
- `to` -- New owner
- `tokenId` -- The project ID (same as the ERC-721 token ID)

**State changes**:
1. ERC-721 ownership transferred
2. All `PROJECTS.ownerOf(projectId)` calls now return the new owner
3. All permission checks that reference the owner now apply to the new owner

**Edge cases**:
- This is a standard ERC-721 transfer. All ERC-721 rules apply (approval, operator, etc.)
- **Permissions are NOT transferred**. Existing operators retain their permissions scoped to the account that granted them (the old owner). The new owner must grant their own permissions.
- The new owner immediately gets full control: queue rulesets, set terminals, set splits, etc.
- Transferring to `address(0)` is prevented by OpenZeppelin's ERC-721 implementation

---

## 18. Add to Balance (Without Minting)

**Entry point**: `JBMultiTerminal.addToBalanceOf(uint256 projectId, address token, uint256 amount, bool shouldReturnHeldFees, string memo, bytes metadata)`

**Who can call**: Anyone.

**Parameters**:
- `projectId` -- Project to add funds to
- `token` -- Token to add
- `amount` -- Amount to add (uses `msg.value` for native token)
- `shouldReturnHeldFees` -- If true, uses the added amount to return held fees (reducing the fee burden)
- `memo`, `metadata` -- Arbitrary data

**State changes**:
1. Tokens transferred to terminal
2. If `shouldReturnHeldFees`: iterates held fees, returns fees proportional to amount added
3. `JBTerminalStore.balanceOf[terminal][projectId][token]` incremented by `amount + returnedFees`

**Events**: `AddToBalance(projectId, amount, returnedFees, memo, metadata, caller)`

**Edge cases**:
- Does NOT mint tokens -- purely adds to balance. This increases surplus, which increases cash out value for existing holders.
- `shouldReturnHeldFees = true` partially or fully returns held fees. The returned fee amount is added to the project balance on top of the deposited amount.
- Used by terminal migration (`migrateBalanceOf`) and split payouts (when `preferAddToBalance = true`)

---

## 19. Transfer Credits

**Entry point**: `JBController.transferCreditsFrom(address holder, uint256 projectId, address recipient, uint256 creditCount)`

**Who can call**: The credit holder or address with `TRANSFER_CREDITS` permission.

**Parameters**:
- `holder` -- Address transferring credits
- `projectId` -- Project whose credits are being transferred
- `recipient` -- Address to receive credits
- `creditCount` -- Number of credits to transfer

**State changes**:
1. `JBTokens.creditBalanceOf[holder][projectId]` decreased
2. `JBTokens.creditBalanceOf[recipient][projectId]` increased

**Events**: Emitted by `JBTokens`

**Edge cases**:
- Reverts if `pauseCreditTransfers` is set in current ruleset
- Credits are internal -- they are NOT ERC-20 tokens. Use `claimTokensFor` to convert credits to ERC-20.
- This only transfers credits, not ERC-20 tokens. ERC-20 tokens are transferred via standard ERC-20 `transfer`/`transferFrom`.

---

## 20. Set Project URI

**Entry point**: `JBController.setUriOf(uint256 projectId, string uri)`

**Who can call**: Project owner or address with `SET_PROJECT_URI` permission.

**State changes**: `uriOf[projectId] = uri`

**Events**: `SetUri(projectId, uri, caller)`

---

## 21. Set Custom Token

**Entry point**: `JBController.setTokenFor(uint256 projectId, IJBToken token)`

**Who can call**: Project owner or address with `SET_TOKEN` permission.

**State changes**: `JBTokens.tokenOf[projectId] = token`

**Edge cases**:
- Requires `allowSetCustomToken` in current or upcoming ruleset
- Can only be called if no token is currently set for the project
- The token must conform to `IJBToken` interface (18 decimals required)

---

## 22. Set Token Metadata

**Entry point**: `JBController.setTokenMetadataOf(uint256 projectId, string name, string symbol)`

**Who can call**: Project owner or address with `SET_TOKEN_METADATA` permission.

**State changes**: Updates the ERC-20 token's name and symbol via `JBERC20.setNameAndSymbol()`

---

## 23. Update Ruleset Weight Cache

**Entry point**: `JBRulesets.updateRulesetWeightCache(uint256 projectId, uint256 rulesetId)`

**Who can call**: Anyone.

**Parameters**:
- `projectId` -- Target project
- `rulesetId` -- The specific ruleset to update cache for

**State changes**:
1. `_weightCacheOf[projectId][rulesetId].weight` updated to current decayed weight
2. `_weightCacheOf[projectId][rulesetId].weightCutMultiple` updated

**Events**: `WeightCacheUpdated(projectId, weight, weightCutMultiple, caller)`

**Edge cases**:
- Required for projects with >20,000 cycles (otherwise `currentOf()` reverts with `WeightCacheRequired`)
- Advances the cache by at most `_WEIGHT_CUT_MULTIPLE_CACHE_LOOKUP_THRESHOLD` (20,000) cycles per call
- Multiple calls needed to fully catch up for very large cycle gaps
- No-op if `duration == 0` or `weightCutPercent == 0`

---

## 24. Add Accounting Contexts

**Entry point**: `JBMultiTerminal.addAccountingContextsFor(uint256 projectId, JBAccountingContext[] accountingContexts)`

**Who can call**: Project owner, address with `ADD_ACCOUNTING_CONTEXTS` permission, or the project's controller.

**State changes**:
1. For each context: validates token decimals, stores `_accountingContextForTokenOf[projectId][token]`
2. Appends to `_accountingContextsOf[projectId]` array

**Events**: `SetAccountingContext(projectId, context, caller)` per token

**Edge cases**:
- Requires `allowAddAccountingContext` in current ruleset (if ruleset exists)
- Token cannot be added twice (`AccountingContextAlreadySet`)
- Currency must be non-zero (`ZeroAccountingContextCurrency`)
- For non-native tokens: decimals are validated against the token's `decimals()` function. Tokens that revert on `decimals()` bypass validation (caller responsible).
