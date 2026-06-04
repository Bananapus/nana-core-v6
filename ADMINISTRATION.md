# Administration

## At a glance

| Item | Details |
| --- | --- |
| Scope | Core Juicebox V6 control plane: directory, controller, terminals, permissions, prices, and global protocol switches |
| Control posture | Mixed protocol-owner, project-owner, delegated-operator, controller, and terminal control |
| Highest-risk actions | Controller migration, terminal migration, token binding, price-feed fallback installation, feeless-list changes, and broad permission grants |
| Recovery posture | Project-local mistakes may be fixable if rulesets allow it; immutable infra mistakes usually require replacement and migration |

## Purpose

`nana-core-v6` is the main control plane in the stack. It mixes protocol-owned contracts, project-local ownership, delegated operators through `JBPermissions`, and ruleset flags that allow or block changes. This file explains who can still change project behavior after core is live.

## Control model

- Protocol-wide `Ownable` surfaces exist on `JBDirectory`, `JBProjects`, `JBPrices`, and `JBFeelessAddresses`.
- Project-local control comes from the project NFT owner in `JBProjects`.
- Fine-grained operator delegation comes from `JBPermissions`.
- Controllers and terminals become privileged system callers once the directory points to them.
- The current ruleset can further allow or deny owner or operator actions.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Project owner | `JBProjects.ownerOf(projectId)` | Per project | Main human control surface |
| Project operator | `JBPermissions` grant | Per project or wildcard | Can be narrow or dangerously broad |
| Controller | `JBDirectory.controllerOf(projectId)` | Per project | Manages rulesets, token setup, splits, and fund-access config |
| Terminal | `JBDirectory` terminal set | Per project | Moves funds through `JBTerminalStore` and terminal entrypoints |
| Protocol owner | `Ownable(owner)` on protocol-wide contracts | Global | Different contracts can have different owners |
| Omnichain ruleset operator | `JBController` constructor immutable | Global or broad | Bypasses some owner checks for synchronized ruleset flows |

## Privileged surfaces

High-value admin functions include:

- `JBDirectory.setControllerOf(...)`, `setTerminalsOf(...)`, `setPrimaryTerminalOf(...)`
- `JBController.queueRulesetsOf(...)`, `launchRulesetsFor(...)`, `setSplitGroupsOf(...)`, `deployERC20For(...)`, `setTokenFor(...)`, `setUriOf(...)`, `addPriceFeedFor(...)`
- `JBMultiTerminal.useAllowanceOf(...)`, `migrateBalanceOf(...)`, `cashOutTokensOf(...)` when permission-gated by the holder or delegated authority
- `JBPermissions.setPermissionsFor(...)`
- `JBPrices.addPriceFeedFor(...)` for protocol defaults or project-local feed fallbacks
- `JBFeelessAddresses.setFeelessAddress(...)`, `setFeelessAddressFor(...)`, `setFeelessHook(...)`
- `JBProjects.setTokenUriResolver(...)`
- `JBProjects.setCreationFee(...)`

The practical split is simple:

- protocol owners change global infrastructure or defaults
- project owners and operators change project configuration
- controllers and terminals act with the authority core gives them

## Immutable and one-way decisions

- Price feeds are append-only. Existing feeds cannot be edited or removed; later feeds are backups after the current primary feed.
- ERC-20 token binding for a project is effectively one-time.
- The fee beneficiary project ID inside `JBMultiTerminal` is hardcoded.
- Constructor immutables on controller, directory, terminal, store, prices, and tokens cannot be patched.
- The project creation fee owner can set in `JBProjects` is bounded by the hardcoded `MAX_CREATION_FEE` (`0.001 ether`). The owner cannot lift this ceiling.

## Operational notes

- Use narrow project-scoped permissions instead of wildcard or ROOT permissions when possible.
- Check whether the active ruleset allows the change before assuming the owner or operator can make it.
- Treat controller migration, terminal migration, token deployment, fee-exemption changes, and price-feed installation as high-blast-radius control-plane changes.
- Read both the permission check and the current ruleset flags before concluding an action is allowed.
- Keep fee-route and payout-path failure semantics in mind. Some failures restore project balance instead of trapping funds.

## Machine notes

- Do not infer authority from project ownership alone. Many paths also depend on the active ruleset and permission bitmap.
- Treat `JBDirectory`, `JBController`, `JBMultiTerminal`, `JBPermissions`, `JBPrices`, `JBFeelessAddresses`, and `JBProjects` as the minimum control-plane source set.
- If a controller, terminal, or price-feed action is not backed by the exact current directory entry, stop and resolve the mismatch first.
- If a permission is not named explicitly in the call path, inspect the contract check before assuming delegated authority exists.
- If a fee route or split payout failed, check whether core restored balance or left a retry path before calling it a permanent loss.

## Recovery

- Wrong immutable infrastructure usually means deploying a new controller, terminal, store, or price layer and then migrating.
- Wrong project-local config can often be corrected if the current ruleset still allows it.
- Wrong wildcard permissions are fixed by updating the permission bitmap, but they are dangerous because of what can happen before revocation.
- Some fee-route and payout-route failures are recoverable in place because core prefers liveness over trapped funds.

## Admin boundaries

- Protocol owners cannot directly rewrite project economics without going through the contracts and ruleset constraints that enforce those changes.
- Project owners cannot bypass immutable constructor references or rewrite existing price-feed entries; if rulesets allow it, they can append fallback feeds.
- Controllers and terminals only have the authority given by the directory and core contracts.
- Nobody can change the hardcoded fee beneficiary or patch immutable deployment mistakes in place.

## Source map

- `src/JBDirectory.sol`
- `src/JBController.sol`
- `src/JBMultiTerminal.sol`
- `src/JBPermissions.sol`
- `src/JBPrices.sol`
- `src/JBFeelessAddresses.sol`
- `src/JBProjects.sol`
- `test/units/static/JBController/`
- `test/units/static/JBDirectory/`
- `test/units/static/JBMultiTerminal/`
- `test/units/static/JBPermissions/`
- `test/units/static/JBPrices/`
