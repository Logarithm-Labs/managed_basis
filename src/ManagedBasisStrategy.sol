// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    struct WithdrawalState {
        uint128 requestCounter;
        uint128 requestTimestamp;
        uint256 requestedWithdrawAmount;
        uint256 executedWithdrawAmount; // requestedAmount - realizedExecutionLoss = executedAmount
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
        uint256 assetsToClaim;
        uint256 currentRound;
        uint256 entryCost;
        uint256 exitCost;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        address positionManager;
        bool isLong;
        mapping(uint256 => PositionState) positionStates;
        mapping(address => uint128) requestCounter;
        mapping(bytes32 => WithdrawalState) withdrawRequests;
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

    event ExecuteWithdrawal(bytes32 requestId, uint256 requestedAmount, uint256 executedAmount);

    event SendToOperator(address indexed caller, uint256 amount);

    event Utilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    event Deutilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION / CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address _asset,
        address _product,
        address _owner,
        address _oracle,
        uint256 _entryCost,
        uint256 _exitCost,
        bool _isLong
    ) external initializer {
        __FactoryDeployable_init();
        __ERC4626_init(IERC20(_asset));
        __LogBaseVault_init(IERC20(_product));
        __AccessControlDefaultAdminRules_init(1 days, _owner);
        __ManagedBasisStrategy_init(_oracle, _entryCost, _exitCost, _isLong);
    }

    function __ManagedBasisStrategy_init(address _oracle, uint256 _entryCost, uint256 _exitCost, bool _isLong)
        public
        initializer
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.oracle = IOracle(_oracle);
        $.entryCost = _entryCost;
        $.exitCost = _exitCost;
        $.isLong = _isLong;
        $.userDepositLimit = type(uint256).max;
        $.strategyDepostLimit = type(uint256).max;
    }

    function setPositionManager(address _positionManager) external onlyFactory {
        if (_positionManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getManagedBasisStrategyStorage().positionManager = _positionManager;
        IERC20(asset()).approve(_positionManager, type(uint256).max);
    }

    function setEntyExitCosts(uint256 _entryCost, uint256 _exitCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.entryCost = _entryCost;
        $.exitCost = _exitCost;
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

        uint128 counter = $.requestCounter[owner];

        bytes32 requestId = getRequestId(owner, counter);
        $.withdrawRequests[requestId] = WithdrawalState({
            requestCounter: counter,
            requestTimestamp: uint128(block.timestamp),
            requestedWithdrawAmount: assets,
            executedWithdrawAmount: 0,
            receiver: receiver,
            isExecuted: false,
            isClaimed: false
        });

        $.requestCounter[owner]++;

        emit WithdrawRequest(caller, receiver, owner, requestId, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestId) external virtual {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        WithdrawalState memory requestData = $.withdrawRequests[requestId];

        // validate claim
        if (requestData.receiver != _msgSender()) {
            revert Errors.UnauthorizedClaimer(_msgSender(), requestData.receiver);
        }
        if (!requestData.isExecuted) {
            revert Errors.RequestNotExecuted();
        }
        if (requestData.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        $.assetsToClaim -= requestData.executedWithdrawAmount;
        $.withdrawRequests[requestId].isClaimed = true;
        IERC20 asset_ = IERC20(asset());
        asset_.safeTransfer(_msgSender(), requestData.executedWithdrawAmount);

        emit Claim(_msgSender(), requestId, requestData.executedWithdrawAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO: account for pendings
    function totalAssets() public view virtual override returns (uint256 total) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        address asset_ = asset();
        address product_ = product();
        uint256 assetPrice = $.oracle.getAssetPrice(asset_);
        uint256 productPrice = $.oracle.getAssetPrice(product_);
        uint256 productBalance = IERC20(product_).balanceOf(address(this));
        uint256 productValueInAsset = productBalance.mulDiv(productPrice, assetPrice, Math.Rounding.Floor);
        int256 pnl = _getVirtualPnl();
        total =
            IERC20(asset_).balanceOf(address(this)) + productValueInAsset + $.positionStates[$.currentRound].netBalance;
        if (pnl > 0) {
            total += uint256(pnl);
        } else {
            if (total >= uint256(-pnl)) {
                total += uint256(-pnl);
            } else {
                total = 0;
            }
        }
    }

    function idleAssets() public view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        return assetBalance - $.assetsToClaim;
    }

    function getRequestId(address owner, uint128 counter) public view virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 baseShares = _convertToShares(assets, Math.Rounding.Floor);
        return baseShares.mulDiv(PRECISION - $.entryCost, PRECISION);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 baseAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        return baseAssets.mulDiv(PRECISION, PRECISION - $.entryCost);
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 baseShares = _convertToShares(assets, Math.Rounding.Ceil);
        return baseShares.mulDiv(PRECISION, PRECISION - $.exitCost);
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 baseAssets = _convertToAssets(shares, Math.Rounding.Floor);
        return baseAssets.mulDiv(PRECISION - $.exitCost, PRECISION);
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function sendToOperator(uint256 amount) public virtual onlyRole(OPERATOR_ROLE) {
        IERC20(asset()).safeTransfer(msg.sender, amount);
        emit SendToOperator(msg.sender, amount);
    }

    function utilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyRole(OPERATOR_ROLE)
        returns (uint256 amountOut)
    {
        uint256 idle = idleAssets();
        if (amount > idle) {
            revert Errors.InsufficientIdleBalanceForUtilize(idle, amount);
        }
        if (swapType == SwapType.INCH_V6) {
            amountOut = InchAggregatorV6Logic.executeSwap(asset(), product(), true, data);
        }

        emit Utilize(msg.sender, amount, amountOut);
    }

    function receiveAndUtilize(uint256 utilizeAmount, uint256 receiveAmount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyRole(OPERATOR_ROLE)
    {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), receiveAmount);
        utilize(utilizeAmount, swapType, data);
    }

    function deutilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyRole(OPERATOR_ROLE)
        returns (uint256 amountOut)
    {
        uint256 productBalance = IERC20(product()).balanceOf(address(this));
        if (amount > productBalance) {
            revert Errors.InsufficientProdcutBalanceForDeutilize(productBalance, amount);
        }
        if (swapType == SwapType.INCH_V6) {
            amountOut = InchAggregatorV6Logic.executeSwap(asset(), product(), false, data);
        }
        emit Deutilize(msg.sender, amount, amountOut);
    }

    function deutilizeAndSend(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyRole(OPERATOR_ROLE)
        returns (uint256 amountOut)
    {
        amountOut = deutilize(amount, swapType, data);
        emit Deutilize(msg.sender, amount, amountOut);

        sendToOperator(amountOut);
    }

    function reportState(PositionState calldata state) public virtual onlyRole(OPERATOR_ROLE) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 _currentRount = $.currentRound + 1;
        $.positionStates[_currentRount] = state;
        $.currentRound = _currentRount;

        emit StateReport(msg.sender, _currentRount, state.netBalance, state.sizeInTokens, state.markPrice);
    }

    function executeWithdrawals(bytes32[] calldata requestIds, uint256[] calldata amountsExecuted)
        public
        onlyRole(OPERATOR_ROLE)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        IERC20 _asset = IERC20(asset());
        uint256 totalExecutedAmount;
        if (requestIds.length != amountsExecuted.length) {
            revert Errors.IncosistentParamsLength();
        }
        for (uint256 i = 0; i < requestIds.length; i++) {
            WithdrawalState storage request = $.withdrawRequests[requestIds[i]];
            request.isExecuted = true;
            request.executedWithdrawAmount = amountsExecuted[i];
            totalExecutedAmount += amountsExecuted[i];

            emit ExecuteWithdrawal(requestIds[i], request.requestedWithdrawAmount, request.executedWithdrawAmount);
        }
        $.assetsToClaim += totalExecutedAmount;
        _asset.safeTransferFrom(msg.sender, address(this), totalExecutedAmount);
    }

    function reportStateAndExecuteWithdrawals(
        PositionState calldata state,
        bytes32[] calldata requestIds,
        uint256[] calldata amountsExecuted
    ) external onlyRole(OPERATOR_ROLE) {
        reportState(state);
        executeWithdrawals(requestIds, amountsExecuted);
    }

    function _getVirtualPnl() internal view virtual returns (int256 pnl) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        PositionState memory state = $.positionStates[$.currentRound];
        uint256 price = $.oracle.getAssetPrice(product());
        uint256 positionValue = state.sizeInTokens * price;
        uint256 positionSize = state.sizeInTokens * state.markPrice;
        pnl = $.isLong
            ? positionValue.toInt256() - positionSize.toInt256()
            : positionSize.toInt256() - positionValue.toInt256();
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

    function exitCost() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.exitCost;
    }

    function isLong() external view returns (bool) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.isLong;
    }

    function userDepositLimit() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.userDepositLimit;
    }

    function strategyDepositLimit() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.strategyDepostLimit;
    }

    function positionState(uint256 roundId) external view returns (PositionState memory) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.positionStates[roundId];
    }

    function requestCounter(address owner) external view returns (uint128) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.requestCounter[owner];
    }

    function withdrawRequest(bytes32 requestId) external view returns (WithdrawalState memory) {
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

    function hedgeCallback(bool wasExecuted, int256 executionCostAmount, uint256 executedHedgeAmount) external {}
}
