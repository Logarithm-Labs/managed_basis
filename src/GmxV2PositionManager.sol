// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IGmxV2PositionManager} from "src/interfaces/IGmxV2PositionManager.sol";

import {Errors} from "./Errors.sol";

/// @title A gmx position manager
/// @author Logarithm Labs
/// @dev this contract should be deployed only by the factory
contract GmxV2PositionManager is IGmxV2PositionManager, UUPSUpgradeable {
    string constant API_VERSION = "0.0.1";
    uint256 constant PRECISION = 1e18;

    /// @notice used for processing status
    enum Stages {
        Idle,
        Increase,
        Decrease
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager
    struct GmxV2PositionManagerStorage {
        Stages _stage;
        address _factory;
        address _strategy;

        address _shortToken;
        address _longToken;
        address _indexToken;
        address _marketToken;
        bytes32 _positionKey;

        uint256 _pendingAssets;

        // uint256 totalClaimedFundingShortToken;
        // uint256 totalClaimedFundingLongToken;
        // uint256 accumulatedPositionFees;

        // uint256 accumulatedBorrowingFees;
        // uint256 accumulatedFundingFees;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxV2PositionManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GmxV2PositionManagerStorageLocation = 0xeef3dac4538c82c8ace4063ab0acd2d15cdb5883aa1dff7c2673abb3d8698400;

    function _getGmxV2PositionManagerStorage() private pure returns (GmxV2PositionManagerStorage storage $) {
        assembly {
            $.slot := GmxV2PositionManagerStorageLocation
        }
    }

    modifier onlyStrategy() {
        _onlyStrategy();
        _;
    }

    function initialize(address _strategy) external initializer {

    }

    function _authorizeUpgrade(address) internal virtual override {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        if(msg.sender != $._factory) {
            revert Errors.UnauthoirzedUpgrade();
        }
    }

    /// @inheritdoc IGmxV2PositionManager
    function apiVersion() external pure override returns (string memory) {
        return API_VERSION;
    }

    /// @inheritdoc IGmxV2PositionManager
    function increasePosition(uint256 collateralDelta, uint256 sizeDeltaInTokens)
        external
        payable
        override
        onlyStrategy
        returns (bytes32)
    {}

    /// @inheritdoc IGmxV2PositionManager
    function decreasePosition(uint256 collateralDelta, uint256 sizeDeltaInTokens)
        external
        payable
        override
        onlyStrategy
        returns (bytes32)
    {}

    /// @inheritdoc IGmxV2PositionManager
    function claim() external override {}

    /// @inheritdoc IGmxV2PositionManager
    function totalAssets() external view override returns (uint256) {}

    /// @inheritdoc IGmxV2PositionManager
    function getExecutionFee() external view override returns (uint256 feeIncrease, uint256 feeDecrease) {}


    // this is used in modifier which reduces the code size
    function _onlyStrategy() private view {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        if(msg.sender != $._strategy) {
            revert Errors.CallerNotStrategy();
        }
    }
}
