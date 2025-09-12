// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILogarithmVault} from "../../vault/ILogarithmVault.sol";
import {ISpotManager} from "../../spot/ISpotManager.sol";
import {IHedgeManager} from "../../hedge/IHedgeManager.sol";
import {IOracle} from "../../oracle/IOracle.sol";
import {IStrategyConfig} from "../../strategy/IStrategyConfig.sol";

/// @dev Used to specify strategy's operations.
enum StrategyStatus {
    // When new operations are available.
    IDLE,
    // When only hedge operation gets initiated.
    KEEPING,
    // When utilizing gets initiated.
    UTILIZING,
    // When deutilizing gets initiated.
    DEUTILIZING,
    // When one of deutilizations (spot & hedge) has been proceeded,
    // or rehedge with spot gets initiated
    AWAITING_FINAL_DEUTILIZATION,
    // When one of utilizations (spot & hedge) has been proceeded.
    AWAITING_FINAL_UTILIZATION
}

library BasisStrategyState {
    /// @custom:storage-location erc7201:logarithm.storage.BasisStrategy
    struct BasisStrategyStorage {
        // addresses
        IERC20 product;
        IERC20 asset;
        ILogarithmVault vault;
        ISpotManager spotManager;
        IHedgeManager hedgeManager;
        IOracle oracle;
        address operator;
        address config;
        // leverage config
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
        // status state
        StrategyStatus strategyStatus;
        // used to change deutilization calc method
        bool processingRebalanceDown;
        // adjust position request to be used to check response
        IHedgeManager.AdjustPositionPayload requestParams;
        // entry/exit fees accrued by the vault that will be spend during utilization/deutilization
        uint256 reservedExecutionCost;
        // entry/exit fees that will be deducted from the reservedExecution cost
        // after completion of utilization/deutilization
        uint256 utilizingExecutionCost;
        // percentage of vault's TVL that caps pending utilization/deutilization
        uint256 maxUtilizePct;
        // cache decrease collateral to save execution cost by executing in a larger size
        uint256 pendingDecreaseCollateral;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.BasisStrategy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BasisStrategyStorageLocation =
        0x3176332e209c21f110843843692adc742ac2f78c16c19930ebc0f9f8747e5200;

    function _getBasisStrategyStorage() private pure returns (BasisStrategyStorage storage $) {
        assembly {
            $.slot := BasisStrategyStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setProduct(address _product) internal {
        _getBasisStrategyStorage().product = IERC20(_product);
    }

    function setAsset(address _asset) internal {
        _getBasisStrategyStorage().asset = IERC20(_asset);
    }

    function setVault(address _vault) internal {
        _getBasisStrategyStorage().vault = ILogarithmVault(_vault);
    }

    function setSpotManager(address _spotManager) internal {
        _getBasisStrategyStorage().spotManager = ISpotManager(_spotManager);
    }

    function setHedgeManager(address _hedgeManager) internal {
        _getBasisStrategyStorage().hedgeManager = IHedgeManager(_hedgeManager);
    }

    function setOracle(address _oracle) internal {
        _getBasisStrategyStorage().oracle = IOracle(_oracle);
    }

    function setOperator(address _operator) internal {
        _getBasisStrategyStorage().operator = _operator;
    }

    function setConfig(address _config) internal {
        _getBasisStrategyStorage().config = _config;
    }

    function setStrategyStatus(StrategyStatus _strategyStatus) internal {
        _getBasisStrategyStorage().strategyStatus = _strategyStatus;
    }

    function setProcessingRebalanceDown(bool _processingRebalanceDown) internal {
        _getBasisStrategyStorage().processingRebalanceDown = _processingRebalanceDown;
    }

    function setRequestParams(IHedgeManager.AdjustPositionPayload memory _requestParams) internal {
        _getBasisStrategyStorage().requestParams = _requestParams;
    }

    function deleteRequestParams() internal {
        delete _getBasisStrategyStorage().requestParams;
    }

    function setReservedExecutionCost(uint256 _reservedExecutionCost) internal {
        _getBasisStrategyStorage().reservedExecutionCost = _reservedExecutionCost;
    }

    function setUtilizingExecutionCost(uint256 _utilizingExecutionCost) internal {
        _getBasisStrategyStorage().utilizingExecutionCost = _utilizingExecutionCost;
    }

    function setMaxUtilizePct(uint256 _maxUtilizePct) internal {
        _getBasisStrategyStorage().maxUtilizePct = _maxUtilizePct;
    }

    function setPendingDecreaseCollateral(uint256 _pendingDecreaseCollateral) internal {
        _getBasisStrategyStorage().pendingDecreaseCollateral = _pendingDecreaseCollateral;
    }

    function setTargetLeverage(uint256 _targetLeverage) internal {
        _getBasisStrategyStorage().targetLeverage = _targetLeverage;
    }

    function setMinLeverage(uint256 _minLeverage) internal {
        _getBasisStrategyStorage().minLeverage = _minLeverage;
    }

    function setMaxLeverage(uint256 _maxLeverage) internal {
        _getBasisStrategyStorage().maxLeverage = _maxLeverage;
    }

    function setSafeMarginLeverage(uint256 _safeMarginLeverage) internal {
        _getBasisStrategyStorage().safeMarginLeverage = _safeMarginLeverage;
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getProduct() internal view returns (IERC20) {
        return _getBasisStrategyStorage().product;
    }

    function getAsset() internal view returns (IERC20) {
        return _getBasisStrategyStorage().asset;
    }

    function getVault() internal view returns (ILogarithmVault) {
        return _getBasisStrategyStorage().vault;
    }

    function getSpotManager() internal view returns (ISpotManager) {
        return _getBasisStrategyStorage().spotManager;
    }

    function getHedgeManager() internal view returns (IHedgeManager) {
        return _getBasisStrategyStorage().hedgeManager;
    }

    function getOracle() internal view returns (IOracle) {
        return _getBasisStrategyStorage().oracle;
    }

    function getOperator() internal view returns (address) {
        return _getBasisStrategyStorage().operator;
    }

    function getConfig() internal view returns (IStrategyConfig) {
        return IStrategyConfig(_getBasisStrategyStorage().config);
    }

    function getStrategyStatus() internal view returns (StrategyStatus) {
        return _getBasisStrategyStorage().strategyStatus;
    }

    function getProcessingRebalanceDown() internal view returns (bool) {
        return _getBasisStrategyStorage().processingRebalanceDown;
    }

    function getRequestParams() internal view returns (IHedgeManager.AdjustPositionPayload memory) {
        return _getBasisStrategyStorage().requestParams;
    }

    function getReservedExecutionCost() internal view returns (uint256) {
        return _getBasisStrategyStorage().reservedExecutionCost;
    }

    function getUtilizingExecutionCost() internal view returns (uint256) {
        return _getBasisStrategyStorage().utilizingExecutionCost;
    }

    function getMaxUtilizePct() internal view returns (uint256) {
        return _getBasisStrategyStorage().maxUtilizePct;
    }

    function getPendingDecreaseCollateral() internal view returns (uint256) {
        return _getBasisStrategyStorage().pendingDecreaseCollateral;
    }

    function getTargetLeverage() internal view returns (uint256) {
        return _getBasisStrategyStorage().targetLeverage;
    }

    function getMinLeverage() internal view returns (uint256) {
        return _getBasisStrategyStorage().minLeverage;
    }

    function getMaxLeverage() internal view returns (uint256) {
        return _getBasisStrategyStorage().maxLeverage;
    }

    function getSafeMarginLeverage() internal view returns (uint256) {
        return _getBasisStrategyStorage().safeMarginLeverage;
    }
}
