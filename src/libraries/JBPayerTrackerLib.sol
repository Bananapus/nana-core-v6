// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPayerTracker} from "../interfaces/IJBPayerTracker.sol";

/// @notice Resolves the original payer behind a forwarded payment by probing the immediate caller for
/// `IJBPayerTracker`. Shared by every contract that forwards a project-creation fee (`JBProjects`, `JBController`,
/// and the project deployers) so they advertise a consistent payer to the fee receiver, and so a chain of
/// forwarders resolves to the true originator instead of an intermediary contract.
library JBPayerTrackerLib {
    /// @notice Resolve the original payer to attribute a forwarded payment to.
    /// @dev If `sender` is a contract exposing a non-zero `IJBPayerTracker.originalPayer()`, that upstream payer is
    /// returned (so a multi-hop forwarder chain resolves to the true originator). Otherwise `sender` itself is the
    /// payer. The probe is a `staticcall`, so a reverting or non-conformant caller falls back to `sender` instead of
    /// bubbling up.
    /// @param sender The immediate (ERC-2771-resolved) caller forwarding the payment.
    /// @return payer The address to credit as the original payer.
    function resolve(address sender) internal view returns (address payer) {
        // EOAs and contracts without code can't implement `IJBPayerTracker` — they are the payer themselves.
        if (sender.code.length == 0) return sender;

        // Probe the caller for an upstream payer; fall back to the caller on any failure.
        (bool ok, bytes memory data) = sender.staticcall(abi.encodeCall(IJBPayerTracker.originalPayer, ()));
        if (!ok || data.length < 32) return sender;

        // A zero upstream means the caller is itself the direct payer.
        address upstream = abi.decode(data, (address));
        return upstream == address(0) ? sender : upstream;
    }
}
