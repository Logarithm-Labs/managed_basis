// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IHedgeManager} from "src/hedge/IHedgeManager.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IOffChainConfig} from "src/hedge/offchain/IOffChainConfig.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

/// @title OffChainPositionManager
///
/// @author Logarithm Labs
///
/// @notice OffChainPositionManager is a smart contract component designed to interact
/// with off-chain perpetual protocols to manage hedge positions.
/// By coordinating with off-chain systems, such as through an oracle or relayer network,
/// the contract adjusts perpetual positions to maintain a target exposure aligned with
/// the strategy’s requirements.
/// This component is ideal for delta-neutral strategies seeking yield from
/// funding payments on off-chain perpetual markets.
///
/// @dev OffChainPositionManager is an upgradeable smart contract, deployed through the beacon proxy pattern.
contract OffChainPositionManager is Initializable, Ownable2StepUpgradeable, IHedgeManager {
    using SafeCast for uint256;
    using Math for uint256;

    /// @dev Used to store the state of offchain position.
    struct PositionState {
        // The size denominated in index token.
        uint256 sizeInTokens;
        // The collateral amount.
        uint256 netBalance;
        // The mark price when this state is submitted.
        uint256 markPrice;
        // The block.timestamp when this state is submitted.
        uint256 timestamp;
    }

    /// @dev Used for the request and response infos.
    struct RequestInfo {
        AdjustPositionPayload request;
        AdjustPositionPayload response;
        uint256 requestTimestamp;
        uint256 responseRound;
        uint256 responseTimestamp;
        bool isReported;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.OffChainPositionManager
    struct OffChainPositionManagerStorage {
        // configuration
        address config;
        address strategy;
        address agent;
        address oracle;
        address indexToken;
        address collateralToken;
        bool isLong;
        // position state
        uint256 currentRound;
        // the last round where position adjusting is requested by strategy.
        uint256 lastRequestRound;
        uint256 pendingCollateralIncrease;
        mapping(uint256 round => PositionState) positionStates;
        mapping(uint256 round => RequestInfo) requests;
        uint256[] requestRounds;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.OffChainPositionManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OffChainPositionManagerStorageLocation =
        0xc79dcf1ab1ed210e1b815a3e944622845af0e197fa2b370829d3b756c740ef00;

    function _getOffChainPositionManagerStorage() private pure returns (OffChainPositionManagerStorage storage $) {
        assembly {
            $.slot := OffChainPositionManagerStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when agent gets updated.
    event AgentUpdated(address indexed account, address indexed newAgent);

    /// @dev Emitted when a new request from strategy is created.
    event CreateRequest(
        uint256 indexed round, uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease
    );

    /// @dev Emitted when a report is executed after requesting.
    event ReportRequest(
        uint256 indexed requestRound,
        uint256 indexed reportRound,
        uint256 sizeDeltaInTokens,
        uint256 collateralDeltaAmount,
        bool isIncrease
    );

    /// @dev Emitted when a increase request is created.
    event RequestIncreasePosition(uint256 collateralDeltaAmount, uint256 sizeDeltaInTokens, uint256 round);

    /// @dev Emitted when a decrease request is created.
    event RequestDecreasePosition(uint256 collateralDeltaAmount, uint256 sizeDeltaInTokens, uint256 round);

    /// @dev Emitted when asset is transferred to agent to increase collateral.
    event AgentTransfer(address indexed caller, uint256 amount, bool toAgent);

    /// @dev Emitted when position's state is reported.
    event ReportState(uint256 positionSizeInTokens, uint256 positionNetBalance, uint256 markPrice, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Authorize caller if it is a configured agent.
    modifier onlyAgent() {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        // agent is added to access controll for testing purposes
        if (msg.sender != $.agent) {
            revert Errors.CallerNotAgent();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address config_, address strategy_, address agent_, address oracle_, bool isLong_)
        external
        initializer
    {
        __Ownable_init(msg.sender);
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.config = config_;
        $.strategy = strategy_;
        $.oracle = oracle_;
        $.indexToken = IBasisStrategy(strategy_).product();
        address asset = IBasisStrategy(strategy_).asset();
        $.collateralToken = asset;
        $.isLong = isLong_;
        _setAgent(agent_);
        // strategy is trusted
        IERC20(asset).approve(strategy_, type(uint256).max);
    }

    function _setAgent(address newAgent) internal {
        if (agent() != newAgent) {
            OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
            $.agent = newAgent;
            emit AgentUpdated(_msgSender(), newAgent);
        }
    }

    function setAgent(address newAgent) external onlyOwner {
        _setAgent(newAgent);
    }

    /*//////////////////////////////////////////////////////////////
                        REQUEST LOGIC 
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHedgeManager
    function adjustPosition(AdjustPositionPayload memory params) external {
        // increments round
        // stores position state from the previous round in the current round
        // stores request in the current round
        // stores round of the active request
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if (msg.sender != $.strategy) {
            revert Errors.CallerNotStrategy();
        }

        if (params.sizeDeltaInTokens == 0 && params.collateralDeltaAmount == 0) {
            revert Errors.InvalidAdjustmentParams();
        }

        uint256 round = $.currentRound + 1;

        if (params.isIncrease) {
            // include idle assets for increasing collateral
            params.collateralDeltaAmount = idleCollateralAmount();
            if (params.collateralDeltaAmount > 0) {
                if (params.collateralDeltaAmount < increaseCollateralMin()) {
                    revert Errors.InvalidCollateralRequest(params.collateralDeltaAmount, true);
                }
                _transferToAgent(params.collateralDeltaAmount);
            }
            if (params.sizeDeltaInTokens > 0) {
                if (params.collateralDeltaAmount == 0 && positionNetBalance() == 0) {
                    revert Errors.InvalidSizeRequest(params.sizeDeltaInTokens, true);
                }
                if (params.sizeDeltaInTokens < increaseSizeMin()) {
                    revert Errors.InvalidSizeRequest(params.sizeDeltaInTokens, true);
                }
            }

            emit RequestIncreasePosition(params.collateralDeltaAmount, params.sizeDeltaInTokens, round);
        } else {
            if (params.collateralDeltaAmount > 0) {
                if (params.collateralDeltaAmount < decreaseCollateralMin()) {
                    revert Errors.InvalidCollateralRequest(params.collateralDeltaAmount, false);
                }
            }
            if (params.sizeDeltaInTokens > 0) {
                if (params.sizeDeltaInTokens < decreaseSizeMin()) {
                    revert Errors.InvalidSizeRequest(params.sizeDeltaInTokens, false);
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

    /// @dev Reports the state of the hedge position.
    function reportState(uint256 sizeInTokens, uint256 netBalance, uint256 markPrice) external onlyAgent {
        // increments round
        // stores position state in the current round
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        uint256 round = $.currentRound + 1;

        // check if there is pending request from position manager
        uint256 _lastedRequestRound = $.lastRequestRound;
        if (_lastedRequestRound != 0 && !$.requests[_lastedRequestRound].isReported) {
            revert Errors.ProcessingRequest();
        }

        PositionState memory state;
        state.sizeInTokens = sizeInTokens;
        state.netBalance = netBalance;
        state.markPrice = markPrice;
        state.timestamp = block.timestamp;

        $.positionStates[round] = state;
        $.currentRound = round;

        emit ReportState(state.sizeInTokens, state.netBalance, state.markPrice, state.timestamp);
    }

    /// @dev Reports the state of the hedge position while calling the strategy's callback functions
    /// if there is a position adjustment request from the strategy.
    function reportStateAndExecuteRequest(
        uint256 sizeInTokens,
        uint256 netBalance,
        uint256 markPrice,
        AdjustPositionPayload memory params
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
            $.pendingCollateralIncrease = 0;
        } else {
            if (params.collateralDeltaAmount > 0) {
                _transferFromAgent(params.collateralDeltaAmount);
            }

            // replace collateralDeltaAmount with idleCollateralAmount if requested amount is bigger than it
            uint256 _idleCollateralAmount = idleCollateralAmount();
            if (_idleCollateralAmount < $.requests[requestRound].request.collateralDeltaAmount) {
                params.collateralDeltaAmount = _idleCollateralAmount;
            }
        }

        $.positionStates[round] = state;
        $.currentRound = round;

        RequestInfo storage requestInfo = $.requests[requestRound];
        if (!requestInfo.isReported) {
            requestInfo.response = params;
            requestInfo.responseRound = round;
            requestInfo.responseTimestamp = block.timestamp;
            requestInfo.isReported = true;

            IBasisStrategy($.strategy).afterAdjustPosition(params);
        } else {
            revert Errors.NoActiveRequests();
        }

        emit ReportState(state.sizeInTokens, state.netBalance, state.markPrice, state.timestamp);

        emit ReportRequest(
            requestRound, round, params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease
        );
    }

    /// @dev Returns the last request that was requested from strategy.
    function getLastRequest() external view returns (RequestInfo memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.requests[$.lastRequestRound];
    }

    /*//////////////////////////////////////////////////////////////
                            AGENT LOGIC
    //////////////////////////////////////////////////////////////*/

    function _transferToAgent(uint256 amount) internal {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.pendingCollateralIncrease += amount;
        IERC20($.collateralToken).transfer($.agent, amount);

        emit AgentTransfer(msg.sender, amount, true);
    }

    function _transferFromAgent(uint256 amount) internal {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        IERC20($.collateralToken).transferFrom($.agent, address(this), amount);

        emit AgentTransfer(msg.sender, amount, false);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION STATE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHedgeManager
    function positionNetBalance() public view virtual override returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        PositionState memory state = $.positionStates[$.currentRound];
        uint256 initialNetBalance = state.netBalance + $.pendingCollateralIncrease + idleCollateralAmount();

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

    /// @dev Returns the current state of position.
    function currentPositionState() public view returns (PositionState memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.positionStates[$.currentRound];
    }

    /// @inheritdoc IHedgeManager
    function currentLeverage() public view returns (uint256 leverage) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        PositionState memory state = $.positionStates[$.currentRound];
        uint256 initialNetBalance = state.netBalance + $.pendingCollateralIncrease;

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

        leverage = netBalance > 0 ? positionValue.mulDiv(Constants.FLOAT_PRECISION, netBalance) : 0;
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of OffChainConfig smart contract.
    function config() public view returns (IOffChainConfig) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return IOffChainConfig($.config);
    }

    /// @notice The address of agent.
    function agent() public view returns (address) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.agent;
    }

    /// @notice The address of oracle smart contract.
    function oracle() public view returns (address) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.oracle;
    }

    /// @notice The last request round.
    function lastRequestRound() public view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.lastRequestRound;
    }

    /// @notice The current round which is increased by reporting state.
    function currentRound() public view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.currentRound;
    }

    /// @notice The position state at a specific round.
    function positionState(uint256 round) public view returns (PositionState memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.positionStates[round];
    }

    /// @notice The pending collateral amount that is transferred to agent to increase collateral, but not reported by agent.
    function pendingCollateralIncrease() public view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.pendingCollateralIncrease;
    }

    /// @notice The request info at a specific round.
    function requests(uint256 round) public view returns (RequestInfo memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.requests[round];
    }

    /// @inheritdoc IHedgeManager
    function positionSizeInTokens() public view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.positionStates[$.currentRound].sizeInTokens;
    }

    /// @inheritdoc IHedgeManager
    function needKeep() public pure virtual returns (bool) {
        return false;
    }

    /// @inheritdoc IHedgeManager
    function keep() public pure {}

    /// @inheritdoc IHedgeManager
    function increaseCollateralMin() public view returns (uint256) {
        return config().increaseCollateralMin();
    }

    /// @inheritdoc IHedgeManager
    function increaseSizeMin() public view returns (uint256) {
        uint256 min = config().increaseSizeMin();
        min = min == 0 ? 0 : IOracle(oracle()).convertTokenAmount(collateralToken(), indexToken(), min);
        return min;
    }

    /// @inheritdoc IHedgeManager
    function decreaseCollateralMin() public view returns (uint256) {
        return config().decreaseCollateralMin();
    }

    /// @inheritdoc IHedgeManager
    function decreaseSizeMin() public view returns (uint256) {
        uint256 min = config().decreaseSizeMin();
        min = min == 0 ? 0 : IOracle(oracle()).convertTokenAmount(collateralToken(), indexToken(), min);
        return min;
    }

    /// @inheritdoc IHedgeManager
    function limitDecreaseCollateral() public view returns (uint256) {
        return config().limitDecreaseCollateral();
    }

    /// @inheritdoc IHedgeManager
    function collateralToken() public view returns (address) {
        return _getOffChainPositionManagerStorage().collateralToken;
    }

    /// @inheritdoc IHedgeManager
    function indexToken() public view returns (address) {
        return _getOffChainPositionManagerStorage().indexToken;
    }

    /// @notice The balance of collateral asset of this position manager.
    function idleCollateralAmount() public view returns (uint256) {
        return IERC20(collateralToken()).balanceOf(address(this));
    }
}
