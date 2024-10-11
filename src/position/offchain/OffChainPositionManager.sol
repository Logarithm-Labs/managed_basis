// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPositionManager} from "src/position/IPositionManager.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IOffChainConfig} from "src/position/offchain/IOffChainConfig.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract OffChainPositionManager is Initializable, OwnableUpgradeable, IPositionManager {
    using SafeCast for uint256;
    using Math for uint256;

    struct PositionState {
        uint256 sizeInTokens;
        uint256 netBalance;
        uint256 markPrice;
        uint256 timestamp;
    }

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
        address config_,
        address strategy_,
        address agent_,
        address oracle_,
        address indexToken_,
        address collateralToken_,
        bool isLong_
    ) external initializer {
        __Ownable_init(msg.sender);
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.config = config_;
        $.strategy = strategy_;
        $.agent = agent_;
        $.oracle = oracle_;
        $.indexToken = indexToken_;
        $.collateralToken = collateralToken_;
        $.isLong = isLong_;

        // strategy is trusted
        IERC20(collateralToken_).approve(strategy_, type(uint256).max);
    }

    function setAgent(address _agent) external onlyOwner {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.agent = _agent;
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

    function adjustPosition(AdjustPositionPayload memory params) external {
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
                (uint256 minIncreaseCollateral, uint256 maxIncreaseCollateral) = config().increaseCollateralMinMax();
                if (
                    params.collateralDeltaAmount < minIncreaseCollateral
                        || params.collateralDeltaAmount > maxIncreaseCollateral
                ) {
                    revert Errors.InvalidCollateralRequest(params.collateralDeltaAmount, true);
                }
                _transferToAgent(params.collateralDeltaAmount);
            }
            if (params.sizeDeltaInTokens > 0) {
                (uint256 minIncreaseSize, uint256 maxIncreaseSize) = increaseSizeMinMax();
                if (params.sizeDeltaInTokens < minIncreaseSize || params.sizeDeltaInTokens > maxIncreaseSize) {
                    revert Errors.InvalidCollateralRequest(params.sizeDeltaInTokens, true);
                }
            }

            emit RequestIncreasePosition(params.collateralDeltaAmount, params.sizeDeltaInTokens, round);
        } else {
            if (params.collateralDeltaAmount > 0) {
                (uint256 minDecreaseCollateral, uint256 maxDecreaseCollateral) = config().decreaseCollateralMinMax();
                if (
                    params.collateralDeltaAmount < minDecreaseCollateral
                        || params.collateralDeltaAmount > maxDecreaseCollateral
                ) {
                    revert Errors.InvalidCollateralRequest(params.collateralDeltaAmount, false);
                }
            }
            if (params.sizeDeltaInTokens > 0) {
                (uint256 minDecreaseSize, uint256 maxDecreaseSize) = decreaseSizeMinMax();
                if (params.sizeDeltaInTokens < minDecreaseSize || params.sizeDeltaInTokens > maxDecreaseSize) {
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
        $.currentRound = round;

        emit ReportState(state.sizeInTokens, state.netBalance, state.markPrice, state.timestamp);
    }

    function reportStateAndExecuteRequest(
        uint256 sizeInTokens,
        uint256 netBalance,
        uint256 markPrice,
        AdjustPositionPayload calldata params
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
        }

        AdjustPositionPayload memory response = AdjustPositionPayload({
            sizeDeltaInTokens: params.sizeDeltaInTokens,
            collateralDeltaAmount: params.collateralDeltaAmount,
            isIncrease: params.isIncrease
        });

        $.positionStates[round] = state;
        $.currentRound = round;

        RequestInfo storage requestInfo = $.requests[requestRound];
        if (!requestInfo.isReported) {
            requestInfo.response = response;
            requestInfo.responseRound = round;
            requestInfo.responseTimestamp = block.timestamp;
            requestInfo.isReported = true;

            IBasisStrategy($.strategy).afterAdjustPosition(params);
        }

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

        leverage = netBalance > 0 ? positionValue.mulDiv(PRECISION, netBalance) : 0;
    }

    /*//////////////////////////////////////////////////////////////
                        EXERNAL STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function config() public view returns (IOffChainConfig) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return IOffChainConfig($.config);
    }

    function agent() external view returns (address) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.agent;
    }

    function oracle() external view returns (address) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.oracle;
    }

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

    function increaseCollateralMinMax() external view returns (uint256 min, uint256 max) {
        return config().increaseCollateralMinMax();
    }

    function increaseSizeMinMax() public view returns (uint256 min, uint256 max) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        address asset = $.collateralToken;
        address product = $.indexToken;
        IOracle _oracle = IOracle($.oracle);

        (min, max) = config().increaseSizeMinMax();

        (min, max) = (
            min == 0 ? 0 : _oracle.convertTokenAmount(asset, product, min),
            max == type(uint256).max ? type(uint256).max : _oracle.convertTokenAmount(asset, product, max)
        );

        return (min, max);
    }

    function decreaseCollateralMinMax() external view returns (uint256 min, uint256 max) {
        return config().decreaseCollateralMinMax();
    }

    function decreaseSizeMinMax() public view returns (uint256 min, uint256 max) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        address asset = $.collateralToken;
        address product = $.indexToken;
        IOracle _oracle = IOracle($.oracle);

        (min, max) = config().decreaseSizeMinMax();

        (min, max) = (
            min == 0 ? 0 : _oracle.convertTokenAmount(asset, product, min),
            max == type(uint256).max ? type(uint256).max : _oracle.convertTokenAmount(asset, product, max)
        );

        return (min, max);
    }

    function limitDecreaseCollateral() external view returns (uint256) {
        return config().limitDecreaseCollateral();
    }
}
