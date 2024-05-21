// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";

import {IBasisGmxFactory} from "src/interfaces/IBasisGmxFactory.sol";
import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";
import {IGmxV2PositionManager} from "src/interfaces/IGmxV2PositionManager.sol";

import {Errors} from "src/libraries/Errors.sol";

contract BasisGmxFactory is IBasisGmxFactory, Ownable2StepUpgradeable, UUPSUpgradeable {
    string constant API_VERSION = "0.0.1";

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.BasisGmxFactory
    struct BasisGmxFactoryStorage {
        // gmx config
        address _exchangeRouter;
        address _dataStore;
        address _orderHandler;
        address _orderVault;
        address _referralStorage;
        address _reader;
        // strategy config
        uint256 _callbackGasLimit;
        bytes32 _referralCode;
        // main storage
        address _strategyImplementation;
        address _positionManagerImplementation;
        address[] _strategies;
        mapping(address strategy => bool) _activeStrategy;
        mapping(address asset => mapping(address product => address)) _marketKeys;
        mapping(address operator => bool) _isOperator;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.BasisGmxFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BasisGmxFactoryStorageLocation =
        0xe2050cc63af88fdc6b67454ffa45c367fd249ca0e96699fe48dd44ba71f1a600;

    function _getBasisGmxFactoryStorage() private pure returns (BasisGmxFactoryStorage storage $) {
        assembly {
            $.slot := BasisGmxFactoryStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategyCreated(
        address indexed strategy, address indexed positionManager, string indexed symbol, string name
    );

    /*//////////////////////////////////////////////////////////////
                            INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address owner_,
        address exchangeRouter_,
        address reader_,
        uint256 callbackGasLimit_,
        bytes32 referralCode_
    ) external initializer {
        __Ownable_init(owner_);
        if (exchangeRouter_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();

        // initialize gmx config
        address orderHandler_ = IExchangeRouter(exchangeRouter_).orderHandler();
        $._exchangeRouter = exchangeRouter_;
        $._dataStore = IExchangeRouter(exchangeRouter_).dataStore();
        $._orderHandler = IExchangeRouter(exchangeRouter_).orderHandler();
        $._orderVault = IOrderHandler(orderHandler_).orderVault();
        $._referralStorage = IOrderHandler(orderHandler_).referralStorage();
        $._reader = reader_;

        // initialze strategy config
        $._callbackGasLimit = callbackGasLimit_;
        $._referralCode = referralCode_;
    }

    function _authorizeUpgrade(address) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL SETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev disable renouncing of ownership for security
    function renounceOwnership() public pure override {
        revert();
    }

    function setGmxReferralCode(bytes32 referralCode_) external onlyOwner {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        $._referralCode = referralCode_;
    }

    function setGmxCallbackGasLimit(uint256 callbackGasLimit_) external onlyOwner {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        $._callbackGasLimit = callbackGasLimit_;
    }

    function addOperators(address[] calldata operators) external virtual onlyOwner {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        uint256 len = operators.length;
        for (uint256 i; i < len;) {
            $._isOperator[operators[i]] = true;
            unchecked {
                ++i;
            }
        }
    }

    function removeOperators(address[] calldata operators) external virtual onlyOwner {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        uint256 len = operators.length;
        for (uint256 i; i < len;) {
            $._isOperator[operators[i]] = false;
            unchecked {
                ++i;
            }
        }
    }

    function setMarketKeys(address[] calldata assets, address[] calldata products, address[] calldata markets)
        external
        virtual
        onlyOwner
    {
        uint256 len = assets.length;
        if (len != products.length || len != markets.length) {
            revert Errors.ArrayLengthMissmatch();
        }
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        for (uint256 i; i < len;) {
            if (assets[i] == address(0) || products[i] == address(0) || markets[i] == address(0)) {
                revert Errors.ZeroAddress();
            }
            $._marketKeys[assets[i]][products[i]] = markets[i];
            unchecked {
                ++i;
            }
        }
    }

    function upgradeStrategyImplementations(address implementation, bytes memory data) external virtual onlyOwner {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        address[] memory _strategies = $._strategies;
        uint256 len = _strategies.length;
        for (uint256 i; i < len;) {
            UUPSUpgradeable strategy = UUPSUpgradeable(_strategies[i]);
            strategy.upgradeToAndCall(implementation, data);
            unchecked {
                ++i;
            }
        }
        $._strategyImplementation = implementation;
    }

    function upgradePositionManagerImplementations(address implementation, bytes memory data)
        external
        virtual
        onlyOwner
    {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        address[] memory _strategies = $._strategies;
        uint256 len = _strategies.length;
        for (uint256 i; i < len;) {
            address positionManagerAddr = IBasisStrategy(_strategies[i]).positionManager();
            UUPSUpgradeable(positionManagerAddr).upgradeToAndCall(implementation, data);
            unchecked {
                ++i;
            }
        }
        $._positionManagerImplementation = implementation;
    }

    function createStrategy(address asset, address product)
        // uint256 targetLeverage,
        // uint256 minLeverage,
        // uint256 maxLeverage
        external
        virtual
        onlyOwner
        returns (address payable strategy, address positionManager)
    {
        string memory assetSymbol = IERC20Metadata(asset).symbol();
        string memory productSymbol = IERC20Metadata(product).symbol();
        string memory name = _getStrategyName(assetSymbol, productSymbol);
        string memory symbol = _getStrategySymbol(assetSymbol, productSymbol);
        bytes memory initializerData = abi.encodeCall(IBasisStrategy.initialize, (asset, product, name, symbol));

        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        strategy = payable(address(new ERC1967Proxy($._strategyImplementation, initializerData)));

        // deploy position manager proxy of this strategy
        bytes memory posMngerInitializerData = abi.encodeCall(IGmxV2PositionManager.initialize, strategy);

        positionManager = address(new ERC1967Proxy($._positionManagerImplementation, posMngerInitializerData));
        IBasisStrategy(strategy).setPositionManager(positionManager);

        IBasisStrategy(strategy).activateStrategy();
        $._strategies.push(strategy);
        $._activeStrategy[strategy] = true;

        emit StrategyCreated(strategy, positionManager, symbol, name);
    }

    function activateStrategy(address strategy) external virtual onlyOwner {
        if (IBasisStrategy(strategy).isActive()) {
            revert();
        }
        IBasisStrategy(strategy).activateStrategy();
    }

    function deactivateStrategy(address strategy) external payable virtual onlyOwner returns (bytes32 key) {
        if (!IBasisStrategy(strategy).isActive()) {
            revert();
        }
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        key = IBasisStrategy(strategy).deactivateStrategy{value: msg.value}();
        $._activeStrategy[strategy] = false;
    }

    function topUpStrategies(address[] calldata _strategies, uint256[] calldata _amounts) external payable {
        uint256 len = _strategies.length;
        if (_amounts.length != len) {
            revert();
        }

        uint256 totalValueSent;
        bool success;
        for (uint256 i; i < len;) {
            if (isActiveStrategy(_strategies[i])) {
                (success,) = _strategies[i].call{value: _amounts[i]}("");
                require(success);
                totalValueSent += _amounts[i];
            }
        }

        (success,) = msg.sender.call{value: msg.value - totalValueSent}("");
        require(success);
    }

    /*//////////////////////////////////////////////////////////////
                          PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBasisGmxFactory
    function apiVersion() public pure override returns (string memory) {
        return API_VERSION;
    }

    /// @inheritdoc IBasisGmxFactory
    function marketKey(address asset, address product) public view returns (address) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._marketKeys[asset][product];
    }

    /// @inheritdoc IBasisGmxFactory
    function dataStore() public view override returns (address) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._dataStore;
    }

    /// @inheritdoc IBasisGmxFactory
    function reader() public view override returns (address) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._reader;
    }

    /// @inheritdoc IBasisGmxFactory
    function orderVault() public view override returns (address) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._orderVault;
    }

    /// @inheritdoc IBasisGmxFactory
    function exchangeRouter() public view override returns (address) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._exchangeRouter;
    }

    /// @inheritdoc IBasisGmxFactory
    function callbackGasLimit() public view override returns (uint256) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._callbackGasLimit;
    }

    /// @inheritdoc IBasisGmxFactory
    function referralCode() public view override returns (bytes32) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._referralCode;
    }

    /// @inheritdoc IBasisGmxFactory
    function orderHandler() public view override returns (address) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._orderHandler;
    }

    /// @inheritdoc IBasisGmxFactory
    function referralStorage() public view override returns (address) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._referralStorage;
    }

    function isOperator(address account) public view override returns (bool) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._isOperator[account];
    }

    function strategies() public view returns (address[] memory) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._strategies;
    }

    function isActiveStrategy(address strategy) public view returns (bool) {
        BasisGmxFactoryStorage storage $ = _getBasisGmxFactoryStorage();
        return $._activeStrategy[strategy];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getStrategyName(string memory assetSymbol, string memory productSymbol)
        internal
        pure
        virtual
        returns (string memory)
    {
        return string(abi.encodePacked("Logarithm Basis Gmx ", assetSymbol, "-", productSymbol));
    }

    function _getStrategySymbol(string memory assetSymbol, string memory productSymbol)
        internal
        pure
        virtual
        returns (string memory)
    {
        return string(abi.encodePacked("log-b-gmx-", assetSymbol, "-", productSymbol));
    }
}
