// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";

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

contract CompactBasisStrategy is UUPSUpgradeable, LogBaseVaultUpgradeable, OwnableUpgradeable {
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
        // fee state
        uint256 entryCost;
        uint256 exitCost;
        // strategy configuration
        uint256 hedgeDeviationThreshold;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        // asset state
        uint256 assetsToClaim; // asset balance that is ready to claim
        uint256 assetsToWithdraw; // asset balance that is processed for withdrawals
        uint256 pendingUtilizedProducts;
        uint256 pendingDeutilizedAssets;
        // pending state
        uint256 pendingDecreaseCollateral;
        // status state
        DataTypes.StrategyStatus strategyStatus;
        // withdraw state
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        mapping(address => uint128) requestCounter;
        mapping(bytes32 => DataTypes.WithdrawRequestState) withdrawRequests;
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
        uint256 _entryCost,
        uint256 _exitCost
    ) external initializer {
        __LogBaseVault_init(IERC20(_asset), IERC20(_product), name, symbol);
        __Ownable_init(msg.sender);
        __ManagedBasisStrategy_init(
            _oracle, _operator, _targetLeverage, _minLeverage, _maxLeverage, _entryCost, _exitCost
        );
    }

    function __ManagedBasisStrategy_init(
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _entryCost,
        uint256 _exitCost
    ) public initializer {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.oracle = _oracle;
        $.operator = _operator;
        $.entryCost = _entryCost;
        $.exitCost = _exitCost;
        $.targetLeverage = _targetLeverage;
        $.minLeverage = _minLeverage;
        $.maxLeverage = _maxLeverage;
        $.userDepositLimit = type(uint256).max;
        $.strategyDepostLimit = type(uint256).max;
        $.hedgeDeviationThreshold = 1e16; // 1%
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
            status: $.strategyStatus
        });
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
        if (cache0.status != cache1.status) {
            $.strategyStatus = cache1.status;
        }

        emit UpdatePendingUtilization();
    }

    function _updateWithdrawRequestState(
        ManagedBasisStrategyStorage storage $,
        bytes32 withdrawId,
        DataTypes.WithdrawRequestState memory withdrawState
    ) internal virtual {
        $.withdrawRequests[withdrawId] = withdrawState;
    }

    function _executeAdjustPosition(address positionManager, IPositionManager.AdjustPositionParams memory params)
        internal
        virtual
    {
        if (params.isIncrease && params.collateralDeltaAmount > 0) {
            IERC20(asset()).safeTransfer(positionManager, params.collateralDeltaAmount);
        }
        IPositionManager(positionManager).adjustPosition(params);
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

            emit WithdrawRequest(caller, receiver, owner, withdrawId, requestedAmount);
        }

        _updateStrategyState($, cache0, cache1);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestId) external virtual returns (uint256 executedAmont) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.WithdrawRequestState memory withdrawState = $.withdrawRequests[requestId];
        DataTypes.StrategyStateChache memory cache0 = _getStrategyStateCache($);
        DataTypes.WithdrawRequestState memory withdrawState = $.withdrawRequests[withdrawId]

        DataTypes.StrategyStateChache memory cache1;

        (cache1, withdrawState, executedAmount) = BasisStrategyLogic.executeClaim(BasisStrategyLogic.ClaimParams({
            $.maxLeverage,
            totalSupply(),
            withdrawState,
            _getStrategyAddresses($),
            cache0
        }));
        
        _updateStrategyState($, cache0, cache1);
        _updateWithdrawRequestState($, withdrawId, withdrawState);

        IERC20(asset()).safeTransfer(msg.sender, executedAmount);

        emit Claim(msg.sender, requestId, executedAmount);
    }

    function isClaimable(bytes32 requestId) external view returns (bool) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.WithdrawRequestState memory withdrawRequest =
            $.withdrawRequests[requestId];
        (bool isExecuted, ) = BasisStrategyLogic.isWithdrawRequestExecuted(
            withdrawRequest,
            _getStrategyAddresses($),
            _getStrategyStateCache($),
            totalSupply(),
            $.maxLeverage
        )
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
        return $.accRequestedWithdrawAssets - $.proccessedWithdrawAssets;
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

    function pendingUtilization() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        return BasisStrategyLogic.getPendingUtilization(asset(), cache, $.targetLeverage);
    }

    function pendingDeutilization() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        DataTypes.StrategyAddresses memory addr = _getStrategyAddresses($);
        return BasisStrategyLogic.getPendingDeutilization(addr, cache);
    }

    function pendingIncreaseCollateral() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        return BasisStrategyLogic.getPendingIncreaseCollateral(asset(), $.targetLeverage, cache);
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function utilize(uint256 amount, DataTypes.SwapType swapType, bytes calldata swapData)
        external
        virtual
        onlyOperator
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);

        $.strategyStatus = DataTypes.StrategyStatus.DEPOSITING;
        emit UpdateStrategyStatus(DataTypes.StrategyStatus.DEPOSITING);

        bool success;
        uint256 amountOut;
        IPositionManager.AdjustPositionParams memory adjustPositionParams;
        (success, amountOut, cache, adjustPositionParams) = BasisStrategyLogic.executeUtilize(
            BasisStrategyLogic.UtilizeParams({
                amount: amount,
                targetLeverage: $.targetLeverage,
                status: $.strategyStatus,
                swapType: swapType,
                addr: _getStrategyAddresses($),
                cache: cache,
                swapData: swapData
            })
        );
        if (success) {
            _updateStrategyState($, cache);
            _executeAdjustPosition($.positionManager, adjustPositionParams);
            emit Utilize(msg.sender, amount, adjustPositionParams.sizeDeltaInTokens);
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
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        bool success;
        uint256 amountOut;
        IPositionManager.AdjustPositionParams memory adjustPositionParams;
        (success, amountOut, cache, adjustPositionParams) = BasisStrategyLogic.executeDeutilize(
            BasisStrategyLogic.UtilizeParams({
                amount: amount,
                targetLeverage: $.targetLeverage,
                status: $.strategyStatus,
                swapType: swapType,
                addr: _getStrategyAddresses($),
                cache: cache,
                swapData: swapData
            })
        );
        if (success) {
            _updateStrategyState($, cache);
            _executeAdjustPosition($.positionManager, adjustPositionParams);
            emit Deutilize(msg.sender, amount, adjustPositionParams.sizeDeltaInTokens);
        } else {
            emit SwapFailed();
        }
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

    function _manualSwap(uint256 amountIn, bool isAssetToProduct) internal {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (isAssetToProduct) {
            ManualSwapLogic.swap(amountIn, $.assetToProductSwapPath);
        } else {
            ManualSwapLogic.swap(amountIn, $.productToAssetSwapPath);
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
}
