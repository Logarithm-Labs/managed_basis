// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";

import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregationRouterV6} from "src/externals/1inch/interfaces/IAggregationRouterV6.sol";

import {InchAggregatorV6Logic} from "src/libraries/InchAggregatorV6Logic.sol";

import {IOracle} from "src/interfaces/IOracle.sol";

import {Errors} from "src/libraries/Errors.sol";
import {FactoryDeployable} from "src/common/FactoryDeployable.sol";
import {LogBaseVaultUpgradeable} from "src/common/LogBaseVaultUpgradeable.sol";

contract ManagedBasisStrategy is
    UUPSUpgradeable,
    FactoryDeployable,
    LogBaseVaultUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    enum SwapType {
        MANUAL,
        INCH_V6
    }

    // TODO: refactor for enum
    enum State {
        UTILIZING,
        DEUTILIZING,
        IDLE
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    struct WithdrawState {
        uint256 requestTimestamp;
        uint256 requestedAmount;
        uint256 executedFromSpot;
        uint256 executedFromIdle;
        uint256 executedFromHedge;
        uint256 executionCost;
        address receiver;
        bool isExecuted;
        bool isClaimed;
    }

    struct PositionState {
        uint256 netBalance;
        uint256 sizeInTokens;
        uint256 markPrice;
        uint256 timestamp;
    }

    struct ManagedBasisStrategyStorage {
        IOracle oracle;
        address positionManager;
        uint256 targetLeverage;
        uint256 currentRound;
        uint256 entryCost;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        // uint256 strategyCapacity;
        uint256 assetsToClaim; // asset balance that is processed for withdraws
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 pendingDecreaseCollateral;
        uint256 totalPendingWithdraw; // total amount of asset that remains to be withdrawn
        uint256 withdrawnFromSpot; // asset amount withdrawn from spot that is not yet processed
        uint256 withdrawnFromIdle; // asset amount withdrawn from idle that is not yet processed
        uint256 idleImbalance; // imbalance in idle assets between spot and hedge due to withdraws from idle
        bytes32[] activeWithdrawRequests;
        bytes32[] closedWithdrawRequests;
        bool rebalancing;
        bool utilizing;
        // TODO:
        bool deutilizing;
        mapping(address => uint128) requestCounter;
        mapping(bytes32 => WithdrawState) withdrawRequests;
    }

    uint256 public constant PRECISION = 1e18;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.ManagedBasisStrategyStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ManagedBasisStrategyStorageLocation =
        0xf5ffd60679e080b7c4e308f2409616890be7bc10ba607661a7e13210852af100;

    function _getManagedBasisStrategyStorage() private pure returns (ManagedBasisStrategyStorage storage $) {
        assembly {
            $.slot := ManagedBasisStrategyStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawRequest(
        address indexed caller, address indexed receiver, address indexed owner, bytes32 requestId, uint256 amount
    );

    event WithdrawReport(address indexed caller, bytes32 requestId, uint256 amountExecuted);

    event StateReport(
        address indexed caller, uint256 roundId, uint256 netBalance, uint256 sizeInTokens, uint256 markPrice
    );

    event Claim(address indexed claimer, bytes32 requestId, uint256 amount);

    event ExecuteRedeem(bytes32 requestId, uint256 requestedAmount, uint256 executedAmount);

    event PendingUtilizationIncrease(uint256 amount);

    event Utilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    event PendingUtilizationDecrease(uint256 amount);

    event Deutilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION / CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address _asset, address _product, address _owner, address _oracle, uint256 _entryCost)
        external
        initializer
    {
        __FactoryDeployable_init();
        __ERC4626_init(IERC20(_asset));
        __LogBaseVault_init(IERC20(_product));
        __AccessControlDefaultAdminRules_init(1 days, _owner);
        __ManagedBasisStrategy_init(_oracle, _entryCost);
    }

    function __ManagedBasisStrategy_init(address _oracle, uint256 _entryCost) public initializer {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.oracle = IOracle(_oracle);
        $.entryCost = _entryCost;
        $.userDepositLimit = type(uint256).max;
        $.strategyDepostLimit = type(uint256).max;
        // $.strategyCapacity = 0;
    }

    function setPositionManager(address _positionManager) external onlyFactory {
        if (_positionManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getManagedBasisStrategyStorage().positionManager = _positionManager;
        IERC20(asset()).approve(_positionManager, type(uint256).max);
    }

    function setEntryCost(uint256 _entryCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.entryCost = _entryCost;
    }

    function setDepositLimits(uint256 userLimit, uint256 strategyLimit) external onlyRole(OPERATOR_ROLE) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.userDepositLimit = userLimit;
        $.strategyDepostLimit = strategyLimit;
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyFactory {}

    function positionManager() public view returns (address) {
        return _getManagedBasisStrategyStorage().positionManager;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address receiver) public view virtual override returns (uint256 allowed) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if ($.userDepositLimit == type(uint256).max && $.strategyDepostLimit == type(uint256).max) {
            return type(uint256).max;
        } else {
            uint256 sharesBalance = balanceOf(receiver);
            uint256 sharesValue = convertToAssets(sharesBalance);
            uint256 availableDepositorLimit =
                $.userDepositLimit == type(uint256).max ? type(uint256).max : $.userDepositLimit - sharesValue;
            uint256 availableStrategyLimit =
                $.strategyDepostLimit == type(uint256).max ? type(uint256).max : $.strategyDepostLimit - totalAssets();
            uint256 userBalance = IERC20(asset()).balanceOf(address(receiver));
            allowed =
                availableDepositorLimit < availableStrategyLimit ? availableDepositorLimit : availableStrategyLimit;
            allowed = userBalance < allowed ? userBalance : allowed;
        }
    }

    function maxMint(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return previewDeposit(maxAssets);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        IERC20 _asset = IERC20(asset());
        _asset.safeTransferFrom(caller, address(this), assets);

        // TODO: might be useful to implement the following logic:

        // uint256 availableCapacity = $.strategyCapacity - utilizedAssets();
        // uint256 assetsToUtilize = assets > availableCapacity ? availableCapacity : assets;

        // the problem is that we need a different way to manage idle assets

        uint256 assetsToHedge = assets.mulDiv(PRECISION, PRECISION + $.targetLeverage);
        uint256 assetsToSpot = assets - assetsToHedge;
        $.pendingUtilization += assetsToSpot;

        _asset.safeTransfer($.positionManager, assetsToHedge);
        // TODO: adjust for idle imbalance
        IPositionManager($.positionManager).increasePositionCollateral(assetsToHedge);

        _mint(receiver, shares);

        emit PendingUtilizationIncrease(assetsToSpot);
        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
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

        uint256 idle = idleAssets();
        if (idle >= assets) {
            IERC20(asset()).safeTransfer(receiver, assets);
            $.idleImbalance += assets.mulDiv(PRECISION, PRECISION + $.targetLeverage);
            $.pendingUtilization -= assets;
        } else {
            uint128 counter = $.requestCounter[owner];

            bytes32 withdrawId = getWithdrawId(owner, counter);
            $.withdrawRequests[withdrawId] = WithdrawState({
                requestTimestamp: uint128(block.timestamp),
                requestedAmount: assets,
                executedFromSpot: 0,
                executedFromIdle: 0,
                executedFromHedge: 0,
                executionCost: 0,
                receiver: receiver,
                isExecuted: false,
                isClaimed: false
            });

            // if strategy holds idle, mark idle as withdrawn
            uint256 remainingAmountToWithdraw = assets - idle;
            uint256 remainingAmountToWithdrawFromSpot =
                remainingAmountToWithdraw.mulDiv($.targetLeverage, PRECISION + $.targetLeverage);

            $.totalPendingWithdraw += remainingAmountToWithdraw;
            $.pendingDeutilization += $.oracle.convertTokenAmount(asset(), product(), remainingAmountToWithdrawFromSpot);
            $.pendingUtilization -= idle;
            $.idleImbalance += idle.mulDiv(PRECISION, PRECISION + $.targetLeverage);
            $.assetsToClaim += idle;
            $.activeWithdrawRequests.push(withdrawId);
            $.requestCounter[owner]++;

            emit WithdrawRequest(caller, receiver, owner, withdrawId, assets);
        }

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestId) external virtual {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        WithdrawState memory requestData = $.withdrawRequests[requestId];

        // validate claim
        if (requestData.receiver != msg.sender) {
            revert Errors.UnauthorizedClaimer(msg.sender, requestData.receiver);
        }
        if (!requestData.isExecuted) {
            revert Errors.RequestNotExecuted();
        }
        if (requestData.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        $.assetsToClaim -= (requestData.executedFromSpot + requestData.executedFromIdle);
        $.withdrawRequests[requestId].isClaimed = true;
        uint256 totalExecuted =
            requestData.executedFromSpot + requestData.executedFromIdle + requestData.executedFromHedge;
        IERC20 asset_ = IERC20(asset());
        asset_.safeTransfer(msg.sender, totalExecuted);

        delete $.withdrawRequests[requestId];

        emit Claim(msg.sender, requestId, totalExecuted);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO: account for pendings
    function totalAssets() public view virtual override returns (uint256 total) {
        return utilizedAssets() + idleAssets();
    }

    function utilizedAssets() public view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 productBalance = IERC20(product()).balanceOf(address(this));
        uint256 productPrice = $.oracle.getAssetPrice(product());
        uint256 assetPrice = $.oracle.getAssetPrice(asset());
        uint256 positionNetBalance = IPositionManager($.positionManager).positionNetBalance();
        return productBalance.mulDiv(productPrice, assetPrice) + positionNetBalance;
    }

    function idleAssets() public view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        return assetBalance - $.assetsToClaim;
    }

    function getWithdrawId(address owner, uint128 counter) public view virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 baseShares = convertToShares(assets);
        return baseShares.mulDiv(PRECISION - $.entryCost, PRECISION);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 baseAssets = convertToAssets(shares);
        return baseAssets.mulDiv(PRECISION, PRECISION - $.entryCost);
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function utilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyRole(OPERATOR_ROLE)
        returns (uint256 amountOut)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        // can only utilize when there is no pending utilization
        if ($.utilizing) {
            revert Errors.AlreadyUtilizing();
        }

        // can only utilize when pending utilization is positive
        if ($.pendingUtilization == 0) {
            revert Errors.NegativePendingUtilization($.pendingUtilization);
        }

        // actual utilize amount is min of amount, idle assets,  pending utilization and available capacity
        uint256 idle = idleAssets();
        amount = amount > idle ? idle : amount;
        amount = amount > $.pendingUtilization ? $.pendingUtilization : amount;
        // uint256 availableCapacity = $.strategyCapacity - utilizedAssets();
        // amount = amount > availableCapacity ? availableCapacity : amount;

        // can only utilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        if (swapType == SwapType.INCH_V6) {
            amountOut = InchAggregatorV6Logic.executeSwap(asset(), product(), true, data);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        // TODO: check prices
        uint256 spotExecutionPrice = amount.mulDiv(PRECISION, amountOut, Math.Rounding.Ceil);

        //
        IPositionManager($.positionManager).increasePositionCollateral(amountOut, spotExecutionPrice);
        IPositionManager($.positionManager).increasePositionSize(amountOut, spotExecutionPrice);

        $.utilizing = true;

        emit Utilize(msg.sender, amount, amountOut);
    }

    function deutilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyRole(OPERATOR_ROLE)
        returns (uint256 amountOut)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 productBalance = IERC20(product()).balanceOf(address(this));

        // actual deutilize amount is min of amount, product balance and pending deutilization
        amount = amount > productBalance ? productBalance : amount;
        amount = amount > $.pendingDeutilization ? $.pendingDeutilization : amount;

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        if (swapType == SwapType.INCH_V6) {
            amountOut = InchAggregatorV6Logic.executeSwap(asset(), product(), false, data);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        if (!$.rebalancing) {
            // processing withdraw requests
            $.assetsToClaim += amountOut;
        }

        // TODO: check prices
        uint256 spotExecutionPrice = amount.mulDiv(PRECISION, amountOut, Math.Rounding.Ceil);
        IPositionManager($.positionManager).decreasePositionSize(amountOut, spotExecutionPrice);

        emit Deutilize(msg.sender, amount, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function oracle() external view returns (address) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return address($.oracle);
    }

    function entryCost() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.entryCost;
    }

    function userDepositLimit() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.userDepositLimit;
    }

    function strategyDepositLimit() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.strategyDepostLimit;
    }

    function requestCounter(address owner) external view returns (uint128) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.requestCounter[owner];
    }

    function withdrawRequest(bytes32 requestId) external view returns (WithdrawState memory) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.withdrawRequests[requestId];
    }

    function assetsToClaim() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.assetsToClaim;
    }

    function currentRound() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.currentRound;
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION MANAGER CALLBACKS LOGIC
    //////////////////////////////////////////////////////////////*/

    function afterIncreasePositionSize() external {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (msg.sender != $.positionManager) {
            revert Errors.CallerNotPositionManager();
        }

        if (!$.utilizing) {
            revert Errors.NotUtilizing();
        }

        // TODO
    }

    function afterDecreasePositionSize(uint256 amountExecuted, uint256 executionCost, bool isSuccess) external {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        if (msg.sender != $.positionManager) {
            revert Errors.CallerNotPositionManager();
        }

        if (!$.utilizing) {
            revert Errors.NotUtilizing();
        }

        if (isSuccess) {
            if ($.rebalancing) {
                // processing rebalance request
            } else {
                // processing withdraw requests
                uint256 cacheWithdrawnFromSpot = $.withdrawnFromSpot;
                uint256 cacheWithdrawnFromIdle = $.withdrawnFromIdle;
                uint256 amountAvailable =
                    cacheWithdrawnFromSpot + cacheWithdrawnFromIdle + amountExecuted + executionCost;

                // as all amountAvailable will be processed, we can update the totalPendingWithdrawState
                uint256 totalWithdraw = $.totalPendingWithdraw;
                (, totalWithdraw) = totalWithdraw.trySub(amountAvailable);
                $.totalPendingWithdraw = totalWithdraw;

                // amountExecuted should be recorded is assetsToClaim
                $.assetsToClaim += amountExecuted;

                uint256 cacheDecreaseCollateral = $.pendingDecreaseCollateral;
                uint256 index;

                while (amountAvailable > 0) {
                    bytes32 requestId0 = $.activeWithdrawRequests[index];
                    WithdrawState memory request0 = $.withdrawRequests[requestId0];
                    uint256 executedAmount = request0.executedFromSpot + request0.executedFromIdle
                        + request0.executedFromHedge + request0.executionCost;
                    uint256 remainingAmount = request0.requestedAmount - executedAmount;
                    if (amountAvailable >= remainingAmount) {
                        // remaining amount is enough fully cover current request

                        // allocation of withdrawn assets rounded to floor
                        uint256 allocationOfSpot = cacheWithdrawnFromSpot.mulDiv(remainingAmount, amountAvailable);
                        uint256 allocationOfIdle = cacheWithdrawnFromIdle.mulDiv(remainingAmount, amountAvailable);
                        uint256 allocationOfHedge = amountExecuted.mulDiv(remainingAmount, amountAvailable);
                        uint256 allocationOfCost = executionCost.mulDiv(remainingAmount, amountAvailable);

                        // dust goes to costs
                        uint256 dust = remainingAmount
                            - (allocationOfSpot + allocationOfIdle + allocationOfHedge + allocationOfCost);

                        request0.executedFromSpot += allocationOfSpot;
                        request0.executedFromIdle += allocationOfIdle;
                        request0.executedFromHedge += allocationOfHedge;
                        request0.executionCost += (allocationOfCost + dust);

                        amountAvailable -= (remainingAmount - dust);
                        cacheDecreaseCollateral += allocationOfHedge;

                        cacheWithdrawnFromSpot -= allocationOfSpot;
                        cacheWithdrawnFromIdle -= allocationOfIdle;
                        amountExecuted -= allocationOfHedge;
                        executionCost -= allocationOfCost;

                        // if requested amount is fulfilled push to it closed
                        $.closedWithdrawRequests.push(requestId0);

                        index++;
                    } else {
                        // redistribute remaining allocations

                        request0.executedFromSpot += cacheWithdrawnFromSpot;
                        request0.executedFromIdle += cacheWithdrawnFromIdle;
                        request0.executedFromHedge += amountExecuted;
                        request0.executionCost += executionCost;

                        amountAvailable = 0;
                    }

                    // update request storage state
                    $.withdrawRequests[requestId0] = request0;
                }

                // update global state
                $.withdrawnFromSpot = 0;
                $.withdrawnFromIdle = 0;
                // recalculate pendingDeutilization based on the new oracle price
                $.pendingDeutilization =
                    totalWithdraw > 0 ? $.oracle.convertTokenAmount(asset(), product(), totalWithdraw) : 0;
                $.pendingDecreaseCollateral = cacheDecreaseCollateral;

                // remove fulfilled requests from activeWithdrawRequests based on index
                if (index > 0) {
                    for (uint256 i = 0; i < $.activeWithdrawRequests.length - index; i++) {
                        $.activeWithdrawRequests[i] = $.activeWithdrawRequests[i + index];
                    }
                    for (uint256 j = 0; j < index; j++) {
                        $.activeWithdrawRequests.pop();
                    }

                    // request decrease collateral from position manager if there are any fulfilled requests

                    //TODO: adjust for idle imbalance
                    IPositionManager($.positionManager).decreasePositionCollateral(cacheDecreaseCollateral);
                }
            }
        } else {
            // processing execution revert
        }
    }

    //
    function afterIncreasePositionCollateral() external {
        // TODO
    }

    function afterDecreasePositionCollateral(uint256 amount, bool isSuccess) external {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        if (msg.sender != $.positionManager) {
            revert Errors.CallerNotPositionManager();
        }

        if ($.rebalancing) {
            // processing rebalance request
        } else {
            // processing withdraw requests

            IERC20(asset()).safeTransferFrom($.positionManager, address(this), amount);
        }
    }
}
