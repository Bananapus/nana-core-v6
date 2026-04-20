# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Core Juicebox V6 control plane: directory, controller, terminals, permissions, prices, and global protocol switches |
| Control posture | Mixed protocol-owner, project-owner, delegated-operator, controller, and terminal control |
| Highest-risk actions | Controller migration, terminal migration, token binding, price-feed installation, and broad permission grants |
| Recovery posture | Project-local mistakes may be fixable if rulesets permit; immutable infra mistakes usually require replacement layers and migration |

## Purpose

`nana-core-v6` is the largest control plane in the stack. It combines protocol-owned contracts, project-local ownership, delegated operators through `JBPermissions`, and ruleset flags that selectively permit or forbid changes. This file is about who can still change project behavior once the core is live.

## Control Model

- Protocol-wide `Ownable` surfaces exist on `JBDirectory`, `JBProjects`, `JBPrices`, and `JBFeelessAddresses`.
- Project-local control runs through the project NFT owner in `JBProjects`.
- Fine-grained operator delegation runs through `JBPermissions`.
- Controllers and terminals are privileged system callers once the directory points to them.
- Current ruleset flags can further allow or deny certain owner or operator actions.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Project owner | `JBProjects.ownerOf(projectId)` | Per project | Root human control surface for a project |
| Project operator | `JBPermissions` grant | Per project or wildcard | Can be narrow or dangerously broad |
| Controller | `JBDirectory.controllerOf(projectId)` | Per project | Manages rulesets, token setup, splits, and fund-access config |
| Terminal | `JBDirectory` terminal set | Per project | Can move funds through `JBTerminalStore` and terminal entrypoints |
| Protocol owner | `Ownable(owner)` on protocol-wide contracts | Global | Different contracts have different owners |
| Omnichain ruleset operator | `JBController` constructor immutable | Global or broad | Bypasses some ordinary owner paths for synchronized ruleset flows |

## Privileged Surfaces

High-value admin functions include:

- `JBDirectory.setControllerOf(...)`, `setTerminalsOf(...)`, `setPrimaryTerminalOf(...)`
- `JBController.queueRulesetsOf(...)`, `launchRulesetsFor(...)`, `setSplitGroupsOf(...)`, `deployERC20For(...)`, `setTokenFor(...)`, `setUriOf(...)`, `addPriceFeedFor(...)`
- `JBMultiTerminal.useAllowanceOf(...)`, `migrateBalanceOf(...)`, `cashOutTokensOf(...)` when permission-gated by the holder or delegated authority
- `JBPermissions.setPermissionsFor(...)`
- `JBPrices.addPriceFeedFor(...)` for protocol defaults or project-local feeds
- `JBFeelessAddresses.setFeelessAddress(...)`
- `JBProjects.setTokenUriResolver(...)`

The most important practical distinction is:

- protocol owners change global infrastructure or defaults
- project owners and their operators change project configuration
- controllers and terminals are trusted system actors once the directory points to them

## Immutable And One-Way

- Default or project-specific price feeds are write-once for a given pair.
- ERC-20 token binding decisions for a project are effectively one-time.
- The fee beneficiary project ID inside `JBMultiTerminal` is hardcoded.
- Constructor immutables on controller, directory, terminal, store, prices, and tokens are not patchable.

## Operational Notes

- Use narrow project-scoped permissions instead of wildcard or ROOT permissions whenever possible.
- Validate whether the active ruleset allows the change before assuming the owner or operator can perform it.
- Treat controller migration, terminal migration, token deployment, and price-feed installation as control-plane changes with large blast radius.
- Read both the permission check and the current ruleset flags before concluding an action is allowed.
- Keep an eye on fee-route and payout-path failure semantics: some failures are intentionally caught so funds stay recoverable instead of being permanently trapped.

## Machine Notes

- Do not infer authority from project ownership alone; many paths also depend on the active ruleset and permission bitmap.
- Treat `JBDirectory`, `JBController`, `JBMultiTerminal`, `JBPermissions`, `JBPrices`, `JBFeelessAddresses`, and `JBProjects` as the minimum source-of-truth set for control-plane crawling.
- If a controller, terminal, or price-feed action is not backed by the exact current directory entry, stop and resolve the mismatch first.
- If a permission is not named explicitly in the call path, inspect the contract check before assuming delegated authority exists.
- If a fee route or split payout failed, inspect whether the core intentionally restored project balance or left a retry path before calling it a permanent loss.

## Recovery

- Wrong immutable infra usually means a new controller, terminal, store, or price layer and then migration.
- Wrong project-local config can often be corrected if the current ruleset still permits the change.
- Wrong wildcard permissions are fixable only by updating the permission bitmap; they are dangerous mainly because of what can happen before revocation.
- Some fee-route and payout-route failures are recoverable in place because the core prefers restoring balance and preserving retry paths over trapping funds.

## Admin Boundaries

- Protocol owners cannot directly rewrite project economics without going through the contracts and ruleset constraints that enforce those changes.
- Project owners cannot bypass immutable constructor references or rewrite existing price-feed entries.
- Controllers and terminals only have the authority the directory and core contracts give them; they do not get arbitrary global power.
- Nobody can change the hardcoded fee beneficiary or retroactively patch immutable deployment mistakes in place.

## Source Map

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
