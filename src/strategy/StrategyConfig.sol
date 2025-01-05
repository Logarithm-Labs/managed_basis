// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title StrategyConfig
/// @author Logarithm Labs
/// @notice A config smart contract that is used throughout all logarithm strategies.
/// @dev Deployed according to the UUPS upgradable pattern.
contract StrategyConfig is UUPSUpgradeable, Ownable2StepUpgradeable {
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

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DeutilizationThresholdUpdated(address indexed account, uint256 value);
    event RebalanceDeviationThresholdUpdated(address indexed account, uint256 value);
    event HedgeDeviationThresholdUpdated(address indexed account, uint256 value);
    event ResponseDeviationThresholdUpdated(address indexed account, uint256 value);

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        _setResponseDeviationThreshold(1e16); // 1%
        _setHedgeDeviationThreshold(1e16); // 1%
        _setRebalanceDeviationThreshold(1e17); // 10%
        _setDeutilizationThreshold(1e16); // 1%
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    function _setDeutilizationThreshold(uint256 threshold) private {
        require(threshold < 1 ether);
        if (deutilizationThreshold() != threshold) {
            _getStrategyConfigStorage().deutilizationThreshold = threshold;
            emit DeutilizationThresholdUpdated(_msgSender(), threshold);
        }
    }

    function _setRebalanceDeviationThreshold(uint256 threshold) private {
        require(threshold < 1 ether);
        if (rebalanceDeviationThreshold() != threshold) {
            _getStrategyConfigStorage().rebalanceDeviationThreshold = threshold;
            emit RebalanceDeviationThresholdUpdated(_msgSender(), threshold);
        }
    }

    function _setHedgeDeviationThreshold(uint256 threshold) private {
        require(threshold < 1 ether);
        if (hedgeDeviationThreshold() != threshold) {
            _getStrategyConfigStorage().hedgeDeviationThreshold = threshold;
            emit HedgeDeviationThresholdUpdated(_msgSender(), threshold);
        }
    }

    function _setResponseDeviationThreshold(uint256 threshold) private {
        require(threshold < 1 ether);
        if (responseDeviationThreshold() != threshold) {
            _getStrategyConfigStorage().responseDeviationThreshold = threshold;
            emit ResponseDeviationThresholdUpdated(_msgSender(), threshold);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setDeutilizationThreshold(uint256 threshold) external onlyOwner {
        _setDeutilizationThreshold(threshold);
    }

    function setRebalanceDeviationThreshold(uint256 threshold) external onlyOwner {
        _setRebalanceDeviationThreshold(threshold);
    }

    function setHedgeDeviationThreshold(uint256 threshold) external onlyOwner {
        _setHedgeDeviationThreshold(threshold);
    }

    function setResponseDeviationThreshold(uint256 threshold) external onlyOwner {
        _setRebalanceDeviationThreshold(threshold);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deutilizationThreshold() public view returns (uint256) {
        return _getStrategyConfigStorage().deutilizationThreshold;
    }

    function rebalanceDeviationThreshold() public view returns (uint256) {
        return _getStrategyConfigStorage().rebalanceDeviationThreshold;
    }

    function hedgeDeviationThreshold() public view returns (uint256) {
        return _getStrategyConfigStorage().hedgeDeviationThreshold;
    }

    function responseDeviationThreshold() public view returns (uint256) {
        return _getStrategyConfigStorage().responseDeviationThreshold;
    }
}
