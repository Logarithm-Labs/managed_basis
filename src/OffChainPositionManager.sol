// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IOffChainPositionManager} from "src/interfaces/IOffChainPositionManager.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "src/libraries/Errors.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract OffChainPositionManager is IOffChainPositionManager, UUPSUpgradeable, OwnableUpgradeable {
    using SafeCast for uint256;
    using Math for uint256;

    enum RequestType {
        IncreasePosition,
        DecreasePosition
    }

    struct PositionState {
        uint256 sizeInTokens;
        uint256 netBalance;
        uint256 markPrice;
        uint256 timestamp;
    }

    struct RequestInfo {
        uint256 sizeDeltaInTokens;
        uint256 spotExecutionPrice;
        uint256 collateralDeltaAmount;
        bool isIncrease;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.OffChainPositionManager
    struct OffChainPositionManagerStorage {
        // configuration
        address strategy;
        address agent;
        address oracle;
        address indexToken;
        address collateralToken;
        uint256 targetLeverage;
        bool isLong;
        // position state
        uint256 currentRound;
        bytes32 activeRequestId;
        uint256 pendingCollateralIncrease;
        mapping(uint256 => PositionState) positionStates;
        mapping(bytes32 => RequestInfo) requests;
    }

    uint256 private constant FLOAT_PRECISION = 1e30;

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.OffChainPositionManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OffChainPositionManagerStorageLocation =
        0xc79dcf1ab1ed210e1b815a3e944622845af0e197fa2b370829d3b756c740ef00;

    function _getOffChainPositionManagerStorage() private pure returns (OffChainPositionManagerStorage storage $) {
        assembly {
            $.slot := OffChainPositionManagerStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address strategy_,
        address agent_,
        address oracle_,
        address indexToken_,
        address collateralToken_,
        bool isLong_
    ) external initializer {
        __Ownable_init(msg.sender);
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.strategy = strategy_;
        $.agent = agent_;
        $.oracle = oracle_;
        $.indexToken = indexToken_;
        $.collateralToken = collateralToken_;
        $.isLong = isLong_;

        // strategy is trusted
        IERC20(collateralToken_).approve(strategy_, type(uint256).max);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event RequestIncreasePositionSize(uint256 sizeDeltaInTokens, bytes32 requestId);
    event IncreasePositionSize(uint256 sizeDeltaIntokens, int256 executionCost, bytes32 requestId);

    event RequestDecreasePositionSize(uint256 sizeDeltaInTokens, bytes32 requestId);
    event DecreasePositionSize(uint256 sizeDeltaIntokens, int256 executionCost, bytes32 requestId);

    event RequestIncreasePositionCollateral(uint256 collateralAmount, bytes32 requestId);
    event IncreasePositionCollateral(uint256 collateralAmount, bytes32 requestId);

    event RequestDecreasePositionCollateral(uint256 collateralAmount, bytes32 requestId);
    event DecreasePositionCollateral(uint256 collateralAmount, bytes32 requestId);

    event AgentTransfer(address indexed caller, uint256 amount, bool toAgent);

    event ReportState(uint256 positionSizeInTokens, uint256 positionNetBalance, uint256 markPrice, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyStrategy() {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        if (msg.sender != $.strategy) {
            revert Errors.CallerNotStrategy();
        }
        _;
    }

    modifier onlyAgent() {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        if (msg.sender != $.agent) {
            revert Errors.CallerNotAgent();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function getRequestId(uint256 round) public view virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), round));
    }

    // 1. pnl realization from size decrease
    // 2. delta between pnl realization and required collateral decrease
    // 3.1 if pnl realization > required collateral decrease
    //     3.1 increase collateral by this delta in callback
    // 3.2 if pnl realization < required collateral decrease
    //      3.2 remove collateral from base collateral
    // 3.3 if the base is not enough ....

    function adjustPosition(
        uint256 sizeDeltaInTokens,
        uint256 spotExecutionPrice,
        uint256 collateralDeltaAmount,
        bool isIncrease
    ) external onlyStrategy returns (bytes32 requestId) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if ($.activeRequestId != bytes32(0)) {
            revert Errors.ActiveRequestIsNotClosed($.activeRequestId);
        }

        uint256 round = $.currentRound + 1;
        requestId = getRequestId(round);

        $.currentRound = round;
        $.activeRequestId = requestId;

        $.requests[requestId] = RequestInfo({
            sizeDeltaInTokens: sizeDeltaInTokens,
            spotExecutionPrice: spotExecutionPrice,
            collateralDeltaAmount: collateralDeltaAmount,
            isIncrease: isIncrease
        });

        if (isIncrease) {
            if (collateralDeltaAmount > 0) {
                emit RequestIncreasePositionCollateral(collateralDeltaAmount, requestId);
            }
            if (sizeDeltaInTokens > 0) {
                emit RequestIncreasePositionSize(sizeDeltaInTokens, requestId);
            }
        } else {
            if (collateralDeltaAmount > 0) {
                emit RequestDecreasePositionCollateral(collateralDeltaAmount, requestId);
            }
            if (sizeDeltaInTokens > 0) {
                emit RequestDecreasePositionSize(sizeDeltaInTokens, requestId);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            AGENT LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferToAgent() external onlyAgent {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        RequestInfo memory request = $.requests[$.activeRequestId];
        if (request.isIncrease && request.collateralDeltaAmount > 0) {
            revert Errors.InvalidActiveRequestType();
        }

        $.pendingCollateralIncrease += request.collateralDeltaAmount;

        _transferToAgent(request.collateralDeltaAmount);
    }

    // to remove
    function forcedTransferToAgent(uint256 amount) external onlyAgent {
        _transferToAgent(amount);
    }

    function _transferToAgent(uint256 amount) internal {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        IERC20($.collateralToken).transfer(msg.sender, amount);

        emit AgentTransfer(msg.sender, amount, true);
    }

    function forcedTransferFromAgent(uint256 amount) external onlyAgent {
        _transferFromAgent(amount);
    }

    function _transferFromAgent(uint256 amount) internal {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        IERC20($.collateralToken).transferFrom(msg.sender, address(this), amount);

        emit AgentTransfer(msg.sender, amount, false);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION STATE LOGIC
    //////////////////////////////////////////////////////////////*/

    function reportStateAndExecuteRequest(
        uint256 sizeInTokens,
        uint256 netBalance,
        uint256 markPrice,
        bytes32 requestId,
        uint256 requestExecutionPrice,
        uint256 requestExecutionCost,
        bool isSuccess
    ) external onlyAgent {
        // TODO: add validation for prices (difference between mark price, execution price and oracle price should be within the threshold)
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if (requestId != $.activeRequestId || requestId == bytes32(0)) {
            revert Errors.InvalidRequestId(requestId, $.activeRequestId);
        }

        if (requestId != bytes32(0)) {}

        // OLD LOGIC BELOW
        if (requestId != bytes32(0)) {
            RequestInfo memory request = $.requests[requestId];
            if (isSuccess) {
                if (request.isIncrease && request.collateralDeltaAmount > 0) {
                    // if request is successfull we need to decrease pending collateral
                    $.pendingCollateralIncrease -= request.collateralDeltaAmount;
                    IBasisStrategy($.strategy).afterIncreasePositionCollateral(request.collateralDeltaAmount, true);
                } else if (!request.isIncrease && request.collateralDeltaAmount > 0) {
                    // if request is successfull we need to transfer collateral from agent to position manager
                    _transferFromAgent(request.collateralDeltaAmount);
                    IBasisStrategy($.strategy).afterDecreasePositionCollateral(request.collateralDeltaAmount, true);
                } else if (request.isIncrease && request.sizeDeltaInTokens > 0) {
                    // if request is successfull report back to strategy
                    IBasisStrategy($.strategy).afterIncreasePositionSize(request.sizeDeltaInTokens, true);
                } else if (!request.isIncrease && request.sizeDeltaInTokens > 0) {
                    // if request is successfull, estimate executed amount, execution costs, and report back to strategy

                    uint256 indexPrecision = 10 ** uint256(IERC20Metadata($.indexToken).decimals());
                    int256 executionSpread = int256(requestExecutionPrice) - int256(request.spotExecutionPrice);
                    int256 executionCost = executionSpread > 0
                        ? (uint256(executionSpread).mulDiv(request.sizeDeltaInTokens, indexPrecision)).toInt256()
                        : -(uint256(-executionSpread).mulDiv(request.sizeDeltaInTokens, indexPrecision)).toInt256();
                    executionCost += requestExecutionCost.toInt256();
                    executionCost = executionCost > int256(0) ? executionCost : int256(0);
                    IBasisStrategy($.strategy).afterDecreasePositionSize(
                        request.sizeDeltaInTokens, uint256(executionCost), true
                    );
                }
            } else {
                // TODO
                // if request failed we need to revert changes
            }
            $.activeRequestId = bytes32(0);
            IBasisStrategy($.strategy).afterExecuteRequest(requestId);
        }

        // if agent submits state without request, it means that it is regular state update
        // no need to report back to strategy

        PositionState storage state = $.positionStates[$.currentRound];
        state.sizeInTokens = sizeInTokens;
        state.netBalance = netBalance;
        state.markPrice = markPrice;
        state.timestamp = block.timestamp;

        emit ReportState(state.sizeInTokens, state.netBalance, state.markPrice, state.timestamp);
    }

    function positionNetBalance() public view virtual override returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        PositionState memory state = $.positionStates[$.currentRound];
        uint256 initialNetBalance = state.netBalance + $.pendingCollateralIncrease;
        uint256 price = IOracle($.oracle).getAssetPrice($.indexToken);
        uint256 positionValue = state.sizeInTokens * price;
        uint256 positionSize = state.sizeInTokens * state.markPrice;
        int256 virtualPnl = $.isLong
            ? positionValue.toInt256() - positionSize.toInt256()
            : positionSize.toInt256() - positionValue.toInt256();

        if (virtualPnl >= 0) {
            return initialNetBalance + uint256(virtualPnl);
        } else if (initialNetBalance > uint256(-virtualPnl)) {
            return initialNetBalance - uint256(-virtualPnl);
        } else {
            return 0;
        }
    }
}
