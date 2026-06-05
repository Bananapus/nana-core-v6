# Invariants of `@bananapus/core-v6`

Scope: the Juicebox V6 core protocol — `JBController`, `JBMultiTerminal`, `JBTerminalStore`, `JBDirectory`,
`JBRulesets`, `JBSplits`, `JBPermissions`, `JBPrices`, `JBProjects`, `JBTokens`, `JBERC20`,
`JBFundAccessLimits`, `JBFeelessAddresses`, and the Chainlink price-feed adapters. This is the foundational
protocol layer that every other V6 contract integrates with. For ecosystem-wide invariants spanning
revnets, suckers, hooks, distributors, etc., see the canonical
[`../INVARIANTS.md`](../INVARIANTS.md).

Audience: integrators (project owners, operators, third-party contracts) reasoning about what core
guarantees independent of the application layer above it. This doc is descriptive of the *as-deployed*
contracts; ruleset-controlled behaviors (mint allowed, controller migration allowed, etc.) are noted
inline because operators may toggle them.

---

## Section A — Guarantees to paying users

### A.1 Token issuance correctness

- A payment of `amount` of an accepted terminal token mints exactly `weight × amount` project tokens
  (modulo data-hook substitution, fee-on-transfer balance deltas, and currency conversion via
  `JBPrices`) — there is no path where the controller mints fewer tokens than the active ruleset's
  weight implies without a data-hook override (`JBMultiTerminal.pay` →
  `JBTerminalStore.recordPaymentFrom` → `JBController.mintTokensOf`). The user-supplied
  `minReturnedTokens` is enforced via balance-delta on the beneficiary (`pay` at
  `JBMultiTerminal.sol:681-711`).
- Reserved tokens are tracked as an IOU in `pendingReservedTokenBalanceOf[projectId]`; they dilute
  `totalTokenSupplyWithReservedTokensOf` until distributed by the permissionless
  `sendReservedTokensToSplitsOf`. Reserved share of a mint never accrues to the beneficiary
  (`JBController.sol:596-621`).
- Payment data hooks can override the issuance weight and add pay-hook side effects, but the
  beneficiary mint count returned to the user is what is checked against `minReturnedTokens` — a
  failing pay hook cannot retroactively reduce issuance.
- Native-token payments must arrive as `msg.value` matching the accounting context (18 decimals
  enforced for `NATIVE_TOKEN` in `JBTerminalStore.recordAccountingContextOf`).

### A.2 Cash-out availability and floor

- `cashOutTokensOf` is always available on a holder's terminal of choice, modulo:
  - the project having a configured accounting context for the requested `tokenToReclaim`,
  - the holder holding at least `cashOutCount` tokens (credits + ERC-20),
  - the data hook (if any) not reverting,
  - sufficient local-terminal surplus to fund the reclaim.
- Reclaim is computed by `JBTerminalStore.recordCashOutFor` using the bonding curve in
  `JBCashOuts`: `base × [(MAX − tax) + tax × (count / supply)] / MAX`, where `base` is the holder's
  pro-rata share of aggregated cross-terminal surplus, `tax = ruleset.cashOutTaxRate`, and
  `MAX = JBConstants.MAX_CASH_OUT_TAX_RATE = 10_000`.
- The hard floor is the local-terminal-token surplus: reclaim is capped by what the cashing terminal
  actually holds for that project/token (`JBTerminalStore.sol:501`, `JBTerminalStore_InadequateTerminalStoreBalance`).
- Tokens are **burned before** reclaim is transferred to the beneficiary
  (`JBMultiTerminal._cashOutTokensOf` calls `controller.burnTokensOf` before `_transferFrom` to the
  beneficiary), preventing reentrant double-cashout against the same supply.
- Failed cashout hooks do not strand funds — hooks fire under try/catch after the beneficiary has
  already received reclaim.
- A failed protocol-fee payment on cashout does not revert the cashout; the fee amount is credited
  back to the originating project as a held-fee refund and `FeeReverted` is emitted
  (`JBMultiTerminal._processFee`).
- The user-supplied `minTokensReclaimed` is enforced via `_checkMin` (`JBMultiTerminal.sol:342`).

### A.3 Bonding-curve floor formula

- `JBCashOuts.cashOutFrom` returns `0` when `cashOutCount == 0`.
- When `tax == MAX_CASH_OUT_TAX_RATE` (10_000), every holder reclaims their full pro-rata share
  regardless of cashout count.
- When `tax == 0`, the formula degenerates to `base = surplus × cashOutCount / totalSupply` (no
  curve premium for early/late cashouts).
- Pending reserved tokens are included in the denominator
  (`totalTokenSupplyWithReservedTokensOf`) — a holder cashing out before reserve distribution
  receives a smaller pro-rata share. Calling the permissionless
  `sendReservedTokensToSplitsOf` first reflects the dilution they already implicitly bear.

### A.4 Protocol fee (2.5%) + 28-day held-fee window

- Fee constants: `FEE = 25`, `MAX_FEE = 1000` (`JBMultiTerminal` — JBFees library), giving a 2.5%
  fee on outflows.
- Outflows that incur the fee: `cashOutTokensOf` (on the cashed amount net of any data-hook hook
  amounts), `sendPayoutsOf` (per fee-eligible split), `useAllowanceOf` (on the full withdrawn
  amount), and `migrateBalanceOf` (on the migrated balance, not held).
- Held fees: cashouts and payouts hold the fee in `_heldFeesOf[projectId][token]` with
  `unlockTimestamp = block.timestamp + 2_419_200` (28 days, `_FEE_HOLDING_SECONDS`).
  Held fees can be:
  - returned to the originating project via `addToBalanceOf(..., shouldReturnHeldFees: true)` —
    the project effectively repays the gross outflow and rescinds the held fee. This does not
    enforce the 28-day timestamp (see RISKS.md §8.5),
  - processed permissionlessly by anyone after the 28-day window via `processHeldFeesOf` — funds
    forwarded to project 1 (the fee beneficiary, `FEE_BENEFICIARY_PROJECT_ID` in `JBConstants`).
- `useAllowanceOf` and migration fees are NOT held; they are taken immediately.
- A `cashOutTaxRate == 0` ruleset still charges fees up to `feeFreeSurplusOf[projectId][token]` to
  defeat the round-trip bypass (intra-terminal payout → zero-tax cash out)
  (`JBMultiTerminal.sol:117-130`).
- `processHeldFeesOf` is reentrancy-safe: it deletes the entry and advances
  `_nextHeldFeeIndexOf[projectId][token]` BEFORE the external fee-terminal call
  (`JBMultiTerminal.sol:744-770`).
