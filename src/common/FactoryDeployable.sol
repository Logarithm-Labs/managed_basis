// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Errors} from "src/libraries/utils/Errors.sol";

abstract contract FactoryDeployable is Initializable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.FactoryDeployable
    struct FactoryDeployableStorage {
        address factory;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.FactoryDeployable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FactoryDeployableStorageLocation =
        0x73ba942c18131837d507bb81d25d682705c8eed37c2e5b83dc64f612c28c7800;

    function _getFactoryDeployableStorage() private pure returns (FactoryDeployableStorage storage $) {
        assembly {
            $.slot := FactoryDeployableStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyFactory() {
        _checkFactory();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function __FactoryDeployable_init() internal onlyInitializing {
        FactoryDeployableStorage storage $ = _getFactoryDeployableStorage();
        $.factory = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEWERS
    //////////////////////////////////////////////////////////////*/

    function factory() public view returns (address) {
        FactoryDeployableStorage storage $ = _getFactoryDeployableStorage();
        return $.factory;
    }

    function _checkFactory() internal view {
        if (msg.sender != factory()) {
            revert Errors.CallerNotFactory();
        }
    }
}
