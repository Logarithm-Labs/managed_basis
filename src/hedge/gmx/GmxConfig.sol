// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";

/// @title GmxConfig
/// @author Logarithm Labs
contract GmxConfig is UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxConfig
    struct GmxConfigStorage {
        address dataStore;
        address exchangeRouter;
        address orderHandler;
        address orderVault;
        address referralStorage;
        address reader;
        uint256 callbackGasLimit;
        bytes32 referralCode;
        uint256 maxClaimableFundingShare;
        uint256 limitDecreaseCollateral;
        uint256 realizedPnlDiffFactor;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxConfig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GmxConfigStorageLocation =
        0x1e3aaedb53cd624bf0cd11c78d19d483bc92f075987e5791fdd0ed2484ab1200;

    function _getGmxConfigStorage() private pure returns (GmxConfigStorage storage $) {
        assembly {
            $.slot := GmxConfigStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CallbackGasLimitUpdated(address indexed account, uint256 newGasLimit);
    event ReferralCodeUpdated(address indexed account, bytes32 newReferralCode);
    event MaxClaimableFundingShareUpdated(address indexed account, uint256 newFundingShare);
    event LimitDecreaseCollateralUpdated(address indexed account, uint256 newLimitDecreaseCollateral);
    event RealizedPnlDiffFactorUpdated(address indexed account, uint256 newRealizedPnlDiffFactor);

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_, address exchangeRouter_, address reader_) external initializer {
        __Ownable_init(owner_);
        _updateAddresses(exchangeRouter_, reader_);
        _setCallbackGasLimit(4_000_000);
        _setReferralCode(bytes32(0));
        _setMaxClaimableFundingShare(0.01 ether); // 1%
        _setRealizedPnlDiffFactor(0.1 ether); // 10%
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    function _updateAddresses(address exchangeRouter_, address reader_) internal {
        GmxConfigStorage storage $ = _getGmxConfigStorage();
        $.exchangeRouter = exchangeRouter_;
        $.dataStore = IExchangeRouter(exchangeRouter_).dataStore();
        address orderHandler_ = IExchangeRouter(exchangeRouter_).orderHandler();
        $.orderHandler = orderHandler_;
        $.orderVault = IOrderHandler(orderHandler_).orderVault();
        $.referralStorage = IOrderHandler(orderHandler_).referralStorage();
        $.reader = reader_;
    }

    function _setCallbackGasLimit(uint256 callbackGasLimit_) internal {
        if (callbackGasLimit() != callbackGasLimit_) {
            _getGmxConfigStorage().callbackGasLimit = callbackGasLimit_;
            emit CallbackGasLimitUpdated(_msgSender(), callbackGasLimit_);
        }
    }

    function _setReferralCode(bytes32 referralCode_) internal {
        if (referralCode() != referralCode_) {
            _getGmxConfigStorage().referralCode = referralCode_;
            emit ReferralCodeUpdated(_msgSender(), referralCode_);
        }
    }

    function _setMaxClaimableFundingShare(uint256 _maxClaimableFundingShare) internal {
        require(_maxClaimableFundingShare < 1 ether);
        if (maxClaimableFundingShare() != _maxClaimableFundingShare) {
            _getGmxConfigStorage().maxClaimableFundingShare = _maxClaimableFundingShare;
            emit MaxClaimableFundingShareUpdated(_msgSender(), _maxClaimableFundingShare);
        }
    }

    function _setLimitDecreaseCollateral(uint256 _limit) internal {
        if (limitDecreaseCollateral() != _limit) {
            _getGmxConfigStorage().limitDecreaseCollateral = _limit;
            emit LimitDecreaseCollateralUpdated(_msgSender(), _limit);
        }
    }

    function _setRealizedPnlDiffFactor(uint256 _diffFactor) internal {
        require(_diffFactor < 1 ether);
        if (realizedPnlDiffFactor() != _diffFactor) {
            _getGmxConfigStorage().realizedPnlDiffFactor = _diffFactor;
            emit RealizedPnlDiffFactorUpdated(_msgSender(), _diffFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function updateAddresses(address exchangeRouter_, address reader_) external onlyOwner {
        _updateAddresses(exchangeRouter_, reader_);
    }

    function setCallbackGasLimit(uint256 callbackGasLimit_) external onlyOwner {
        _setCallbackGasLimit(callbackGasLimit_);
    }

    function setReferralCode(bytes32 referralCode_) external onlyOwner {
        _setReferralCode(referralCode_);
    }

    function setMaxClaimableFundingShare(uint256 _maxClaimableFundingShare) external onlyOwner {
        _setMaxClaimableFundingShare(_maxClaimableFundingShare);
    }

    function setLimitDecreaseCollateral(uint256 _limit) external onlyOwner {
        _setLimitDecreaseCollateral(_limit);
    }

    function setRealizedPnlDiffFactor(uint256 _diffFactor) external onlyOwner {
        _setRealizedPnlDiffFactor(_diffFactor);
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function dataStore() public view returns (address) {
        return _getGmxConfigStorage().dataStore;
    }

    function exchangeRouter() public view returns (address) {
        return _getGmxConfigStorage().exchangeRouter;
    }

    function orderHandler() public view returns (address) {
        return _getGmxConfigStorage().orderHandler;
    }

    function orderVault() public view returns (address) {
        return _getGmxConfigStorage().orderVault;
    }

    function referralStorage() public view returns (address) {
        return _getGmxConfigStorage().referralStorage;
    }

    function reader() public view returns (address) {
        return _getGmxConfigStorage().reader;
    }

    function callbackGasLimit() public view returns (uint256) {
        return _getGmxConfigStorage().callbackGasLimit;
    }

    function referralCode() public view returns (bytes32) {
        return _getGmxConfigStorage().referralCode;
    }

    function maxClaimableFundingShare() public view returns (uint256) {
        return _getGmxConfigStorage().maxClaimableFundingShare;
    }

    function limitDecreaseCollateral() public view returns (uint256) {
        return _getGmxConfigStorage().limitDecreaseCollateral;
    }

    function realizedPnlDiffFactor() public view returns (uint256) {
        return _getGmxConfigStorage().realizedPnlDiffFactor;
    }
}
