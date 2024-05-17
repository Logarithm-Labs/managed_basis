// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";

import {IBasisGmxFactory} from "src/interfaces/IBasisGmxFactory.sol";
import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";
import {IGmxV2PositionManager} from "src/interfaces/IGmxV2PositionManager.sol";

import {Errors} from "./Errors.sol";

/// @title A gmx position manager
/// @author Logarithm Labs
/// @dev this contract must be deployed only by the factory
contract GmxV2PositionManager is IGmxV2PositionManager, UUPSUpgradeable {
    string constant API_VERSION = "0.0.1";
    uint256 constant PRECISION = 1e18;

    /// @notice used for processing status
    enum Stages {
        Idle,
        Pending
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager.Config
    struct ConfigStorage {
        address _factory;
        address _strategy;
        address _marketToken;
        address _indexToken;
        address _longToken;
        address _shortToken;
        bytes32 _positionKey;
    }

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager.State
    struct StateStorage {
        Stages _stage;
        uint256 _pendingAssets;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxV2PositionManager.Config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ConfigStorageLocation = 0x51e553f1ed05f39323723017580800f12e204b6a09a61aeb584366ce03172f00;

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxV2PositionManager.State")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StateStorageLocation = 0x9a05e65897e43e5729051b7a8b9a904f0ad0efe51cf504c7b850ba952775e500;

    function _getConfigStorage() private pure returns (ConfigStorage storage $) {
        assembly {
            $.slot := ConfigStorageLocation
        }
    }

    function _getStateStorage() private pure returns (StateStorage storage $) {
        assembly {
            $.slot := StateStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyStrategy() {
        _onlyStrategy();
        _;
    }

    function initialize(address strategy) external initializer {
        address factory = msg.sender;
        address asset = address(IBasisStrategy(strategy).asset());
        address product = address(IBasisStrategy(strategy).product());
        address marketKey = IBasisGmxFactory(factory).marketKey(asset, product);
        if (marketKey == address(0)) {
            revert Errors.InvalidMarket();
        }
        address dataStore = IBasisGmxFactory(factory).dataStore();
        address reader = IBasisGmxFactory(factory).reader();
        Market.Props memory market = IReader(reader).getMarket(dataStore, marketKey);
        if (market.shortToken != asset || market.longToken != product) {
            revert Errors.InvalidInitializationAssets();
        }
        // always short position
        bytes32 positionKey = keccak256(abi.encode(address(this), market.marketToken, market.shortToken, false));

        ConfigStorage storage $ = _getConfigStorage();
        $._factory = factory;
        $._strategy = strategy;
        $._marketToken = market.marketToken;
        $._indexToken = market.indexToken;
        $._longToken = market.longToken;
        $._shortToken = market.shortToken;
        $._positionKey = positionKey;
    }

    function _authorizeUpgrade(address) internal virtual override {
        ConfigStorage storage $ = _getConfigStorage();
        if (msg.sender != $._factory) {
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
        ConfigStorage storage $ = _getConfigStorage();
        if (msg.sender != $._strategy) {
            revert Errors.CallerNotStrategy();
        }
    }
}
