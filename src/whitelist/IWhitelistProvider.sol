// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IWhitelistProvider {
    function isWhitelisted(address user) external view returns (bool);
}
