// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import "src/interfaces/IManagedBasisStrategy.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DataTypes} from "src/libraries/utils/DataTypes.sol";

import {console2 as console} from "forge-std/console2.sol";

contract OffChainPositionManager is IPositionManager, UUPSUpgradeable, OwnableUpgradeable {
    using SafeCast for uint256;
    using Math for uint256;

    struct PositionState {
        uint256 sizeInTokens;
        uint256 netBalance;
        uint256 markPrice;
        uint256 timestamp;
    }

    struct RequestInfo {
        DataTypes.PositionManagerPayload request;
        DataTypes.PositionManagerPayload response;
        uint256 requestTimestamp;
        uint256 responseRound;
        uint256 responseTimestamp;
        bool isReported;
        bool isSuccess;
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
        bool isLong;
        uint256[2] increaseSizeMinMax;
        uint256[2] increaseCollateralMinMax;
        uint256[2] decreaseSizeMinMax;
        uint256[2] decreaseCollateralMinMax;
        // position state
        uint256 currentRound;
        uint256 lastRequestRound;
        uint256 pendingCollateralIncrease;
        mapping(uint256 round => PositionState) positionStates;
        mapping(uint256 round => RequestInfo) requests;
        uint256[] requestRounds;
    }

    uint256 private constant PRECISION = 1e18;

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
        $.increaseSizeMinMax = [0, type(uint256).max];
        $.increaseCollateralMinMax = [0, type(uint256).max];
        $.decreaseSizeMinMax = [0, type(uint256).max];
        $.decreaseCollateralMinMax = [0, type(uint256).max];

        // strategy is trusted
        IERC20(collateralToken_).approve(strategy_, type(uint256).max);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    function setAgent(address agent) external onlyOwner {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.agent = agent;
    }

    function setSizeMinMax(
        uint256 increaseSizeMin,
        uint256 increaseSizeMax,
        uint256 decreaseSizeMin,
        uint256 decreaseSizeMax
    ) external onlyOwner {
        require(increaseSizeMin < increaseSizeMax && decreaseSizeMin < decreaseSizeMax);
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.increaseSizeMinMax = [increaseSizeMin, increaseSizeMax];
        $.decreaseSizeMinMax = [decreaseSizeMin, decreaseSizeMax];
    }

    function setCollateralMinMax(
        uint256 increaseCollateralMin,
        uint256 increaseCollateralMax,
        uint256 decreaseCollateralMin,
        uint256 decreaseCollateralMax
    ) external onlyOwner {
        require(increaseCollateralMin < increaseCollateralMax && decreaseCollateralMin < decreaseCollateralMax);
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.increaseCollateralMinMax = [increaseCollateralMin, increaseCollateralMax];
        $.decreaseCollateralMinMax = [decreaseCollateralMin, decreaseCollateralMax];
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event CreateRequest(
        uint256 indexed round, uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease
    );
    event ReportRequest(
        uint256 indexed requestRound,
        uint256 indexed reportRound,
        uint256 sizeDeltaInTokens,
        uint256 collateralDeltaAmount,
        bool isIncrease
    );

    event RequestIncreasePosition(uint256 collateralDeltaAmount, uint256 sizeDeltaInTokens, uint256 round);

    event RequestDecreasePosition(uint256 collateralDeltaAmount, uint256 sizeDeltaInTokens, uint256 round);

    event AgentTransfer(address indexed caller, uint256 amount, bool toAgent);

    event ReportState(uint256 positionSizeInTokens, uint256 positionNetBalance, uint256 markPrice, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAgent() {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        // agent is added to access controll for testing purposes
        if (msg.sender != $.agent) {
            revert Errors.CallerNotAgent();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        REQUEST LOGIC 
    //////////////////////////////////////////////////////////////*/

    function adjustPosition(DataTypes.PositionManagerPayload memory params) external {
        // increments round
        // stores position state from the previous round in the current round
        // stores request in the current round
        // stores round of the active request
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if (msg.sender != $.strategy) {
            revert Errors.CallerNotStrategy();
        }

        uint256 round = $.currentRound + 1;

        if (params.isIncrease) {
            if (params.collateralDeltaAmount > 0) {
                if (
                    params.collateralDeltaAmount < $.increaseCollateralMinMax[0]
                        || params.collateralDeltaAmount > $.increaseCollateralMinMax[1]
                ) {
                    revert Errors.InvalidCollateralRequest(params.collateralDeltaAmount, true);
                }
                _transferToAgent(params.collateralDeltaAmount);
            }
            if (params.sizeDeltaInTokens > 0) {
                if (
                    params.sizeDeltaInTokens < $.increaseSizeMinMax[0]
                        || params.sizeDeltaInTokens > $.increaseSizeMinMax[1]
                ) {
                    revert Errors.InvalidCollateralRequest(params.sizeDeltaInTokens, true);
                }
            }

            emit RequestIncreasePosition(params.collateralDeltaAmount, params.sizeDeltaInTokens, round);
        } else {
            if (params.collateralDeltaAmount > 0) {
                if (
                    params.collateralDeltaAmount < $.decreaseCollateralMinMax[0]
                        || params.collateralDeltaAmount > $.decreaseCollateralMinMax[1]
                ) {
                    revert Errors.InvalidCollateralRequest(params.collateralDeltaAmount, false);
                }
            }
            if (params.sizeDeltaInTokens > 0) {
                if (
                    params.sizeDeltaInTokens < $.decreaseSizeMinMax[0]
                        || params.sizeDeltaInTokens > $.decreaseSizeMinMax[1]
                ) {
                    revert Errors.InvalidCollateralRequest(params.sizeDeltaInTokens, false);
                }
            }

            emit RequestDecreasePosition(params.collateralDeltaAmount, params.sizeDeltaInTokens, round);
        }

        RequestInfo memory requestInfo;
        requestInfo.request = params;
        requestInfo.requestTimestamp = block.timestamp;

        $.requests[round] = requestInfo;
        $.positionStates[round] = $.positionStates[round - 1];
        $.currentRound = round;
        $.lastRequestRound = round;
        $.requestRounds.push(round);

        emit CreateRequest(round, params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    // TODO: add validation logic
    function reportState(uint256 sizeInTokens, uint256 netBalance, uint256 markPrice) external onlyAgent {
        // increments round
        // stores position state in the current round
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        uint256 round = $.currentRound + 1;

        PositionState memory state;
        state.sizeInTokens = sizeInTokens;
        state.netBalance = netBalance;
        state.markPrice = markPrice;
        state.timestamp = block.timestamp;

        $.positionStates[round] = state;

        emit ReportState(state.sizeInTokens, state.netBalance, state.markPrice, state.timestamp);
    }

    function reportStateAndExecuteRequest(
        uint256 sizeInTokens,
        uint256 netBalance,
        uint256 markPrice,
        DataTypes.PositionManagerPayload calldata params
    ) external onlyAgent {
        // 1. increments round
        // 2. stores position state in the current round
        // 3. updates reques info of the active request round with the response
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        uint256 round = $.currentRound + 1;
        uint256 requestRound = $.lastRequestRound;

        PositionState memory state = PositionState({
            sizeInTokens: sizeInTokens,
            netBalance: netBalance,
            markPrice: markPrice,
            timestamp: block.timestamp
        });

        if (params.isIncrease) {
            $.pendingCollateralIncrease -= params.collateralDeltaAmount;
        } else {
            if (params.collateralDeltaAmount > 0) {
                _transferFromAgent(params.collateralDeltaAmount);
            }
        }

        DataTypes.PositionManagerPayload memory response = DataTypes.PositionManagerPayload({
            sizeDeltaInTokens: params.sizeDeltaInTokens,
            collateralDeltaAmount: params.collateralDeltaAmount,
            isIncrease: params.isIncrease
        });

        RequestInfo storage requestInfo = $.requests[requestRound];
        requestInfo.response = response;
        requestInfo.responseRound = round;
        requestInfo.responseTimestamp = block.timestamp;
        requestInfo.isReported = true;

        $.positionStates[round] = state;
        $.currentRound = round;

        IManagedBasisStrategy($.strategy).afterAdjustPosition(params);

        emit ReportState(state.sizeInTokens, state.netBalance, state.markPrice, state.timestamp);

        emit ReportRequest(
            requestRound, round, params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease
        );
    }

    function getLastRequest() external view returns (RequestInfo memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.requests[$.lastRequestRound];
    }

    /*//////////////////////////////////////////////////////////////
                            AGENT LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO: remove function after testing
    function forcedTransferToAgent(uint256 amount) external onlyAgent {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if (msg.sender != $.agent) {
            revert Errors.CallerNotAgent();
        }

        _transferToAgent(amount);
    }

    function _transferToAgent(uint256 amount) internal {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.pendingCollateralIncrease += amount;
        IERC20($.collateralToken).transfer($.agent, amount);

        emit AgentTransfer(msg.sender, amount, true);
    }

    // TODO: remove function after testing
    function forcedTransferFromAgent(uint256 amount) external onlyAgent {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if (msg.sender != $.agent) {
            revert Errors.CallerNotAgent();
        }

        _transferFromAgent(amount);
    }

    function _transferFromAgent(uint256 amount) internal {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        IERC20($.collateralToken).transferFrom($.agent, address(this), amount);

        emit AgentTransfer(msg.sender, amount, false);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION STATE LOGIC
    //////////////////////////////////////////////////////////////*/

    function positionNetBalance() public view virtual override returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        PositionState memory state = $.positionStates[$.currentRound];
        uint256 initialNetBalance =
            state.netBalance + $.pendingCollateralIncrease + IERC20($.collateralToken).balanceOf(address(this));

        uint256 positionValue =
            IOracle($.oracle).convertTokenAmount($.indexToken, $.collateralToken, state.sizeInTokens);
        uint256 positionSize =
            state.sizeInTokens.mulDiv(state.markPrice, 10 ** uint256(IERC20Metadata($.indexToken).decimals()));
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

    function currentPositionState() public view returns (PositionState memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.positionStates[$.currentRound];
    }

    function currentLeverage() public view returns (uint256 leverage) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        PositionState memory state = $.positionStates[$.currentRound];
        uint256 initialNetBalance =
            state.netBalance + $.pendingCollateralIncrease + IERC20($.collateralToken).balanceOf(address(this));

        uint256 positionValue =
            IOracle($.oracle).convertTokenAmount($.indexToken, $.collateralToken, state.sizeInTokens);
        uint256 positionSize =
            state.sizeInTokens.mulDiv(state.markPrice, 10 ** uint256(IERC20Metadata($.indexToken).decimals()));
        int256 virtualPnl = $.isLong
            ? positionValue.toInt256() - positionSize.toInt256()
            : positionSize.toInt256() - positionValue.toInt256();
        uint256 netBalance;
        if (virtualPnl >= 0) {
            netBalance = initialNetBalance + uint256(virtualPnl);
        } else if (initialNetBalance > uint256(-virtualPnl)) {
            netBalance = initialNetBalance - uint256(-virtualPnl);
        }

        leverage = netBalance > 0 ? positionValue.mulDiv(PRECISION, netBalance) : 0;
    }

    /*//////////////////////////////////////////////////////////////
                        EXERNAL STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function lastRequestRound() external view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.lastRequestRound;
    }

    function currentRound() external view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.currentRound;
    }

    function positionState(uint256 round) external view returns (PositionState memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.positionStates[round];
    }

    function pendingCollateralIncrease() external view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.pendingCollateralIncrease;
    }

    function requests(uint256 round) external view returns (RequestInfo memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.requests[round];
    }

    function positionSizeInTokens() external view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.positionStates[$.currentRound].sizeInTokens;
    }

    function apiVersion() external view virtual returns (string memory) {
        return "0.0.1";
    }

    function needKeep() external pure virtual returns (bool) {
        return false;
    }

    function keep() external pure {}
}
