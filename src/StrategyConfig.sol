// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract StrategyConfig is UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.StrategyConfig
    struct StrategyConfigStorage {
        uint256 deutilizationThreshold;
        uint256 rebalanceDeviationThreshold;
        uint256 hedgeDeviationThreshold;
        uint256 responseDeviationThreshold;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.StrategyConfig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StrategyConfigStorageLocation =
        0xfbbde6e648f8f543a6d34a388f16c117d911b0f754c63693128ec06eebe01300;

    function _getStrategyConfigStorage() private pure returns (StrategyConfigStorage storage $) {
        assembly {
            $.slot := StrategyConfigStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);

        StrategyConfigStorage storage $ = _getStrategyConfigStorage();
        $.responseDeviationThreshold = 1e16;
        $.hedgeDeviationThreshold = 1e16; // 1%
        $.rebalanceDeviationThreshold = 1e17; // 10%
        $.deutilizationThreshold = 1e16; // 1%
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setDeutilizationThreshold(uint256 threshold) external onlyOwner {
        require(threshold < 1 ether);
        _getStrategyConfigStorage().deutilizationThreshold = threshold;
    }

    function setRebalanceDeviationThreshold(uint256 threshold) external onlyOwner {
        require(threshold < 1 ether);
        _getStrategyConfigStorage().rebalanceDeviationThreshold = threshold;
    }

    function setHedgeDeviationThreshold(uint256 threshold) external onlyOwner {
        require(threshold < 1 ether);
        _getStrategyConfigStorage().hedgeDeviationThreshold = threshold;
    }

    function setResponseDeviationThreshold(uint256 threshold) external onlyOwner {
        require(threshold < 1 ether);
        _getStrategyConfigStorage().responseDeviationThreshold = threshold;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deutilizationThreshold() external view returns (uint256) {
        return _getStrategyConfigStorage().deutilizationThreshold;
    }

    function rebalanceDeviationThreshold() external view returns (uint256) {
        return _getStrategyConfigStorage().rebalanceDeviationThreshold;
    }

    function hedgeDeviationThreshold() external view returns (uint256) {
        return _getStrategyConfigStorage().hedgeDeviationThreshold;
    }

    function responseDeviationThreshold() external view returns (uint256) {
        return _getStrategyConfigStorage().responseDeviationThreshold;
    }
}
