# nana-core-v6 — Risks

## Trust Assumptions

### What You Trust

1. **Shared Infrastructure** — All projects share the same JBMultiTerminal and JBController instances. A bug in these contracts affects every project.
2. **Project Owner** — The ERC-721 holder can queue new rulesets, set terminals, configure splits, and delegate permissions. A malicious or compromised owner can fundamentally change project economics.
3. **Data Hooks** — If a ruleset specifies a data hook, that hook has absolute control over token minting weights and cash out parameters. A malicious data hook can drain the entire project treasury.
4. **Approval Hooks** — Can approve or reject ruleset transitions. A reverting approval hook doesn't freeze the project (try-catch fallback), but a malicious one could allow unexpected transitions.
5. **Price Feeds** — Surplus calculations depend on Chainlink price feeds. Stale or manipulated feeds affect cash out values and payout calculations. Staleness causes reverts (DoS), not fund loss.
6. **Fee Project (#1)** — 2.5% fees go to project #1. If project #1's terminal is misconfigured, fees are returned to the originating project's balance (not lost).

### What You Do NOT Need to Trust

- **Other projects** — Each project's balance is isolated by terminal address in JBTerminalStore
- **Token holders** — Can only cash out proportional to the bonding curve
- **Permit2** — Optional; projects work without it

## Known Risks

### By Design

| Risk | Description | Mitigation |
|------|-------------|------------|
| Data hook omnipotence | Data hooks override bonding curve parameters | Only use audited, trusted data hooks |
| Last-holder advantage | Last token holder redeems remaining surplus at 1:1 | Bonding curve math; inherent to the design |
| Pending reserved inflation | Pending reserved tokens dilute cash out values | Call `sendReservedTokensToSplitsOf` regularly |
| No reentrancy guard | Protocol relies on CEI ordering, not mutex | State updates before all external calls |
| Weight cache requirement | Projects with >20k cycles need progressive cache updates | Anyone can call `updateRulesetWeightCache` |

### Operational

| Risk | Description | Mitigation |
|------|-------------|------------|
| Price feed DoS | Stale/reverting price feed blocks multi-currency operations | Monitor feed health; single-currency projects unaffected |
| Split gas exhaustion | Very large split arrays (100+) may exceed block gas | Keep split count reasonable (<50) |
| Held fee growth | Held fees array grows without cleanup | `_nextHeldFeeIndexOf` pointer skips processed entries |

## Reentrancy Analysis

No `ReentrancyGuard`. Relies on state ordering (checks-effects-interactions):

| Function | State Updated Before External Call | Risk |
|----------|-----------------------------------|------|
| `_cashOutTokensOf` | Store balance deducted, tokens burned BEFORE transfer | LOW |
| `_pay` | Store balance added, tokens minted BEFORE pay hooks | LOW |
| `executePayout` | Payout limit recorded BEFORE split hook calls | LOW |
| `processHeldFeesOf` | Index updated BEFORE fee processing | LOW |
| `_sendReservedTokensToSplitsOf` | Pending balance zeroed BEFORE minting | LOW |

**Key defense:** `JBTerminalStore_InadequateTerminalStoreBalance` revert prevents extracting more than available balance regardless of reentrancy.

## Permission Security

- ROOT (ID 1) grants all permissions but cannot be set for wildcard `projectId = 0`
- ROOT operators cannot grant ROOT to other addresses
- Permission 0 is reserved and cannot be set
- All permission checks support ERC-2771 meta-transactions

## Proven Invariants

1. No flash-loan profit (12 attack vectors tested)
2. Terminal balance >= sum of recorded project balances
3. Total inflows >= total outflows
4. Fee project balance monotonically increases
5. Token supply = creditSupply + erc20.totalSupply()
6. Current ruleset always exists after launch