- Fee processing is fail-open: if the fee terminal reverts, the fee is forgiven and the amount is
  credited back to the originating project. This is RISKS.md §8.2 — accepted as the cost of
  liveness.

### A.5 Permit2 + ERC-20 deposit accounting (balance-delta safe)

- `_acceptFundsFor` measures the actual balance delta against the terminal's pre-call ERC-20
  balance and uses that as the accepted amount. Fee-on-transfer tokens are charged inbound at the
  net received amount, not the requested `amount` (`JBMultiTerminal._acceptFundsFor`).
- Permit2 use is inbound-only; outbound transfers use `SafeERC20.safeTransfer`. The Permit2 path
  caps transfer size to `uint160.max` (`_acceptFundsFor`'s cast).
- The `_acceptingToken` transient guard reverts on reentrant deposit attempts during balance-delta
  measurement (`JBMultiTerminal_ReentrantTokenTransfer`). This blocks ERC-777-style callbacks from
  double-counting an inbound transfer.
- Native-token payments require `msg.value == amount`; ERC-20 paths reject non-zero `msg.value`
  (`JBMultiTerminal_NoMsgValueAllowed`).

### A.6 Cashout reclaim ≤ local-token surplus

- `JBTerminalStore.recordCashOutFor` computes `balanceDiff` as the funds leaving the cashing
  terminal in `tokenToReclaim`. It enforces `balanceDiff ≤ balanceOf[terminal][projectId][token]`
  via `JBTerminalStore_InadequateTerminalStoreBalance`.
- Cross-terminal surplus aggregation only affects the *price* of the reclaim (how much is
  reclaimable per project token), not the *source* of payment. A holder cashing out on terminal X
  for token T receives funds from X's recorded balance of T — never from a different terminal.

### A.7 `_acceptingToken` transient reentrancy guard

- `JBMultiTerminal._acceptFundsFor` sets `_acceptingToken = true` before measuring the inbound
  ERC-20 balance delta and `false` after. A reentrant call landing back inside `_acceptFundsFor`
  reverts with `JBMultiTerminal_ReentrantTokenTransfer`. This is the primary guard against
  ERC-777-style inbound reentrancy during deposit accounting.
- The guard is per-call; it does not block reentrancy *after* the deposit completes (that surface
  is documented in RISKS.md §3).

---

## Section B — Guarantees to project owners and operators

### B.1 Permission system

- `JBPermissions.setPermissionsFor(account, data)` is callable in only two cases
  (`JBPermissions.sol:66-101`):
  1. `_msgSender() == account` — an account can set its own operator permissions.
  2. `_msgSender()` holds the ROOT permission (ID 1) on `(account, projectId, includeRoot=true,
     includeWildcardProjectId=true)` AND the packed permissions being granted do not include ROOT
     AND `data.projectId != WILDCARD_PROJECT_ID (0)`. This anti-escalation clause prevents a ROOT
     operator from minting new ROOTs or expanding into wildcard project-0 scope.
- Permission ID 0 is reserved as a sentinel — `setPermissionsFor` reverts
  `JBPermissions_NoZeroPermission` if the packed set includes bit 0.
- `hasPermission` and `hasPermissions` revert `JBPermissions_PermissionIdOutOfBounds` for IDs > 255.
- Empty `permissionIds` arrays satisfy `hasPermissions` vacuously (documented in RISKS.md §4).
  Callers must validate non-empty arrays if non-vacuous truth matters.

### B.2 Ruleset queue authority

- `JBController.launchRulesetsFor` is gated to:
  - `LAUNCH_RULESETS` on the project owner,
  - `SET_TERMINALS` on the project owner,
  - `SET_PROJECT_URI` on the project owner if a non-empty `projectUri` is passed,
  - OR the call is from `OMNICHAIN_RULESET_OPERATOR` (immutable on the controller), which bypasses
    all three.
  - Reverts `JBController_RulesetsAlreadyLaunched` if `latestRulesetIdOf(projectId) > 0`. First
    launch only.
- `JBController.queueRulesetsOf` is gated to `QUEUE_RULESETS` on the project owner OR
  `OMNICHAIN_RULESET_OPERATOR`. Each queued ruleset must pass the prior ruleset's approval hook to
  become active (`JBRulesets._currentlyApprovableRulesetIdOf`, falling back to the
  basedOnId chain on rejection).
- Queueing validates `reservedPercent ≤ MAX_RESERVED_PERCENT`,
  `cashOutTaxRate ≤ MAX_CASH_OUT_TAX_RATE`, `weight ≤ uint112.max`, `duration ≤ uint32.max`,
  `mustStartAtOrAfter + duration ≤ uint48.max`, and that the approval hook (if any) supports
  `IJBRulesetApprovalHook` via ERC-165 (`JBRulesets.queueFor`).
- Ruleset IDs are strictly increasing: `rulesetId = latestRulesetIdOf > block.timestamp ?
  latestRulesetIdOf + 1 : block.timestamp` (`JBRulesets.sol:160-164`).

### B.3 `mintTokensOf` auth matrix

`JBController.mintTokensOf(projectId, tokenCount, beneficiary, memo, useReservedPercent)` is
gated as follows (`JBController.sol:550-621`):

| Caller class | Mint allowed? | `useReservedPercent` honored? |
|---|---|---|
| Project's terminal (from `_pay`) | Always | Yes |
| Project's data hook (active ruleset's `dataHook`) | Always | Yes |
| Address granted mint by data hook (`hasMintPermissionFor`) | Always | Yes |
| Project owner | Only if `ruleset.allowOwnerMinting()` | Yes |
| `MINT_TOKENS` operator on owner | Only if `ruleset.allowOwnerMinting()` | Yes |

`allowOwnerMinting=false` blocks *only* the owner / `MINT_TOKENS` path — terminals and data hooks
remain authoritative. There is no path to mint without `tokenCount > 0`
(`JBController_ZeroTokensToMint`).

### B.4 `burnTokensOf` auth

- `JBController.burnTokensOf(holder, projectId, tokenCount, memo)` allows:
  - the holder directly,
  - an operator with `BURN_TOKENS` from the holder,
  - any of the project's current terminals (via `_isTerminalOf`) — this is the cashout path.
- Reverts `JBController_ZeroTokensToBurn` if `tokenCount == 0`. Credits are burned first, then
  ERC-20 tokens if needed (`JBTokens.burnFrom`).

### B.5 `sendReservedTokensToSplitsOf` is permissionless

