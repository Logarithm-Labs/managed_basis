// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "src/libraries/Errors.sol";

abstract contract OffChainPositionManager is IPositionManager {
    using SafeCast for uint256;

    struct PositionState {
        uint256 sizeInTokens;
        uint256 netBalance;
        uint256 markPrice;
        uint256 timestamp;
    }

    struct RequestInfo {
        uint256 sizeDeltaInTokens;
        uint256 collateralAmount;
        uint256 spotExecutionPrice;
        bool isIncrease;
        bool isExecuted;
    }
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.OffChainPositionManager
    struct OffChainPositionManagerStorage {
        // configuration
        address strategy;
        address oracle;
        address indexToken;
        address collateralToken;
        bool isLong;
        uint256 maxClaimableFundingShare;
        uint256 maxHedgeDeviation;
        // position state
        uint256 currentRound;
        bytes32 activeRequestId;
        mapping(uint256 => PositionState) positionStates;
        mapping(bytes32 => RequestInfo) requests;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.OffChainPositionManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OffChainPositionManagerStorageLocation =
        0xc79dcf1ab1ed210e1b815a3e944622845af0e197fa2b370829d3b756c740ef00;

    function _getOffChainPositionManagerStorage() private pure returns (OffChainPositionManagerStorage storage $) {
        assembly {
            $.slot := OffChainPositionManagerStorageLocation
        }
    }

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

    event AgentTransfer(address indexed caller, uint256 amount, bool toStrategy);

    event ReportState(uint256 positionSizeInTokens, uint256 positionNetBalance, uint256 markPrice, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                        POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function getRequestId(uint256 round) public view virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), round));
    }

    function increasePositionSize(uint256 sizeDeltaIntokens, uint256 spotExecutionPrice) public {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if ($.activeRequestId != bytes32(0)) {
            revert Errors.ActiveRequestIsNotClosed($.activeRequestId);
        }

        uint256 round = $.currentRound + 1;
        bytes32 requestId = getRequestId(round);

        $.currentRound = round;
        $.activeRequestId = requestId;

        $.requests[requestId] = RequestInfo({
            sizeDeltaInTokens: sizeDeltaIntokens,
            collateralAmount: 0,
            spotExecutionPrice: spotExecutionPrice,
            isIncrease: true,
            isExecuted: false
        });

        emit RequestIncreasePositionSize(sizeDeltaIntokens, requestId);
    }

    function decreasePositionSize(uint256 sizeDeltaIntokens, uint256 spotExecutionPrice) public {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if ($.activeRequestId != bytes32(0)) {
            revert Errors.ActiveRequestIsNotClosed($.activeRequestId);
        }

        uint256 round = $.currentRound + 1;
        bytes32 requestId = getRequestId(round);

        $.currentRound = round;
        $.activeRequestId = requestId;

        $.requests[requestId] = RequestInfo({
            sizeDeltaInTokens: sizeDeltaIntokens,
            collateralAmount: 0,
            spotExecutionPrice: spotExecutionPrice,
            isIncrease: false,
            isExecuted: false
        });

        emit RequestDecreasePositionSize(sizeDeltaIntokens, requestId);
    }

    function increasePositionCollateral(uint256 collateralAmount) public {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if ($.activeRequestId != bytes32(0)) {
            revert Errors.ActiveRequestIsNotClosed($.activeRequestId);
        }

        uint256 round = $.currentRound + 1;
        bytes32 requestId = getRequestId(round);

        $.currentRound = round;
        $.activeRequestId = requestId;

        $.requests[requestId] = RequestInfo({
            sizeDeltaInTokens: 0,
            collateralAmount: collateralAmount,
            spotExecutionPrice: 0,
            isIncrease: true,
            isExecuted: false
        });

        emit RequestIncreasePositionCollateral(collateralAmount, requestId);
    }

    function decreasePositionCollateral(uint256 collateralAmount) public {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if ($.activeRequestId != bytes32(0)) {
            revert Errors.ActiveRequestIsNotClosed($.activeRequestId);
        }

        uint256 round = $.currentRound + 1;
        bytes32 requestId = getRequestId(round);

        $.currentRound = round;
        $.activeRequestId = requestId;

        $.requests[requestId] = RequestInfo({
            sizeDeltaInTokens: 0,
            collateralAmount: collateralAmount,
            spotExecutionPrice: 0,
            isIncrease: false,
            isExecuted: false
        });

        emit RequestDecreasePositionCollateral(collateralAmount, requestId);
    }

    /*//////////////////////////////////////////////////////////////
                            AGENT LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferToAgent(uint256 amount) external {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        IERC20($.collateralToken).transfer(msg.sender, amount);

        emit AgentTransfer(msg.sender, amount, false);
    }

    function transferFromAgent(uint256 amount) external {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        IERC20($.collateralToken).transferFrom(msg.sender, address(this), amount);

        emit AgentTransfer(msg.sender, amount, true);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION STATE LOGIC
    //////////////////////////////////////////////////////////////*/

    function reportStateAndExecuteRequest(
        bytes32 requestId,
        uint256 sizeInTokens,
        uint256 netBalance,
        uint256 requestExecutionPrice,
        bool isSuccess
    ) public {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if (requestId != $.activeRequestId || requestId == bytes32(0)) {
            revert Errors.InvalidRequestId(requestId, $.activeRequestId);
        }

        if (requestId != bytes32(0)) {
            RequestInfo memory request0 = $.requests[requestId];
            if (isSuccess) {
                // if request is executed successfully we need to calculate execution cost and emit execution event
                int256 executionCost; // negative execution cost means profit
                if (request0.isIncrease) {
                    executionCost = (int256(request0.spotExecutionPrice) - int256(requestExecutionPrice))
                        * int256(request0.sizeDeltaInTokens);
                    emit IncreasePositionSize(request0.sizeDeltaInTokens, executionCost, requestId);
                } else {
                    executionCost = (int256(requestExecutionPrice) - int256(request0.spotExecutionPrice))
                        * int256(request0.sizeDeltaInTokens);
                    emit DecreasePositionSize(request0.sizeDeltaInTokens, executionCost, requestId);
                }
            } else {
                // TODO
                // if request failed we need to revert changes in strategy spot position
            }
        }

        PositionState storage state = $.positionStates[$.currentRound];
        state.sizeInTokens = sizeInTokens;
        state.netBalance = netBalance;
        state.markPrice = requestExecutionPrice;
        state.timestamp = block.timestamp;

        emit ReportState(state.sizeInTokens, state.netBalance, state.markPrice, state.timestamp);
    }

    function positionNetBalance() public view virtual override returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        PositionState memory state = $.positionStates[$.currentRound];

        uint256 price = IOracle($.oracle).getAssetPrice($.indexToken);
        uint256 positionValue = state.sizeInTokens * price;
        uint256 positionSize = state.sizeInTokens * state.markPrice;
        int256 virtualPnl = $.isLong
            ? positionValue.toInt256() - positionSize.toInt256()
            : positionSize.toInt256() - positionValue.toInt256();

        if (virtualPnl >= 0) {
            return state.netBalance + uint256(virtualPnl);
        } else if (state.netBalance > uint256(-virtualPnl)) {
            return state.netBalance - uint256(-virtualPnl);
        } else {
            return 0;
        }
    }
}
