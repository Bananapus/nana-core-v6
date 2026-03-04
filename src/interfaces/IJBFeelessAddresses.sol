// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IJBFeelessAddresses {
    event SetFeelessAddress(address indexed addr, bool indexed isFeeless, address caller);

    function isFeeless(address addr) external view returns (bool);

    function setFeelessAddress(address addr, bool flag) external;
}