- `JBController.sendReservedTokensToSplitsOf(projectId)` mints exactly the prior
  `pendingReservedTokenBalanceOf[projectId]` and distributes it per the project's current ruleset's
  RESERVED_TOKENS split group. Leftover goes to the project owner.
  (`JBController.sol:665-667` → `_sendReservedTokensToSplitsOf` at 1222-1271).
- Permissionless caller cannot mint *more* than the pending amount — the storage slot is zeroed
  before the mint loop.
- Reserved-token split where `split.projectId == ownerProjectId` reverts (prevents recycling the
  project's own reserves back into payment-style minting).
- Controller migration requires `pendingReservedTokenBalanceOf[projectId] == 0`
  (`JBController.migrate`).

### B.6 `claimTokensFor` — credits → ERC-20 1:1

- `JBController.claimTokensFor(holder, projectId, tokenCount, beneficiary)` requires the holder OR
  a `CLAIM_TOKENS` operator on the holder.
- Internally calls `JBTokens.claimTokensFor` which burns credits 1:1 and mints the same count of
  ERC-20 to `beneficiary`. The project must have a token deployed/attached
  (`JBTokens_TokenNotFound`).

### B.7 Directory routing — `setControllerOf`, `setTerminalsOf`, `setPrimaryTerminalOf`

- `JBDirectory.setControllerOf` allows:
  - owner / `SET_CONTROLLER` operator if the current controller permits the change (the controller's
    `setControllerAllowed(projectId)` is consulted, which checks the current ruleset's
    `allowSetController` flag),
  - any address in `isAllowedToSetFirstController` if the project has no controller yet
    (`controllerOf[projectId] == address(0)`).
  Migration ordering: `beforeReceiveMigrationFrom` → old `migrate` (called while directory still
  points to old controller, which closes a reentrancy window) → directory update →
  `afterReceiveMigrationFrom` (`JBDirectory.sol:98-152`).
- `JBDirectory.setTerminalsOf` requires owner / `SET_TERMINALS` operator OR the project's
  controller. Owner/operator paths additionally require the controller's
  `setTerminalsAllowed(projectId)` (which checks the current ruleset's `allowSetTerminals` flag).
  The controller path bypasses the ruleset gate. Duplicate terminals revert
  (`JBDirectory_DuplicateTerminals`).
- `JBDirectory.setPrimaryTerminalOf` requires `SET_PRIMARY_TERMINAL` AND, if the new terminal is
  not already in the project's terminal list, `ADD_TERMINALS`. Terminal must accept the requested
  token (`JBDirectory_TokenNotAccepted`).

### B.8 Operator powers and limits

Powers the owner can delegate via `JBPermissions`:

- `LAUNCH_RULESETS`, `QUEUE_RULESETS`, `SET_TERMINALS`, `SET_CONTROLLER`, `SET_PROJECT_URI`,
  `SET_TOKEN`, `SET_TOKEN_METADATA`, `DEPLOY_ERC20`, `SET_SPLIT_GROUPS`, `ADD_PRICE_FEED`,
  `ADD_ACCOUNTING_CONTEXTS`, `SET_PRIMARY_TERMINAL`, `ADD_TERMINALS`, `MIGRATE_TERMINAL`,
  `MINT_TOKENS` (only useful if ruleset allows owner minting), `BURN_TOKENS`, `CLAIM_TOKENS`,
  `TRANSFER_CREDITS` (pauseable per ruleset), `USE_ALLOWANCE`, `CASH_OUT_TOKENS` (per-holder),
  `ROOT` (wildcard project, self-grant only).

Powers no one holds on a properly-configured project:

- Editing existing price feeds (append-only via `JBPrices`).
- Changing the fee beneficiary project ID (hardcoded to `FEE_BENEFICIARY_PROJECT_ID = 1`).
- Lifting `MAX_CREATION_FEE = 0.001 ether` on `JBProjects`.

---

## Section C — Per-contract operation inventory

For each contract: external/public functions, caller, effect, invariant preserved, and what the
caller cannot achieve via that path.

### C.1 `JBMultiTerminal` — `src/JBMultiTerminal.sol`

Payment / cashout / payout / fee terminal. Holds funds. All external hook calls wrapped in
try/catch. Fee = 2.5% on outflows, held 28 days.

**Paying users (permissionless):**

- **`pay(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata) payable →
  beneficiaryTokenCount`** (`L667-712`)
  - Accepts `token` (native via `msg.value` or ERC-20 via `transferFrom`/Permit2),
    `_acceptFundsFor` measures balance delta. Calls `STORE.recordPaymentFrom` (data hook resolves
    weight + pay-hook specs), `controller.mintTokensOf` (reserved share accrues to pending
    balance), fulfills pay-hook specifications via try/catch.
  - **Invariant:** `beneficiaryTokenCount >= minReturnedTokens` enforced by balance-delta on
    beneficiary. Pay-hook revert does not roll back beneficiary mint. `_acceptingToken` transient
    guard blocks reentrant deposits. Accounting context must be set
    (`JBMultiTerminal_TokenNotAccepted`).
  - **Cannot:** mint without controller authorization; bypass `pauseCreditTransfers`/data-hook
    gating; route to a project without an accounting context for `token`.

- **`addToBalanceOf(projectId, token, amount, shouldReturnHeldFees, memo, metadata) payable`**
  (`L264-285`)
  - Credits terminal-store balance without minting; optionally rolls back held fees proportional to
    the added amount.
  - **Invariant:** `balance += accepted_delta`; returned held fees ≤ amount added and ≤ what was
    actually charged.
  - **Cannot:** mint project tokens; alter `feeFreeSurplusOf`; force processing of held fees.

**Token holders / `CASH_OUT_TOKENS` operators:**

- **`cashOutTokensOf(holder, projectId, cashOutCount, tokenToReclaim, minTokensReclaimed,
  beneficiary, metadata) → reclaimAmount`** (`L310-343`)
  - Caller must be `holder` or an operator with `CASH_OUT_TOKENS` on `holder`. Runs data hook
    (override option) or bonding-curve baseline; `STORE.recordCashOutFor` decrements local-token
    surplus; `controller.burnTokensOf`; transfers net reclaim to beneficiary; fulfills cashout
    hooks (try/catch); takes 2.5% fee on fee-eligible portion (held 28 days unless terminal is
    feeless).
  - **Invariant:** project tokens burned BEFORE fees taken (no double cashout via reentrancy);
    reclaim ≤ local-token surplus; `reclaimAmount >= minTokensReclaimed`; with
    `cashOutTaxRate=0`, fees still charged up to `feeFreeSurplusOf` to prevent round-trip
    bypass.
  - **Cannot:** reclaim beyond local-token surplus; skip the burn; cash out a token without an
    accounting context.

**Operators / owner / permissionless:**

- **`sendPayoutsOf(projectId, token, amount, currency, minTokensPaidOut) →
  amountPaidOut`** (`L816-836`) — permissionless.
  - `STORE.recordPayoutFor` caps `amount` at remaining payout limit (no revert if smaller),
    converts via `JBPrices`, decrements `balanceOf`. Splits iterated via `JBPayoutSplitGroupLib`
    → split hook (partial-pull aware), recipient project's primary terminal, or beneficiary
    fallback (wildcard splits route to `msg.sender`). Leftover after splits → project owner.
    2.5% fee taken on non-feeless egress, held.
  - **Invariant:** payouts ≤ remaining cycle payout limit; locked splits enforced
    (replacement table must preserve every locked entry with same multiplicity); same-project
    self-payout reverts (`JBMultiTerminal_MintNotAllowed`); held fees accumulate per outflow.
  - **Cannot:** exceed cycle payout limit; bypass locked-split enforcement; force a same-project
    payout to mint new tokens.

- **`useAllowanceOf(projectId, token, amount, currency, minTokensPaidOut, beneficiary,
  feeBeneficiary, memo) → netAmountPaidOut`** (`L862-900`) — owner /
  `USE_ALLOWANCE` operator.
  - Enforces cumulative used ≤ ruleset surplus allowance via
    `STORE.recordUsedAllowanceOf`; 2.5% fee taken immediately (NOT held). Net amount delivered to
    `beneficiary`; fee project mints project tokens for `feeBeneficiary` in exchange for the
    fee-token payment.
  - **Invariant:** cumulative withdrawals per `ruleset.id` ≤ configured surplus allowance;
    surplus allowance does not reset on duration-based ruleset auto-cycle (only on new ruleset
    ID).

- **`processHeldFeesOf(projectId, token, count)`** (`L724-790`) — permissionless after 28-day
  unlock.
  - Iterates `_heldFeesOf` from `_nextHeldFeeIndexOf` for up to `count` entries; for each whose
    `unlockTimestamp <= block.timestamp`, deletes entry + advances index BEFORE the external
    `_processFee` call (reentrancy-safe). On failure forgives the fee back to the project balance,
    emits `FeeReverted`.
  - **Invariant:** fees only processed after 28-day lock; never double-processed across
    reentrancy; broken fee route never traps project funds.

- **`migrateBalanceOf(projectId, token, to) → balance`** (`L576-646`) — owner /
  `MIGRATE_TERMINAL` operator.
  - Requires current ruleset's `allowTerminalMigration`. Reverts on self-migration. Zeros recorded
    balance, clears `feeFreeSurplusOf[projectId][token]`, takes 2.5% migration fee (NOT held)
    unless destination is feeless or `projectId == FEE_BENEFICIARY_PROJECT_ID`, then
    `_externalAddToBalance` on destination terminal.
  - **Invariant:** held fees stay attached to this terminal; cannot migrate to self
    (`JBMultiTerminal_TerminalMigrationToSelf`); destination terminal must accept the same
    token.

- **`addAccountingContextsFor(projectId, accountingContexts)`** (`L225-...`) — owner /
  `ADD_ACCOUNTING_CONTEXTS` operator / project's controller.
  - Forwards to `STORE.recordAccountingContextOf`. Validates decimals (≤ 36, ERC-20 match where
    available); native token must declare 18 decimals; currency must be non-zero; duplicate
    rejection per `(terminal, projectId, token)`.
  - **Invariant:** accounting context is set once and never overwritten.

- **`executePayout(split, projectId, token, amount, originalMessageSender)`** (`L353-...`) — only
  callable by `address(this)` (`require(msg.sender == address(this))`).
- **`executeProcessFee(...)`** (`L517-...`) — same.
- **`executeTransferTo(addr, token, amount)`** (`L561-566`) — same.

**Views:** `accountingContextForTokenOf`, `accountingContextsOf`, `currentSurplusOf`,
`heldFeesOf`, `previewCashOutFrom`, `previewPayFor`, `supportsInterface`.

### C.2 `JBController` — `src/JBController.sol`

Orchestrator: project lifecycle, ruleset queueing, token mint/burn, reserved-token distribution.

**Project launch and lifecycle:**

- **`launchProjectFor(owner, projectUri, rulesetConfigurations, terminalConfigurations, memo)
  payable → projectId`** (`L403-441`) — permissionless on behalf of `owner`.
  - Forwards exactly `JBProjects.creationFee` (`JBController_InvalidCreationFee`). Mints project
    NFT to `owner`, registers this controller in `JBDirectory`, configures terminals + accounting
    contexts, queues initial rulesets.
  - **Invariant:** launch alone does not prove the resulting NFT owner intended that
    configuration — anyone can call this on behalf of any `owner` (RISKS.md §4).

- **`launchRulesetsFor(projectId, projectUri, rulesetConfigurations, terminalConfigurations,
  memo) → rulesetId`** (`L453-519`) — owner / (`LAUNCH_RULESETS` + `SET_TERMINALS` (+
  `SET_PROJECT_URI` if URI passed)) operator / `OMNICHAIN_RULESET_OPERATOR`.
  - **Invariant:** reverts `JBController_RulesetsAlreadyLaunched` if `latestRulesetIdOf != 0`
    (first launch only). Queues initial rulesets and configures terminals atomically.

- **`queueRulesetsOf(projectId, rulesetConfigurations, memo) → rulesetId`** (`L630-658`) — owner
  / `QUEUE_RULESETS` operator / `OMNICHAIN_RULESET_OPERATOR`.
  - **Invariant:** each queued ruleset must pass the prior ruleset's approval hook to take effect;
    `reservedPercent ≤ 10_000`, `cashOutTaxRate ≤ 10_000` validated on queue.

- **`migrate(projectId, to)`** (`L525-...`) — directory-only (during `setControllerOf`). Reverts
  if `pendingReservedTokenBalanceOf[projectId] != 0`.

- **`beforeReceiveMigrationFrom`** / **`afterReceiveMigrationFrom`** (`L215-246`) — directory-only.

**Token issuance / burn:**

- **`mintTokensOf(projectId, tokenCount, beneficiary, memo, useReservedPercent) →
  beneficiaryTokenCount`** (`L550-621`) — see auth matrix in B.3.
  - **Invariant:** out-of-cycle dilution requires `allowOwnerMinting`; reserved-token IOU tracked
    in `pendingReservedTokenBalanceOf`, never lost.

- **`burnTokensOf(holder, projectId, tokenCount, memo)`** (`L255-281`) — holder /
  `BURN_TOKENS` operator / any project terminal.

- **`sendReservedTokensToSplitsOf(projectId) → tokenCount`** (`L665-667`) — permissionless.
  - **Invariant:** mints exactly the pending balance, distributes per RESERVED_TOKENS split group;
    leftover → owner; same-project reserve split reverts.

- **`claimTokensFor(holder, projectId, tokenCount, beneficiary)`** (`L293-306`) — holder /
  `CLAIM_TOKENS` operator. Burns credits 1:1, mints ERC-20.

- **`transferCreditsFrom(holder, projectId, recipient, creditCount)`** (`L757-778`) — holder /
  `TRANSFER_CREDITS` operator. Reverts if `pauseCreditTransfers()`.

- **`deployERC20For(projectId, name, symbol, salt) → token`** (`L318-343`) — owner /
  `DEPLOY_ERC20` operator. One-shot per project (`JBTokens_ProjectAlreadyHasToken`).

**Project configuration:**

- **`setTokenFor(projectId, token)`** (`L698-714`) — owner / `SET_TOKEN` operator. Requires
  current/upcoming ruleset's `allowSetCustomToken`. Reverts if a token is already set; token must
  use 18 decimals.
- **`setTokenMetadataOf(projectId, name, symbol)`** (`L722-729`) — owner /
  `SET_TOKEN_METADATA` operator.
- **`setSplitGroupsOf(projectId, rulesetId, splitGroups)`** (`L677-692`) — owner /
  `SET_SPLIT_GROUPS` operator. Locked splits enforced in `JBSplits`.
- **`setUriOf(projectId, uri)`** (`L737-...`) — owner / `SET_PROJECT_URI` operator.
- **`addPriceFeedFor(projectId, pricingCurrency, unitCurrency, feed)`** (`L183-209`) — owner /
  `ADD_PRICE_FEED` operator. Requires `ruleset.allowAddPriceFeed()` when a ruleset exists.
  Forwards to `JBPrices.addPriceFeedFor`; feeds are append-only and never overwritten.

**Internal/self:**

- **`executePayReservedTokenToTerminal(...)`** (`L354-...`) — restricted to `address(this)`.

**Views:** `allRulesetsOf`, `currentRulesetOf`, `getRulesetOf`, `latestQueuedRulesetOf`,
`previewMintOf`, `setControllerAllowed`, `setTerminalsAllowed`,
`totalTokenSupplyWithReservedTokensOf`, `upcomingRulesetOf`, `supportsInterface`.

### C.3 `JBTerminalStore` — `src/JBTerminalStore.sol`

Shared accounting. All mutating functions scope by `msg.sender` (the calling terminal). External
callers can only corrupt their own scoped storage; the directory routing controls who counts as a
real terminal.

- **`recordAccountingContextOf(projectId, contexts[])`** (`L196-269`) — caller-terminal. Enforces
  `allowAddAccountingContext` flag; decimals ≤ 36, native = 18; currency non-zero; one-shot per
  `(terminal, projectId, token)`.
- **`recordAddedBalanceFor(projectId, token, amount)`** (`L276-279`) — caller-terminal,
  monotonic-up. RISKS.md §7.5: balance key includes `msg.sender`, so only the calling terminal can
  inflate its own recorded balance. A buggy/malicious *registered* terminal can still misreport
  funds it received.
- **`recordCashOutFor(holder, projectId, cashOutCount, tokenToReclaim, beneficiaryIsFeeless,
  metadata)`** (`L299-...`) — caller-terminal. Runs data hook or bonding curve; enforces
  `balanceDiff ≤ local-token surplus`.
- **`recordPaymentFrom(payer, amount, projectId, beneficiary, metadata)`** (`L398-425`) —
  caller-terminal. Runs data hook for token count + pay-hook specs; `balance += diff`.
- **`recordPayoutFor(projectId, token, amount, currency)`** (`L438-511`) — caller-terminal.
  Caps `amount` at remaining cycle payout limit (no revert); cross-currency rounding to zero
  consumes nothing.
- **`recordTerminalMigration(projectId, token)`** (`L519-533`) — caller-terminal. Enforces
  `allowTerminalMigration`; zeros recorded balance; returns the migrated amount.
- **`recordUsedAllowanceOf(projectId, token, amount, currency)`** (`L546-...`) —
  caller-terminal. Enforces `(usedSurplus + amount) ≤ surplusAllowance ≤ live surplus`. Keyed by
  `ruleset.id` (does not auto-reset on duration cycling).

The store cannot mint or burn project tokens, modify rulesets, or directly transfer terminal
funds. Conservation guards: `JBTerminalStore_InadequateTerminalStoreBalance` everywhere balance
debits occur.

### C.4 `JBDirectory` — `src/JBDirectory.sol`

- **`setControllerOf(projectId, controller)`** (`L98-152`) — see B.7.
  - **Invariant:** ruleset gating cannot be bypassed for non-first changes (controller's
    `setControllerAllowed(projectId)` is consulted); migration runs while directory still points
    to old controller, closing the reentrancy window where the new controller would have already
    been authoritative.
- **`setTerminalsOf(projectId, terminals[])`** (`L212-251`) — see B.7. Duplicate terminals
  revert (`JBDirectory_DuplicateTerminals`).
- **`setPrimaryTerminalOf(projectId, token, terminal)`** (`L176-204`) — see B.7. Implicit
  terminal addition when the target is not already in the list (requires `ADD_TERMINALS`).
- **`setIsAllowedToSetFirstController(addr, flag)`** (`L161-166`) — `onlyOwner` on the directory.

**Views:** `primaryTerminalOf`, `terminalsOf`, `isTerminalOf`, `controllerOf`.

### C.5 `JBTokens` — `src/JBTokens.sol`

All mutating functions gated by `onlyControllerOf(projectId)` — project owners cannot call
directly.

- **`mintFor(holder, projectId, count) → token`** (`L244-...`) — credits or ERC-20 (whichever the
  project has), uint208 supply cap.
- **`burnFrom(holder, projectId, count)`** (`L82-131`) — burns credits first, then ERC-20.
- **`claimTokensFor(holder, projectId, count, beneficiary)`** (`L141-182`) — burns credits, mints
  equal ERC-20.
- **`deployERC20For(projectId, name, symbol, salt) → token`** (`L194-234`) — one-shot per project;
  salt mixed with `msg.sender` for deterministic deploys.
- **`setTokenFor(projectId, token)`** (`L290-313`) — externally-deployed token attach, one-shot.
  Token must use 18 decimals and pass `canBeAddedTo(projectId)`. WARNING: external supply manipulation
  surface (RISKS.md §2 Bonding Curve).
- **`setTokenMetadataFor(projectId, name, symbol)`** (`L321-346`) — name/symbol update on the
  project's `JBERC20`.
- **`transferCreditsFrom(holder, projectId, recipient, count)`** (`L355-382`) — credit-balance
  accounting only.

**Invariant:** `totalSupplyOf(projectId) = totalCreditSupplyOf[projectId] + token.totalSupply()`
(`L418-429`); credits always burned first; ERC-20 deploy/attach is one-shot.

**Views:** `totalBalanceOf`, `totalSupplyOf`.

### C.6 `JBSplits` — `src/JBSplits.sol`

- **`setSplitGroupsOf(projectId, rulesetId, splitGroups)`** (`L92-127`) — either:
  - the project's controller (default path used by `JBController.setSplitGroupsOf`), OR
  - a self-managed group: `splitGroups[i].groupId >> 160 != 0` AND
    `address(uint160(groupId)) == msg.sender` (lets hooks manage their own groups
    cooperatively without controller calls).
  - **Invariant:** locked splits enforced — the new table must preserve every currently-locked
    split with at least its multiplicity; `percent` sum ≤ `SPLITS_TOTAL_PERCENT (1e9)`; per-split
    `percent > 0`. `groupId` upper 96 bits zero are reserved for protocol use (terminal payout
    groups), always require controller authorization.
- **`splitsOf(projectId, rulesetId, groupId)`** falls back to ruleset 0 default group when the
  requested ruleset has none set.

### C.7 `JBRulesets` — `src/JBRulesets.sol`

- **`queueFor(projectId, duration, weight, weightCutPercent, approvalHook, metadata,
  mustStartAtOrAfter) → ruleset`** (`L107-205`) — project's controller only.
  - **Invariant:** ruleset IDs strictly increase (`latestId + 1` or `block.timestamp`, whichever
    is larger); a rejected approval falls back to the `basedOnId` chain; approval hook must support
    `IJBRulesetApprovalHook` (ERC-165). Weight overflow checked at queue (uint112).
- **`updateRulesetWeightCache(projectId, rulesetId)`** (`L214-264`) — permissionless. Advances
  weight-decay cache up to `_WEIGHT_CUT_MULTIPLE_CACHE_LOOKUP_THRESHOLD` (20_000) iterations per
  call. Required after 20_000 elapsed cycles to keep `deriveWeightFrom` cheap (RISKS.md §2).

**Views (effectively immutable storage for queued/active rulesets):** `allOf`,
`currentApprovalStatusForLatestRulesetOf`, `currentOf`, `getRulesetOf`, `latestQueuedOf`,
`upcomingOf`, `deriveCycleNumberFrom`, `deriveStartFrom`, `deriveWeightFrom`.

### C.8 `JBPermissions` — `src/JBPermissions.sol`

- **`setPermissionsFor(account, permissionsData)`** (`L66-114`) — `account` itself
  (unrestricted), OR a non-self caller holding ROOT on `(account, projectId)` AND not granting
  ROOT AND `data.projectId != WILDCARD_PROJECT_ID`.
  - **Invariant:** ROOT operators can scope-grant non-ROOT, non-wildcard permissions but cannot
    mint new ROOTs or wildcard scopes; permission ID 0 reserved
    (`JBPermissions_NoZeroPermission`); IDs > 255 rejected on reads
    (`JBPermissions_PermissionIdOutOfBounds`); empty permission arrays satisfy
    `hasPermissions` vacuously.

**Views:** `hasPermission`, `hasPermissions`, `permissionsOf`, `WILDCARD_PROJECT_ID` (= 0).

### C.9 `JBPrices` — `src/JBPrices.sol`

- **`addPriceFeedFor(projectId, pricingCurrency, unitCurrency, feed)`** (`L98-135`) —
  `projectId == 0` → contract owner only; any other project → only that project's controller
  (routed through `JBController.addPriceFeedFor`, which adds ruleset / permission gates).
  - **Invariant:** feeds are append-only — existing entries never overwritten; exact-direction
    duplicate `feed` address rejected; inverse direction derived on lookup via `pricePerUnitOf`
    fallback path. Backups serve when the primary feed reverts or returns 0.

**Views:** `priceFeedAt`, `priceFeedCountFor`, `priceFeedFor`, `pricePerUnitOf`.

### C.10 `JBProjects` — `src/JBProjects.sol`

ERC-721 of project ownership. Project owner = `ownerOf(projectId)`.

- **`createFor(owner) payable → projectId`** (`L117-136`) — anyone. Mints the next project
  ERC-721 to `owner` and forwards `msg.value == creationFee` to `creationFeeReceiver`.
- **`setCreationFee(fee, receiver)`** (`L83-95`) — `onlyOwner`. Bounded by `MAX_CREATION_FEE =
  0.001 ether` (hardcoded immutable).
- **`setTokenUriResolver(resolver)`** (`L101-106`) — `onlyOwner`.
- **`transferFrom` / `safeTransferFrom`** (ERC-721 inherited) — owner or approved operator. The
  ONLY path for transferring project ownership; cascades immediately into every other contract's
  permission resolution.
- **`tokenURI(projectId)`** (`L153-162`) — view, delegates to `tokenUriResolver` (returns empty
  string if unset).

**Views:** `count`, `creationFee`, `creationFeeReceiver`, `tokenUriResolver`,
`MAX_CREATION_FEE`, ERC-721 surface (`ownerOf`, `balanceOf`, `getApproved`, etc.).

### C.11 `JBFundAccessLimits` — `src/JBFundAccessLimits.sol`

- **`setFundAccessLimitsFor(projectId, rulesetId, fundAccessLimitGroups)`** (`L84-187`) — project's
  controller only.
  - **Invariant:** at most one group per `(terminal, token)` pair; payout-limit currencies
    strictly increasing within a group; surplus-allowance currencies strictly increasing within a
    group. These ordering constraints prevent duplicate currencies from being split across groups
    and making surplus views depend on malformed config.

**Views:** `payoutLimitOf`, `payoutLimitsOf`, `surplusAllowanceOf`, `surplusAllowancesOf`.

### C.12 `JBFeelessAddresses` — `src/JBFeelessAddresses.sol`

- **`setFeelessAddress(addr, flag)`** (`L54-58`) — `onlyOwner`. Equivalent to
  `setFeelessAddressFor(0, addr, flag)` (project-0 wildcard = feeless for ALL projects).
- **`setFeelessAddressFor(projectId, addr, flag)`** (`L66-70`) — `onlyOwner`.
- **`setFeelessHook(hook)`** (`L76-84`) — `onlyOwner`. Hook must support `IJBFeelessHook`
  (ERC-165) or revert.

**Views:** `isFeelessFor(addr, projectId, caller)` — static OR with optional hook
(`try/catch`, reverting hook treated as `false`). `feelessHook`. **Invariant:** the hook can only
*widen* the feeless set, never shrink it (admin mappings OR'd with hook result).

### C.13 `JBERC20` — `src/JBERC20.sol`

Cloneable governance/permit ERC-20. One per project. Owned exclusively by `JBTokens`.

- **`initialize(name_, symbol_, tokensAddress)`** — clone-factory init, once. Sets
  `tokens = tokensAddress`.
- **`mint(account, amount)`** — `onlyTokens`. Only `JBTokens` can mint.
- **`burn(account, amount)`** — `onlyTokens`. Only `JBTokens` can burn.
- **`setMetadata(name, symbol)`** — `onlyTokens`.
- **`isValidSignature(hash, signature)`** — EIP-1271 view delegating to ERC20Permit.
- **`canBeAddedTo(projectId)`** — returns `false`; project-owned clones are deployed through `JBTokens`.
- **`getPastTotalActiveVotes(timepoint)`** — total voting units delegated to nonzero delegates at a past block.
- **`getTotalActiveVotes()`** — current total voting units delegated to nonzero delegates.
- Standard ERC-20 / ERC20Votes / ERC20Permit surface (`transfer`, `approve`, `permit`, `delegate`,
  `nonces`, etc.).

**Invariant:** `mint`/`burn` are restricted to `tokens`, so project-token supply is fully
mediated by `JBTokens` (which is in turn mediated by the project's controller). Projects that
use `setTokenFor` with an *external* ERC-20 do not have this guarantee — external supply changes
dilute cashouts (`JBTokens.totalSupplyOf` warning at L412-417).

**Active-vote invariant:** `getPastTotalSupply(...)` remains the ERC20Votes total-supply trace and includes
undelegated balances. `getPastTotalActiveVotes(...)` is the sum of voting units whose owner had a nonzero delegate at
the snapshot block. Moving tokens into an undelegated AMM removes those units from the active total; moving them back
to a holder whose delegate is still set adds them again for later snapshots without another delegation call.

### C.14 Chainlink price-feed adapters — `src/JBChainlinkV3PriceFeed.sol`, `src/JBChainlinkV3SequencerPriceFeed.sol`

- **`JBChainlinkV3PriceFeed.currentUnitPrice(decimals)`** (`L52-87`) — view. Reverts if:
  - the round is incomplete (`updatedAt == 0` or `answeredInRound < roundId`),
  - the price is stale (`block.timestamp > THRESHOLD + updatedAt`),
  - the price is non-positive (`price <= 0`).
- **`JBChainlinkV3SequencerPriceFeed.currentUnitPrice(decimals)`** (`L59-75`) — extends above
  with an L2 sequencer-uptime check. Reverts if:
  - the sequencer round is invalid (`startedAt == 0`),
  - the sequencer is down (`answer != 0`),
  - the sequencer has restarted within `GRACE_PERIOD_TIME` seconds.

**Invariant:** the feeds are deployed immutable (no setters). `JBPrices` rejects writes that
overwrite existing entries, so once a feed is registered for `(projectId, pricingCurrency,
unitCurrency)` at index 0 it is permanent. Adding backups appends — they win only when the
primary feed reverts or returns zero (`JBPrices._pricePerUnitOf`).

### C.15 `JBDeadline` (and `src/periphery/JBDeadline{1Day,3Days,3Hours,7Days}.sol`)

Approval-hook implementations used by projects that want minimum notice between ruleset
configuration and ruleset start.

- **`approvalStatusOf(projectId, rulesetId, startTimestamp) → JBApprovalStatus`** — view. Returns
  `Approved` if `startTimestamp - block.timestamp >= DURATION`, `ApprovalExpected` while the
  notice window is still open, otherwise `Failed`. Stateless.

The deadline contracts hold no state and grant no privileges.

---

## Section D — Cross-cutting invariants

1. **Token supply identity.** For every project,
   `totalSupplyOf(projectId) = totalCreditSupplyOf[projectId] + token.totalSupply()`
   (`JBTokens.sol:418-429`). Tracked separately as `totalTokenSupplyWithReservedTokensOf` =
   `totalSupplyOf + pendingReservedTokenBalanceOf` for cashout/bonding-curve math.
2. **Terminal solvency.** For each `(terminal, token)` pair,
   `IERC20(token).balanceOf(terminal) >= Σ_p balanceOf[terminal][p][token]`. Verified by
   `TerminalStoreInvariant.t.sol`. The `JBTerminalStore_InadequateTerminalStoreBalance` revert
   is the universal backstop on any debit path.
3. **Conservation.** Project inflows (pays, addToBalanceOf, held-fee returns) ≥ project outflows
   (cashouts, payouts, allowance, migration egress) + fees taken. Rounding is bounded by floor
   division (favors the protocol). Verified by `ComprehensiveInvariant.t.sol`.
4. **Fee project balance monotonic.** Project 1 (`FEE_BENEFICIARY_PROJECT_ID`) only gains
   protocol-fee value through `processHeldFeesOf` and immediate-fee paths
   (`useAllowanceOf`, migration). Verified by tests in `test/invariants/`.
5. **No flash-loan profit.** A `pay → cashOut` round trip in a single transaction is provably
   loss-making after fees. Verified by `FlashLoanAttacks.t.sol`.
6. **Hooks run with state already settled.** Pay hooks run after `mintTokensOf`; cashout hooks
   run after `burnTokensOf` and after beneficiary reclaim has been transferred; split hooks run
   after `STORE.recordPayoutFor` has already consumed payout-limit usage. A reverting hook never
   rolls back the user-facing settlement.
7. **Permission ID 0 reserved.** `setPermissionsFor` reverts if bit 0 is set in the packed
   permissions; `hasPermission` and `hasPermissions` revert for IDs > 255. The 256-bit packed
   bitmap is the full permission space.
8. **Ruleset existence.** After `launchProjectFor`/`launchRulesetsFor` succeeds,
   `RULESETS.currentOf(projectId)` always returns a non-zero ruleset until the project
   explicitly queues a `weight = 0` future ruleset (which is still a ruleset, just one that
   mints zero tokens per payment). Verified by `RulesetsInvariant.t.sol`.
9. **Append-only price feeds.** `JBPrices` never overwrites a registered feed. Primary feeds are
   index 0; backups append; lookup tries primary then backups then opposite-direction then
   project-0 defaults. Existing entries are immutable.
10. **One-shot bindings.** Each project can deploy at most one `JBERC20` via `deployERC20For`;
    can attach at most one external token via `setTokenFor`; each accounting context per
    `(terminal, projectId, token)` is set once. `JBProjects.transferFrom` is the only path
    that mutates project ownership.
11. **Ruleset gating cannot be circumvented for second-and-later controller changes.**
    `JBDirectory.setControllerOf` consults `controller.setControllerAllowed(projectId)` when a
    controller is already set. First-controller assignment requires the project owner, a
    `SET_CONTROLLER` operator, or an address on the directory-owner `isAllowedToSetFirstController`
    allowlist.
12. **Self-payout reverts.** A `sendPayoutsOf` split whose `split.projectId == projectId` (the
    source) reverts unconditionally — both the `pay`-shape and the `addToBalanceOf`-shape are
    disguised owner-mint paths that would bypass `allowOwnerMinting=false`
    (`JBMultiTerminal.sol:438-440`). The try/catch in the split-group library catches the revert
    and restores the balance.

---

## Section E — Out-of-scope centralization caveats

These are powers held by privileged addresses outside any individual project's control. They are
not third-party attack surface but they bound what "decentralized" means for a project hosted on
core.

- **`JBProjects` `onlyOwner`** controls:
  - `creationFee` (bounded by hardcoded `MAX_CREATION_FEE = 0.001 ether`, so the owner cannot
    price project creation out of reach),
  - `creationFeeReceiver`,
  - `tokenUriResolver` (project NFT metadata).
- **`JBDirectory` `onlyOwner`** controls:
  - `isAllowedToSetFirstController` — the allowlist of contracts that can register themselves as
    a project's controller when no controller is set yet. Compromise lets an attacker race a
    pre-launch project to install a malicious controller before the intended one.
- **`JBPrices` `onlyOwner`** controls:
  - default price feeds (`projectId == 0`). Existing defaults are immutable (append-only), but
    a malicious appended fallback could win when the primary reverts or returns zero. RISKS.md §1.
- **`JBFeelessAddresses` `onlyOwner`** controls:
  - global and per-project feeless lists, and the optional `feelessHook`. Hook can only widen
    the feeless set. Compromise lets an attacker grant fee-bypass to themselves; it cannot
    directly mint or drain a project.
- **`OMNICHAIN_RULESET_OPERATOR` (immutable on `JBController`)** bypasses owner permission on
  `launchRulesetsFor` and `queueRulesetsOf` for every project. The deployer is responsible for
  setting this to the canonical omnichain deployer on each chain; a wrong constant is a
  prerequisite trust failure (same actor controls the deploy keys). See RISKS.md §1 for the full
  deploy-time-verification trust note.

These owners are protocol-level admin held by the deployer's chosen owner (typically the NANA
ops multi-sig). They cannot directly mint or drain any specific project — every dangerous power
above either appends (never overwrites) or affects fee/feeless routing (never custody).

---

## Section F — Key code references

Ruleset queueing and approval:
- `src/JBController.sol:453-519` (launchRulesetsFor)
- `src/JBController.sol:630-658` (queueRulesetsOf)
- `src/JBRulesets.sol:107-205` (queueFor)
- `src/JBRulesets.sol:214-264` (updateRulesetWeightCache)
- `src/JBRulesets.sol:927-961` (_currentlyApprovableRulesetIdOf)

Mint / burn / supply:
- `src/JBController.sol:550-621` (mintTokensOf auth matrix)
- `src/JBController.sol:255-281` (burnTokensOf)
- `src/JBController.sol:665-667` + `:1222-1271` (sendReservedTokensToSplitsOf)
- `src/JBTokens.sol:82-131` (burnFrom — credits first)
- `src/JBTokens.sol:244-...` (mintFor with uint208 cap)
- `src/JBTokens.sol:418-429` (totalSupplyOf identity)

Payment / cashout / payout:
- `src/JBMultiTerminal.sol:667-712` (pay)
- `src/JBMultiTerminal.sol:310-343` (cashOutTokensOf)
- `src/JBMultiTerminal.sol:816-836` (sendPayoutsOf)
- `src/JBMultiTerminal.sol:862-900` (useAllowanceOf)
- `src/JBMultiTerminal.sol:576-646` (migrateBalanceOf)
- `src/JBTerminalStore.sol:398-425` (recordPaymentFrom)
- `src/JBTerminalStore.sol:438-511` (recordPayoutFor — caps at remaining payout limit)
- `src/JBTerminalStore.sol:299-...` (recordCashOutFor — local-surplus cap)

Fee / held-fee / fee-free surplus:
- `src/JBMultiTerminal.sol:117-130` (feeFreeSurplusOf semantics)
- `src/JBMultiTerminal.sol:724-790` (processHeldFeesOf reentrancy-safe)
- `src/JBMultiTerminal.sol:1923-...` (_returnHeldFees)
- `src/JBMultiTerminal.sol:86` (`_FEE_HOLDING_SECONDS = 2_419_200`)

Permissions:
- `src/JBPermissions.sol:66-114` (setPermissionsFor anti-escalation)
- `src/JBPermissions.sol:128-186` (hasPermissions — vacuous truth on empty)
- `src/JBPermissions.sol:200-233` (hasPermission)

Directory:
- `src/JBDirectory.sol:98-152` (setControllerOf — migration ordering)
- `src/JBDirectory.sol:176-204` (setPrimaryTerminalOf — implicit add)
- `src/JBDirectory.sol:212-251` (setTerminalsOf — controller bypass + dup check)

Price feeds:
- `src/JBPrices.sol:98-135` (addPriceFeedFor — append-only)
- `src/JBChainlinkV3PriceFeed.sol:52-87` (staleness + incomplete-round + negative-price guards)
- `src/JBChainlinkV3SequencerPriceFeed.sol:59-75` (L2 sequencer + grace period)

Splits / fund-access:
- `src/JBSplits.sol:92-127` (setSplitGroupsOf — controller vs self-managed)
- `src/JBSplits.sol:168-...` (_setSplitsOf — locked-split + percent enforcement)
- `src/JBFundAccessLimits.sol:84-187` (setFundAccessLimitsFor — currency ordering)

Projects:
- `src/JBProjects.sol:32` (`MAX_CREATION_FEE = 0.001 ether`)
- `src/JBProjects.sol:83-95` (setCreationFee)
- `src/JBProjects.sol:117-136` (createFor)

---

For ecosystem-wide invariants beyond this repo — revnet rulesets, suckers, buyback hook, 721
hook, distributors, application contracts — see [`../INVARIANTS.md`](../INVARIANTS.md).
