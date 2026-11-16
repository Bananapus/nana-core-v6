# Held fallbacks: no try/catch branch may redirect value

Rule: when an untrusted call inside a batch fails, the amount is held for the same recipient in this contract's
storage and anyone can retry it with a plain (propagating) call. Nothing is forgiven, skipped, burned or rerouted,
so the gas a caller picks can never change who ends up with the money. No gas constants anywhere.

- [x] Fee processing (`_processFee`): on failure re-hold the fee in `_heldFeesOf` with no lock, instead of
      crediting it back to the paying project as fee-free surplus. `processHeldFeesOf` retries it and re-holds a fee
      that fails again at the end of the queue. `JBHeldFees.hold` owns the record.
- [x] Payout splits (`JBPayoutSplitGroupLib`): on failure hold the gross amount in `heldPayoutOf[projectId][token][splitHash]`
      instead of restoring project balance. Split hook reverts propagate to the same catch (no inner swallow).
      Direct splits with no beneficiary get the caller written in before anything is paid or held.
- [x] Leftover payout to the owner: same escrow, keyed by a beneficiary-only split for the owner.
- [x] `processHeldPayoutOf(projectId, token, split)`: permissionless retry through `executePayout` with no catch;
      fee taken as in `_sendPayoutsOf`.
- [x] Reserved token splits (`JBController`): refactor the per-split body into `_sendReservedTokensToSplit`, then
      hold on failure in `heldReservedTokensOf[projectId][token][splitHash]` (hook revert: keep the tokens instead of
      burning; project pay revert: keep instead of sending raw tokens to the beneficiary).
      `processHeldReservedTokensOf(projectId, token, split)` reruns the same code and reverts if it re-held.
- [x] `JBHeldSplits`: one external library owns the held-split ledger shape, `HoldSplit` and `ProcessHeldSplit`,
      used by the terminal and the controller.
- [ ] Size: JBMultiTerminal fits (96 bytes margin). JBController is about 530 bytes over EIP-170 with this change
      (main has 291 bytes of margin). Landing it needs the reserved split distribution moved into an external
      library the way the terminal already does with `JBPayoutSplitGroupLib`; that is a separate refactor PR.
- [ ] Tests: not in scope for this PR (user: "dont worry about tests yet"); existing tests asserting forgiveness
      will need rewriting.

Out of scope here: JBPrices/JBRulesets/JBFeelessAddresses/decimals try/catch (reads, no value), Permit2 catch
(a failed permit only makes the later transfer revert).
