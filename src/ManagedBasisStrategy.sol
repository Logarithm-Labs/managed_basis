// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LogBaseVaultUpgradeable} from "src/common/LogBaseVaultUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BasisStrategyLogic} from "src/libraries/logic/BasisStrategyLogic.sol";
import {ManualSwapLogic} from "src/libraries/logic/ManualSwapLogic.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

import {IOracle} from "src/interfaces/IOracle.sol";
import {IManagedBasisStrategy} from "src/interfaces/IManagedBasisStrategy.sol";

contract ManagedBasisStrategy is UUPSUpgradeable, LogBaseVaultUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.ManagedBasisStrategyStorageV1
    struct ManagedBasisStrategyStorage {
        // address state
        address oracle;
        address operator;
        address forwarder;
        address positionManager;
        // leverage state
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
        // cost state
        uint256 entryCost;
        uint256 exitCost;
        // strategy configuration
        uint256 hedgeDeviationThreshold;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        // asset state
        uint256 assetsToClaim; // asset balance that is ready to claim
        uint256 assetsToWithdraw; // asset balance that is processed for withdrawals
        // pending state
        uint256 pendingUtilizedProducts;
        uint256 pendingDeutilizedAssets;
        uint256 pendingDecreaseCollateral;
        // status state
        DataTypes.StrategyStatus strategyStatus;
        // withdraw state
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        mapping(address => uint128) requestCounter;
        mapping(bytes32 => DataTypes.WithdrawRequestState) withdrawRequests;
        // manual swap state
        mapping(address => bool) isSwapPool;
        address[] productToAssetSwapPath;
        address[] assetToProductSwapPath;
        // adjust position
        DataTypes.PositionManagerPayload requestParams;
        bool processingRebalance;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.ManagedBasisStrategyStorageV1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ManagedBasisStrategyStorageLocation =
        0x76bd71a320090dc5d8c5864143521b706fefaa2f93d6b1826cde0a967ebe6100;

    function _getManagedBasisStrategyStorage() private pure returns (ManagedBasisStrategyStorage storage $) {
        assembly {
            $.slot := ManagedBasisStrategyStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        string memory name,
        string memory symbol,
        address _asset,
        address _product,
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage,
        uint256 _entryCost,
        uint256 _exitCost,
        address[] calldata _assetToProductSwapPath
    ) external initializer {
        __LogBaseVault_init(IERC20(_asset), IERC20(_product), name, symbol);
        __Ownable_init(msg.sender);

        // validation oracle
        if (IOracle(_oracle).getAssetPrice(_asset) == 0 || IOracle(_oracle).getAssetPrice(_product) == 0) revert();

        __ManagedBasisStrategy_init(
            _oracle,
            _operator,
            _targetLeverage,
            _minLeverage,
            _maxLeverage,
            _safeMarginLeverage,
            _entryCost,
            _exitCost,
            _assetToProductSwapPath
        );
    }

    function __ManagedBasisStrategy_init(
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage,
        uint256 _entryCost,
        uint256 _exitCost,
        address[] calldata _assetToProductSwapPath
    ) public initializer {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.oracle = _oracle;
        $.operator = _operator;
        $.entryCost = _entryCost;
        $.exitCost = _exitCost;

        if (_targetLeverage == 0) revert();
        $.targetLeverage = _targetLeverage;
        if (_minLeverage >= _targetLeverage) revert();
        $.minLeverage = _minLeverage;
        if (_maxLeverage <= _targetLeverage) revert();
        $.maxLeverage = _maxLeverage;
        if (_safeMarginLeverage <= _maxLeverage) revert();
        $.safeMarginLeverage = _safeMarginLeverage;

        $.userDepositLimit = type(uint256).max;
        $.strategyDepostLimit = type(uint256).max;
        $.hedgeDeviationThreshold = 1e16; // 1%
        _setManualSwapPath(_assetToProductSwapPath);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawRequest(
        address indexed caller, address indexed receiver, address indexed owner, bytes32 withdrawId, uint256 amount
    );

    event Claim(address indexed claimer, bytes32 requestId, uint256 amount);

    event UpdatePendingUtilization();

    event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    event Deutilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    event SwapFailed();

    event UpdateStrategyStatus(DataTypes.StrategyStatus status);

    event AfterAdjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOperator() {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (msg.sender != $.operator) {
            revert Errors.CallerNotOperator();
        }
        _;
    }

    modifier onlyPositionManager() {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (msg.sender != $.positionManager) {
            revert Errors.CallerNotPositionManager();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION   
    //////////////////////////////////////////////////////////////*/

    function setPositionManager(address _positionManager) external onlyOwner {
        if (_positionManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getManagedBasisStrategyStorage().positionManager = _positionManager;
    }

    function setForwarder(address _forwarder) external onlyOwner {
        if (_forwarder == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getManagedBasisStrategyStorage().forwarder = _forwarder;
    }

    function setEntryExitCosts(uint256 _entryCost, uint256 _exitCost) external onlyOperator {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.entryCost = _entryCost;
        $.exitCost = _exitCost;
    }

    function setDepositLimits(uint256 userLimit, uint256 strategyLimit) external onlyOwner {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.userDepositLimit = userLimit;
        $.strategyDepostLimit = strategyLimit;
    }

    /*//////////////////////////////////////////////////////////////
                        STATE TRANSITIONS   
    //////////////////////////////////////////////////////////////*/

    function _getStrategyAddresses(ManagedBasisStrategyStorage storage $)
        internal
        view
        virtual
        returns (DataTypes.StrategyAddresses memory)
    {
        return DataTypes.StrategyAddresses({
            asset: asset(),
            product: product(),
            oracle: $.oracle,
            operator: $.operator,
            positionManager: $.positionManager
        });
    }

    function _getStrategyLeverages(ManagedBasisStrategyStorage storage $)
        internal
        view
        virtual
        returns (DataTypes.StrategyLeverages memory)
    {
        return DataTypes.StrategyLeverages({
            currentLeverage: IPositionManager($.positionManager).currentLeverage(),
            targetLeverage: $.targetLeverage,
            minLeverage: $.minLeverage,
            maxLeverage: $.maxLeverage,
            safeMarginLeverage: $.safeMarginLeverage
        });
    }

    function _getStrategyStateCache(ManagedBasisStrategyStorage storage $)
        internal
        view
        virtual
        returns (DataTypes.StrategyStateChache memory)
    {
        return DataTypes.StrategyStateChache({
            assetsToClaim: $.assetsToClaim,
            assetsToWithdraw: $.assetsToWithdraw,
            accRequestedWithdrawAssets: $.accRequestedWithdrawAssets,
            proccessedWithdrawAssets: $.proccessedWithdrawAssets,
            pendingDecreaseCollateral: $.pendingDecreaseCollateral,
            pendingDeutilizedAssets: $.pendingDeutilizedAssets
        });
        // strategyStatus: $.strategyStatus
    }

    function _updateStrategyState(
        ManagedBasisStrategyStorage storage $,
        DataTypes.StrategyStateChache memory cache0,
        DataTypes.StrategyStateChache memory cache1
    ) internal virtual {
        if (cache0.assetsToClaim != cache1.assetsToClaim) {
            $.assetsToClaim = cache1.assetsToClaim;
        }
        if (cache0.assetsToWithdraw != cache1.assetsToWithdraw) {
            $.assetsToWithdraw = cache1.assetsToWithdraw;
        }
        if (cache0.accRequestedWithdrawAssets != cache1.accRequestedWithdrawAssets) {
            $.accRequestedWithdrawAssets = cache1.accRequestedWithdrawAssets;
        }
        if (cache0.proccessedWithdrawAssets != cache1.proccessedWithdrawAssets) {
            $.proccessedWithdrawAssets = cache1.proccessedWithdrawAssets;
        }
        if (cache0.pendingDecreaseCollateral != cache1.pendingDecreaseCollateral) {
            $.pendingDecreaseCollateral = cache1.pendingDecreaseCollateral;
        }
        if (cache0.pendingDeutilizedAssets != cache1.pendingDeutilizedAssets) {
            $.pendingDeutilizedAssets = cache1.pendingDeutilizedAssets;
        }
        // if (cache0.strategyStatus != cache1.strategyStatus) {
        //     $.strategyStatus = cache1.strategyStatus;
        // }

        emit UpdatePendingUtilization();
    }

    function _updateWithdrawRequestState(
        ManagedBasisStrategyStorage storage $,
        bytes32 withdrawId,
        DataTypes.WithdrawRequestState memory withdrawState
    ) internal virtual {
        $.withdrawRequests[withdrawId] = withdrawState;
    }

    // TODO: add checks for min execution amounts
    function _executeAdjustPosition(
        ManagedBasisStrategyStorage storage $,
        DataTypes.PositionManagerPayload memory params
    ) internal virtual {
        if (params.isIncrease && params.collateralDeltaAmount > 0) {
            IERC20(asset()).safeTransfer($.positionManager, params.collateralDeltaAmount);
        }
        if (params.collateralDeltaAmount > 0 || params.sizeDeltaInTokens > 0) {
            $.requestParams = params;
            IPositionManager($.positionManager).adjustPosition(params);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / WITHDRAW LOGIC   
    //////////////////////////////////////////////////////////////*/

    /// @dev Deposit/mint common workflow.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache0 = _getStrategyStateCache($);

        DataTypes.StrategyStateChache memory cache1 = BasisStrategyLogic.executeDeposit(
            BasisStrategyLogic.DepositParams({asset: asset(), assets: assets, cache: cache0})
        );

        _updateStrategyState($, cache0, cache1);

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Withdraw/redeem common workflow.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);

        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        DataTypes.StrategyStateChache memory cache0 = _getStrategyStateCache($);
        address asset_ = asset();

        (
            bytes32 withdrawId,
            DataTypes.StrategyStateChache memory cache1,
            DataTypes.WithdrawRequestState memory withdrawState
        ) = BasisStrategyLogic.executeWithdraw(
            BasisStrategyLogic.WithdrawParams({
                asset: asset_,
                receiver: receiver,
                owner: owner,
                requestCounter: $.requestCounter[owner],
                assets: assets,
                cache: cache0
            })
        );

        if (withdrawId == bytes32(0)) {
            // empty withdrawId means withdraw was executed immediately against idle assets
            // no need to create a withdraw request, withdrawing assets should be transferred to receiver
            IERC20(asset_).safeTransfer(receiver, assets);
        } else {
            _updateWithdrawRequestState($, withdrawId, withdrawState);
            $.requestCounter[owner]++;

            emit WithdrawRequest(caller, receiver, owner, withdrawId, withdrawState.requestedAmount);
        }

        _updateStrategyState($, cache0, cache1);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 withdrawId) external virtual returns (uint256 executedAmount) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.WithdrawRequestState memory withdrawState = $.withdrawRequests[withdrawId];
        DataTypes.StrategyStateChache memory cache0 = _getStrategyStateCache($);

        DataTypes.StrategyStateChache memory cache1;

        (cache1, withdrawState, executedAmount) = BasisStrategyLogic.executeClaim(
            BasisStrategyLogic.ClaimParams({
                status: $.strategyStatus,
                totalSupply: totalSupply(),
                leverages: _getStrategyLeverages($),
                withdrawState: withdrawState,
                addr: _getStrategyAddresses($),
                cache: cache0
            })
        );

        _updateStrategyState($, cache0, cache1);
        _updateWithdrawRequestState($, withdrawId, withdrawState);

        IERC20(asset()).safeTransfer(msg.sender, executedAmount);

        emit Claim(msg.sender, withdrawId, executedAmount);
    }

    function isClaimable(bytes32 withdrawId) external view returns (bool) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.WithdrawRequestState memory withdrawRequest = $.withdrawRequests[withdrawId];
        (bool isExecuted,) = BasisStrategyLogic.isWithdrawRequestExecuted(
            $.strategyStatus,
            withdrawRequest,
            _getStrategyAddresses($),
            _getStrategyStateCache($),
            _getStrategyLeverages($),
            totalSupply()
        );
        return isExecuted && !withdrawRequest.isClaimed;
    }

    function getWithdrawId(address owner, uint128 counter) public view virtual returns (bytes32) {
        return BasisStrategyLogic.getWithdrawId(owner, counter);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual override returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyAddresses memory addr = _getStrategyAddresses($);
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        (,, assets) = BasisStrategyLogic.getTotalAssets(addr, cache);
    }

    function utilizedAssets() external view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyAddresses memory addr = _getStrategyAddresses($);
        return BasisStrategyLogic.getUtilizedAssets(addr);
    }

    function idleAssets() external view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        return BasisStrategyLogic.getIdleAssets(asset(), cache);
    }

    function totalPendingWithdraw() external view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return BasisStrategyLogic.getTotalPendingWithdraw(_getStrategyStateCache($));
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256 shares) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return BasisStrategyLogic.getPreviewDeposit(
            BasisStrategyLogic.PreviewParams({
                assetsOrShares: assets,
                fee: $.entryCost,
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                cache: _getStrategyStateCache($)
            })
        );
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return BasisStrategyLogic.getPreviewMint(
            BasisStrategyLogic.PreviewParams({
                assetsOrShares: shares,
                fee: $.entryCost,
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                cache: _getStrategyStateCache($)
            })
        );
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256 shares) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return BasisStrategyLogic.getPreviewWithdraw(
            BasisStrategyLogic.PreviewParams({
                assetsOrShares: assets,
                fee: $.exitCost,
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                cache: _getStrategyStateCache($)
            })
        );
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return BasisStrategyLogic.getPreviewRedeem(
            BasisStrategyLogic.PreviewParams({
                assetsOrShares: shares,
                fee: $.exitCost,
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                cache: _getStrategyStateCache($)
            })
        );
    }

    function pendingIncreaseCollateral() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        return BasisStrategyLogic.getPendingIncreaseCollateral(asset(), $.targetLeverage, cache);
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep(bytes memory) public view virtual returns (bool upkeepNeeded, bytes memory performData) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        (upkeepNeeded, performData) = BasisStrategyLogic.getCheckUpkeep(
            BasisStrategyLogic.CheckUpkeepParams({
                hedgeDeviationThreshold: $.hedgeDeviationThreshold,
                pendingDecreaseCollateral: $.pendingDecreaseCollateral,
                processingRebalance: $.processingRebalance,
                cache: _getStrategyStateCache($),
                addr: _getStrategyAddresses($),
                leverages: _getStrategyLeverages($),
                strategyStatus: $.strategyStatus
            })
        );
    }

    function performUpkeep(bytes calldata performData) external {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        if (msg.sender != $.forwarder) {
            revert Errors.UnauthorizedForwarder(msg.sender);
        }

        if ($.strategyStatus != DataTypes.StrategyStatus.IDLE) {
            return;
        }

        _performUpkeep($, performData);
    }

    function _performUpkeep(ManagedBasisStrategyStorage storage $, bytes memory performData) internal {
        DataTypes.StrategyStateChache memory cache0 = _getStrategyStateCache($);

        (
            DataTypes.StrategyStateChache memory cache1,
            DataTypes.PositionManagerPayload memory requestParams,
            DataTypes.StrategyStatus status,
            bool processingRebalance
        ) = BasisStrategyLogic.executePerformUpkeep(
            BasisStrategyLogic.PerformUpkeepParams({
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                leverages: _getStrategyLeverages($),
                cache: cache0,
                productToAssetSwapPath: $.productToAssetSwapPath,
                performData: performData
            })
        );

        _updateStrategyState($, cache0, cache1);

        $.strategyStatus = status;

        if (processingRebalance) {
            // processingRebalance shouldn't be set as false during performing upkeep
            // can be set as false within the callback function
            $.processingRebalance = processingRebalance;
        }

        _executeAdjustPosition($, requestParams);

        emit UpdateStrategyStatus(status);
        emit UpdatePendingUtilization();
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function pendingUtilizations()
        external
        view
        returns (uint256 pendingUtilizationInAsset, uint256 pendingDeutilizationInProduct)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        DataTypes.StrategyAddresses memory addr = _getStrategyAddresses($);
        DataTypes.StrategyLeverages memory leverages = _getStrategyLeverages($);

        (bool upkeepNeeded,) = BasisStrategyLogic.getCheckUpkeep(
            BasisStrategyLogic.CheckUpkeepParams({
                hedgeDeviationThreshold: $.hedgeDeviationThreshold,
                pendingDecreaseCollateral: $.pendingDecreaseCollateral,
                processingRebalance: $.processingRebalance,
                cache: cache,
                addr: addr,
                leverages: leverages,
                strategyStatus: $.strategyStatus
            })
        );

        if (upkeepNeeded) {
            return (pendingUtilizationInAsset, pendingDeutilizationInProduct);
        }

        pendingUtilizationInAsset =
            BasisStrategyLogic.getPendingUtilization(addr.asset, leverages.targetLeverage, cache);
        pendingDeutilizationInProduct =
            BasisStrategyLogic.getPendingDeutilization(addr, cache, leverages, totalSupply(), $.processingRebalance);
        return (pendingUtilizationInAsset, pendingDeutilizationInProduct);
    }

    function utilize(uint256 amount, DataTypes.SwapType swapType, bytes calldata swapData)
        external
        virtual
        onlyOperator
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        (bool upkeepNeeded, bytes memory performData) = checkUpkeep("");
        if (upkeepNeeded) {
            _performUpkeep($, performData);
            return;
        }

        DataTypes.StrategyStateChache memory cache0 = _getStrategyStateCache($);

        (bool success, DataTypes.StrategyStatus status, DataTypes.PositionManagerPayload memory requestParams) =
        BasisStrategyLogic.executeUtilize(
            BasisStrategyLogic.UtilizeParams({
                amount: amount,
                targetLeverage: $.targetLeverage,
                status: $.strategyStatus,
                swapType: swapType,
                addr: _getStrategyAddresses($),
                cache: cache0,
                assetToProductSwapPath: $.assetToProductSwapPath,
                swapData: swapData
            })
        );
        if (success) {
            $.strategyStatus = status;
            _executeAdjustPosition($, requestParams);
            emit Utilize(msg.sender, amount, requestParams.sizeDeltaInTokens);
        } else {
            emit SwapFailed();
        }
    }

    function deutilize(uint256 amount, DataTypes.SwapType swapType, bytes calldata swapData)
        external
        virtual
        onlyOperator
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        (bool upkeepNeeded, bytes memory performData) = checkUpkeep("");
        if (upkeepNeeded) {
            _performUpkeep($, performData);
            return;
        }

        DataTypes.StrategyStateChache memory cache0 = _getStrategyStateCache($);
        (
            bool success,
            uint256 amountOut,
            DataTypes.StrategyStatus status,
            DataTypes.StrategyStateChache memory cache1,
            DataTypes.PositionManagerPayload memory requestParams
        ) = BasisStrategyLogic.executeDeutilize(
            BasisStrategyLogic.DeutilizeParams({
                amount: amount,
                totalSupply: totalSupply(),
                status: $.strategyStatus,
                swapType: swapType,
                addr: _getStrategyAddresses($),
                leverages: _getStrategyLeverages($),
                cache: cache0,
                productToAssetSwapPath: $.productToAssetSwapPath,
                swapData: swapData,
                processingRebalance: $.processingRebalance
            })
        );
        if (success) {
            $.strategyStatus = status;
            _updateStrategyState($, cache0, cache1);
            _executeAdjustPosition($, requestParams);
            emit Deutilize(msg.sender, amount, requestParams.sizeDeltaInTokens);
        } else {
            emit SwapFailed();
        }
    }

    function unpause() external onlyOperator {
        require(_getManagedBasisStrategyStorage().strategyStatus == DataTypes.StrategyStatus.PAUSE);
        _getManagedBasisStrategyStorage().strategyStatus = DataTypes.StrategyStatus.IDLE;
    }

    /*//////////////////////////////////////////////////////////////
                            MANUAL SWAP
    //////////////////////////////////////////////////////////////*/

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        if (data.length != 96) {
            revert Errors.InvalidCallback();
        }
        _verifyCallback();
        (address tokenIn,, address payer) = abi.decode(data, (address, address, address));
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        if (payer == address(this)) {
            IERC20(tokenIn).safeTransfer(msg.sender, amountToPay);
        } else {
            IERC20(tokenIn).safeTransferFrom(payer, msg.sender, amountToPay);
        }
    }

    function _verifyCallback() internal view {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (!$.isSwapPool[msg.sender]) {
            revert Errors.InvalidCallback();
        }
    }

    function _setManualSwapPath(address[] calldata _assetToProductSwapPath) private {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 length = _assetToProductSwapPath.length;
        if (
            length % 2 == 0 || _assetToProductSwapPath[0] != asset() || _assetToProductSwapPath[length - 1] != product()
        ) {
            // length should be odd
            // the first element should be asset
            // the last element should be product
            revert Errors.InvalidPath();
        }

        address[] memory _productToAssetSwapPath = new address[](length);
        for (uint256 i; i < length; i++) {
            _productToAssetSwapPath[i] = _assetToProductSwapPath[length - i - 1];
            if (i % 2 != 0) {
                // odd index element of path should be swap pool address
                address pool = _assetToProductSwapPath[i];
                address tokenIn = _assetToProductSwapPath[i - 1];
                address tokenOut = _assetToProductSwapPath[i + 1];
                address token0 = IUniswapV3Pool(pool).token0();
                address token1 = IUniswapV3Pool(pool).token1();
                if ((tokenIn != token0 || tokenOut != token1) && (tokenOut != token0 || tokenIn != token1)) {
                    revert Errors.InvalidPath();
                }
                $.isSwapPool[pool] = true;
            }
        }
        $.assetToProductSwapPath = _assetToProductSwapPath;
        $.productToAssetSwapPath = _productToAssetSwapPath;
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION MANAGER CALLBACK LOGIC
    //////////////////////////////////////////////////////////////*/

    // callback function dispatcher
    function afterAdjustPosition(DataTypes.PositionManagerPayload memory params) external onlyPositionManager {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        if ($.strategyStatus == DataTypes.StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }

        uint256 currentLeverage = IPositionManager($.positionManager).currentLeverage();

        if (params.isIncrease) {
            (DataTypes.StrategyStatus status, bool processingRebalance) = BasisStrategyLogic
                .executeAfterIncreasePosition(
                BasisStrategyLogic.AfterAdjustPositionParams({
                    positionManager: $.positionManager,
                    requestParams: $.requestParams,
                    responseParams: params,
                    revertSwapPath: $.productToAssetSwapPath
                }),
                $.processingRebalance,
                currentLeverage,
                $.targetLeverage
            );
            $.strategyStatus = status;
            $.processingRebalance = processingRebalance;
            emit UpdatePendingUtilization();
        } else {
            DataTypes.StrategyStateChache memory cache0 = _getStrategyStateCache($);

            (DataTypes.StrategyStateChache memory cache1, DataTypes.StrategyStatus status, bool processingRebalance) =
            BasisStrategyLogic.executeAfterDecreasePosition(
                BasisStrategyLogic.AfterAdjustPositionParams({
                    positionManager: $.positionManager,
                    requestParams: $.requestParams,
                    responseParams: params,
                    revertSwapPath: $.assetToProductSwapPath
                }),
                cache0,
                $.processingRebalance,
                currentLeverage,
                $.targetLeverage
            );
            $.strategyStatus = status;
            $.processingRebalance = processingRebalance;
            _updateStrategyState($, cache0, cache1);
        }

        emit UpdateStrategyStatus(DataTypes.StrategyStatus.IDLE);

        emit AfterAdjustPosition(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL GETTERS
    //////////////////////////////////////////////////////////////*/

    function positionManager() external view returns (address) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.positionManager;
    }

    function oracle() external view returns (address) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.oracle;
    }

    function strategyStatus() external view returns (DataTypes.StrategyStatus) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.strategyStatus;
    }

    function requestCounter(address owner) external view returns (uint128) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.requestCounter[owner];
    }

    function withdrawRequests(bytes32 requestKey) external view returns (DataTypes.WithdrawRequestState memory) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.withdrawRequests[requestKey];
    }

    function accRequestedWithdrawAssets() external view returns (uint256) {
        return _getManagedBasisStrategyStorage().accRequestedWithdrawAssets;
    }

    function proccessedWithdrawAssets() external view returns (uint256) {
        return _getManagedBasisStrategyStorage().proccessedWithdrawAssets;
    }

    function assetsToClaim() external view returns (uint256) {
        return _getManagedBasisStrategyStorage().assetsToClaim;
    }

    function assetsToWithdraw() external view returns (uint256) {
        return _getManagedBasisStrategyStorage().assetsToWithdraw;
    }

    function pendingDecreaseCollateral() external view returns (uint256) {
        return _getManagedBasisStrategyStorage().pendingDecreaseCollateral;
    }
}
