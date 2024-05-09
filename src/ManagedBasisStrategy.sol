// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAggregationRouter } from "src/interfaces/IAggregationRouter.sol";

import {Errors} from "./Errors.sol";

contract ManagedBasisStrategy is Initializable, UUPSUpgradeable, ERC4626Upgradeable, AccessControlDefaultAdminRulesUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    event WithdrawRequest(address indexed sender, address indexed receiver, address indexed owner, bytes32 requestId, uint256 amount);
    event Claim(address indexed claimer, bytes32 requestId, uint256 amount);

    enum SwapType {
        MANUAL,
        INCH
    }
    
    

    struct WithdrawState {
        uint128 requestCounter;
        uint128 requestTimestamp;
        uint256 totalWithdrawAmount;
        uint256 executedWithdrawAmount;
        address receiver;
        bool executed;
        bool claimed;
    }

    struct ShortState {
        uint256 collateralAmount;
        uint256 sizeInTokens;
        uint256 unrealizedPnl;
        uint256 accumulatedFundingFee;
        uint256 timestamp;
    }

    

    uint256 public constant PRECISION = 1e18;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IERC20 public product;
    address public operator;

    uint256 public targetLeverage;
    uint256 public minLeverage;
    uint256 public maxLeverage;

    uint256 public entryCost;
    uint256 public exitCost;

    uint256 public currentRound;
    mapping(uint256 => ShortState) public shortState;
    mapping(address => uint128) public requestCounter;
    mapping(bytes32 => WithdrawState) public withdrawRequests;

    uint256 public assetsToClaim;



    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function initialize(address _asset, address _owner, address _operator) public initializer {
        __ERC4626_init(IERC20(_asset));
        __AccessControlDefaultAdminRules_init(1 days, _owner);

    }

    function _authorizeUpgrade(address /*newImplementation*/) internal virtual override {}

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/




    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address receiver) public view virtual override returns (uint256) {

    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        IERC20 asset_ = IERC20(asset());
        uint256 targetLeverage_ = targetLeverage;
        uint256 assetsToSpot = assets.mulDiv(targetLeverage_, targetLeverage_ + PRECISION);

        asset_.safeTransferFrom(caller, address(this), assets);
        asset_.safeTransfer(operator, assets - assetsToSpot);

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        address asset_ = asset();

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);

        uint128 counter = requestCounter[owner];

        bytes32 requestId = getRequestId(owner, counter);
        withdrawRequests[requestId] = WithdrawState({
            requestCounter: counter,
            requestTimestamp: uint128(block.timestamp),
            totalWithdrawAmount: assets,
            executedWithdrawAmount: 0,
            receiver: receiver,
            executed: false,
            claimed: false
        });

        requestCounter[owner]++;

        emit WithdrawRequest(caller, receiver, owner, requestId, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestId) external virtual {
        WithdrawState memory requestData = withdrawRequests[requestId];
        
        // validate claim
        if (requestData.receiver != msg.sender) {
            revert Errors.UnauthoirzedClaimer(msg.sender, requestData.receiver);
        }
        if (!requestData.executed) {
            revert Errors.RequestNotExecuted(requestData.totalWithdrawAmount, requestData.executedWithdrawAmount);
        }
        if (requestData.claimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        assetsToClaim -= requestData.totalWithdrawAmount;
        withdrawRequests[requestId].claimed = true;
        IERC20 asset_ = IERC20(asset());

        asset_.safeTransfer(msg.sender, requestData.totalWithdrawAmount);

        emit Claim(msg.sender, requestId, requestData.totalWithdrawAmount);

    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function reportState(ShortState calldata state) external virtual onlyRole(OPERATOR_ROLE) {
        shortState[currentRound] = state;
        currentRound ++;
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual override returns (uint256) {

    }

    function idleAssets() public view virtual returns (uint256) {

    }

    function getRequestId(address owner, uint128 counter) public view virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        uint256 baseShares =  _convertToShares(assets, Math.Rounding.Floor);
        return baseShares.mulDiv(PRECISION - entryCost, PRECISION);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        uint256 baseAssets =  _convertToAssets(shares, Math.Rounding.Ceil);
        return baseAssets.mulDiv(PRECISION, PRECISION - entryCost);
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 baseShares =  _convertToShares(assets, Math.Rounding.Ceil);
        return baseShares.mulDiv(PRECISION, PRECISION - entryCost);
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 baseAssets =  _convertToAssets(shares, Math.Rounding.Floor);
        return baseAssets.mulDiv(PRECISION - entryCost, PRECISION);
    }


    /*//////////////////////////////////////////////////////////////
                        OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function utilize(uint256 amount, SwapType swapType, bytes calldata data) public virtual {
        if (swapType == SwapType.INCH) {
            
        }
    }

    function receiveAndUtilize(uint256 amount, SwapType swapType, bytes calldata data) public virtual {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        utilize(amount, swapType, data);
    }

    function deutilize() public virtual {

    }

    function _prepareInchSwap(IAggregationRouter router, IAggregationRouter.SwapDescription memory desc, bool isUtilize) internal virtual returns (bool) {
        address asset_ = asset();
        address product_ = address(product);
        if (isUtilize) {
            if (desc.srcToken != asset_ || desc.dstToken != product_) {
                revert Errors.InchSwapInvailidTokens();
            }
        } else {
            if (desc.srcToken != product_ || desc.dstToken != asset_) {
                revert Errors.InchSwapInvailidTokens();
            }
        }

        uint256 srcBalance = IERC20(desc.srcToken).balanceOf(address(this));
        if (desc.amount > srcBalance) {
            revert Errors.InchSwapAmountExceedsBalance(desc.amount, srcBalance);
        }
        if (desc.dstReceiver != address(this) || desc.dstReceiver != address(0)) {
            revert Errors.InchInvalidReceiver();
        }

        IERC20(desc.srcToken).safeIncreaseAllowance(address(router), desc.amount);
    }

    /*//////////////////////////////////////////////////////////////
                        REBALANCE LOGIC
    //////////////////////////////////////////////////////////////*/




    
}