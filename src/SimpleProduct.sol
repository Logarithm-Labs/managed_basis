// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { LogBaseVaultUpgradeable } from "src/LogBaseVaultUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract SimpleProduct is Initializable, UUPSUpgradeable, LogBaseVaultUpgradeable {

    function _authorizeUpgrade(address /*newImplementation*/) internal virtual override {}
    
}