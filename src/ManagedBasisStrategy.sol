// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAggregationRouter} from "src/interfaces/IAggregationRouter.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

import {LogBaseVaultUpgradeable} from "src/common/LogBaseVaultUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LogarithmOracle} from "src/LogarithmOracle.sol";

import {InchAggregatorLogic} from "src/libraries/InchAggregatorLogic.sol";
import {Errors} from "src/libraries/Errors.sol";
import {FactoryDeployable} from "src/common/FactoryDeployable.sol";

contract ManagedBasisStrategy is
    FactoryDeployable,
    LogBaseVaultUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    event WithdrawRequest(
        address indexed caller, address indexed receiver, address indexed owner, bytes32 requestId, uint256 amount
    );

    event WithdrawReport(address indexed caller, bytes32 requestId, uint256 amountExecuted);

    event StateReport(
        address indexed caller, uint256 roundId, uint256 netBalance, uint256 sizeInTokens, uint256 markPrice
    );

    event Claim(address indexed claimer, bytes32 requestId, uint256 amount);

    enum SwapType {
        MANUAL,
        INCH
    }

    struct WithdrawalState {
        uint128 requestCounter;
        uint128 requestTimestamp;
        uint256 requestedWithdrawAmount;
        uint256 realizedExecutionLoss;
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

    uint256 public constant PRECISION = 1e18;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    address public operator;
    IOracle public oracle;

    bool public isLong;
    uint256 public targetLeverage;
    uint256 public minLeverage;
    uint256 public maxLeverage;

    uint256 public entryCost;
    uint256 public exitCost;

    uint256 public currentRound;
    mapping(uint256 => PositionState) public positionStates;
    mapping(address => uint128) public requestCounter;
    mapping(bytes32 => WithdrawalState) public withdrawRequests;

    uint256 public assetsToClaim;

    event Utilize(address indexed caller, uint256 amountIn, uint256 amountOut);
    event Deutilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function initialize(address _asset, address _owner) public initializer {
        __FactoryDeployable_init();
        __LogBaseVault_init(IERC20(_asset));
        __AccessControlDefaultAdminRules_init(1 days, _owner);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyFactory {}

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        // TODO
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        IERC20 asset_ = IERC20(asset());
        // uint256 targetLeverage_ = targetLeverage;
        // uint256 assetsToSpot = assets.mulDiv(targetLeverage_, targetLeverage_ + PRECISION);

        asset_.safeTransferFrom(caller, address(this), assets);
        // asset_.safeTransfer(operator, assets - assetsToSpot);

        _mint(receiver, shares);

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

        uint128 counter = requestCounter[owner];

        bytes32 requestId = getRequestId(owner, counter);
        withdrawRequests[requestId] = WithdrawalState({
            requestCounter: counter,
            requestTimestamp: uint128(block.timestamp),
            requestedWithdrawAmount: assets,
            executedWithdrawAmount: 0,
            receiver: receiver,
            isExecuted: false,
            isClaimed: false
        });

        requestCounter[owner]++;

        emit WithdrawRequest(caller, receiver, owner, requestId, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestId) external virtual {
        WithdrawalState memory requestData = withdrawRequests[requestId];

        // validate claim
        if (requestData.receiver != msg.sender) {
            revert Errors.UnauthoirzedClaimer(msg.sender, requestData.receiver);
        }
        if (!requestData.isExecuted) {
            revert Errors.RequestNotExecuted(requestData.requestedWithdrawAmount, requestData.executedWithdrawAmount);
        }
        if (requestData.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        assetsToClaim -= requestData.requestedWithdrawAmount;
        withdrawRequests[requestId].isClaimed = true;
        IERC20 asset_ = IERC20(asset());

        asset_.safeTransfer(msg.sender, requestData.requestedWithdrawAmount);

        emit Claim(msg.sender, requestId, requestData.requestedWithdrawAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO: account for pendings
    function totalAssets() public view virtual override returns (uint256 total) {
        address asset_ = asset();
        address product_ = product();
        uint256 assetPrice = oracle.getAssetPrice(asset_);
        uint256 productPrice = oracle.getAssetPrice(product_);
        uint256 productBalance = IERC20(product_).balanceOf(address(this));
        uint256 productValueInAsset = productBalance.mulDiv(productPrice, assetPrice, Math.Rounding.Floor);
        int256 pnl = _getVirtualPnl();
        total = IERC20(asset_).balanceOf(address(this)) + productValueInAsset + positionStates[currentRound].netBalance;
        if (pnl > 0) {
            total += uint256(pnl);
        } else {
            total -= uint256(-pnl);
        }
    }

    function idleAssets() public view virtual returns (uint256) {}

    function getRequestId(address owner, uint128 counter) public view virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        uint256 baseShares = _convertToShares(assets, Math.Rounding.Floor);
        return baseShares.mulDiv(PRECISION - entryCost, PRECISION);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        uint256 baseAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        return baseAssets.mulDiv(PRECISION, PRECISION - entryCost);
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 baseShares = _convertToShares(assets, Math.Rounding.Ceil);
        return baseShares.mulDiv(PRECISION, PRECISION - exitCost);
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 baseAssets = _convertToAssets(shares, Math.Rounding.Floor);
        return baseAssets.mulDiv(PRECISION - exitCost, PRECISION);
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
        if (swapType == SwapType.INCH) {
            amountOut = InchAggregatorLogic.executeSwap(asset(), product(), true, data);
        }

        emit Utilize(msg.sender, amount, amountOut);
    }

    function receiveAndUtilize(uint256 amount, SwapType swapType, bytes calldata data) public virtual onlyRole(OPERATOR_ROLE) {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        utilize(amount, swapType, data);
    }

    function deutilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        returns (uint256 amountOut)
    {
        if (swapType == SwapType.INCH) {
            amountOut = InchAggregatorLogic.executeSwap(asset(), product(), false, data);
        }
        emit Deutilize(msg.sender, amount, amountOut);
    }

    function reportState(PositionState calldata state) public virtual onlyRole(OPERATOR_ROLE) {
        uint256 _currentRount = currentRound + 1;
        positionStates[_currentRount] = state;
        currentRound = _currentRount;

        emit StateReport(msg.sender, _currentRount, state.netBalance, state.sizeInTokens, state.markPrice);
    }

    // function reportWithdrawal(bytes32[] calldata requestId, uint256[] calldata amountExecuted) public onlyRole(OPERATOR_ROLE) {
    //     if (requestId.length != amountExecuted.length) {
    //         revert Errors.IncosistentParamsLength();
    //     }
    //     for (uint256 i = 0; i < requestId.length; i++) {
    //         withdrawRequests[requestId[i]].executedWithdrawAmount += amountExecuted[i];

    //         // TODO: Add check for isExecuted

    //         emit WithdrawReport(msg.sender, requestId[i], amountExecuted[i]);
    //     }
    // }

    function reportExecutedWithdrawals(bytes32[] calldata requestIds, uint256[] amountExecuted)
        public
        onlyRole(OPERATOR_ROLE)
    {
        IERC20 _asset = IERC20(asset());
        uint256 totalExecutedAmount;
        if (requestId.length != amountExecuted.length) {
            revert Errors.IncosistentParamsLength();
        }
        for (uint256 i = 0; i < requestId.length; i++) {
            withdrawRequests[requestIds[i]].isExecuted = true;
            withdrawRequests[requestIds[i]].executedWithdrawAmount = amountExecuted[i];
            totalExecutedAmount += amountExecuted[i];
            emit ExecuteWithdrawal(); // TODO
        }
        _asset.safeTransferFrom(msg.sender, address(this), totalExecutedAmount);
    }

    function reportStateAndExecutedWithdrawals(
        PositionState calldata state,
        bytes32[] calldata requestIds,
        uint256[] calldata amountsExecuted
    ) external onlyRole(OPERATOR_ROLE) {
        reportState(state);
        reportExecutedWithdrawal(requestIds, amountsExecuted);
    }

    function _getVirtualPnl() internal view virtual returns (int256 pnl) {
        PositionState memory state = positionStates[currentRound];
        uint256 price = oracle.getAssetPrice(product());
        uint256 positionValue = state.sizeInTokens * price;
        uint256 positionSize = state.sizeInTokens * state.markPrice;
        pnl = isLong
            ? positionValue.toInt256() - positionSize.toInt256()
            : positionSize.toInt256() - positionValue.toInt256();
    }
}
