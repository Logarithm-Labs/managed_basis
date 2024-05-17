// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IBasisGmxFactory} from "src/interfaces/IBasisGmxFactory.sol";

contract BasisGmxFactory is IBasisGmxFactory, OwnableUpgradeable, UUPSUpgradeable {
    string constant API_VERSION = "0.0.1";

    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
    }

    function _authorizeUpgrade(address) internal virtual override onlyOwner {}

    /// @inheritdoc IBasisGmxFactory
    function apiVersion() external pure override returns (string memory) {
        return API_VERSION;
    }
}
