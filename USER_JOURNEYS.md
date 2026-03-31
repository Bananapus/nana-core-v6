# User Journeys

## Who This Repo Serves

- founders launching programmable treasuries
- supporters paying into projects
- token holders cashing out or receiving distributions
- integrators building on top of the base protocol

## Journey 1: Launch A Project

**Starting state:** you know the project's owner, accepted terminals, and the first ruleset configuration.

**Success:** the project exists, its ruleset is active, and the treasury can start accepting funds.

**Flow**
1. Call `JBController.launchProjectFor(...)`.
2. The project NFT is minted to the owner.
3. The controller installs the initial ruleset chain and terminal configuration.
4. Optional hooks, splits, reserved-rate behavior, and permissions become part of the ruleset metadata.
5. The project is now ready for payments, payouts, and future ruleset changes.

## Journey 2: Accept Payments And Issue Project Tokens

**Starting state:** the project has an active ruleset and a terminal that accepts the incoming asset.

**Success:** the treasury receives funds and the beneficiary receives the right amount of project token exposure.

**Flow**
1. A payer calls `pay(...)` on the relevant terminal.
2. The terminal records the payment and asks the store to derive minting behavior from the current ruleset.
3. The beneficiary receives project token credits or ERC-20 tokens according to the project's issuance setup.
4. Any configured data hooks or pay hooks run in the positions the protocol expects.

**Edge conditions that change user experience:** paused payments, zero weight, custom hook overrides, unsupported tokens, and fee-on-transfer accounting.

## Journey 3: Distribute Funds Or Let Holders Exit

**Starting state:** the project has treasury balance or surplus, and either the owner wants to distribute funds or a holder wants to redeem.

**Success:** funds leave the treasury through the intended governed path instead of arbitrary withdrawals.

**Flow**
1. The owner or authorized operator calls payout distribution functions within the active fund access limits.
2. Split recipients, other projects, and fee beneficiaries receive their configured shares.
3. Separately, token holders can call `cashOutTokensOf(...)` to burn project tokens for surplus exposure along the bonding curve.
4. The active cash-out tax rate, pending reserved tokens, and hooks all influence the result.

## Journey 4: Change Economics Without Migrating The Project

**Starting state:** the project is live and future behavior needs to change.

**Success:** new rulesets are queued cleanly and activate on schedule.

**Flow**
1. The owner or an authorized operator queues new rulesets.
2. Approval hooks, if present, can accept or reject the transition.
3. When the active ruleset expires or the timeline advances, the next approved ruleset takes over.
4. The project continues under the same identity and treasury while its economics evolve.

## Hand-Offs

- Use [nana-permission-ids-v6](../nana-permission-ids-v6/USER_JOURNEYS.md) for the permission vocabulary.
- Use the hook and deployer repos when you want a product opinion layered on top of this base protocol.
