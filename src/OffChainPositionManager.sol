// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import "src/interfaces/IManagedBasisStrategy.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Constants} from "src/libraries/utils/Constants.sol";

import {console2 as console} from "forge-std/console2.sol";

contract OffChainPositionManager is IPositionManager, UUPSUpgradeable, OwnableUpgradeable {
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
        mapping(uint256 => RequestParams) requests;
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
        uint256 targetLeverage_,
        bool isLong_
    ) external initializer {
        __Ownable_init(msg.sender);
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        $.strategy = strategy_;
        $.agent = agent_;
        $.oracle = oracle_;
        $.indexToken = indexToken_;
        $.collateralToken = collateralToken_;
        $.targetLeverage = targetLeverage_;
        $.isLong = isLong_;

        // strategy is trusted
        IERC20(collateralToken_).approve(strategy_, type(uint256).max);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event RequestIncreasePositionSize(uint256 sizeDeltaInTokens, uint256 round);
    event IncreasePositionSize(uint256 sizeDeltaIntokens, int256 executionCost, uint256 round);

    event RequestDecreasePositionSize(uint256 sizeDeltaInTokens, uint256 round);
    event DecreasePositionSize(uint256 sizeDeltaIntokens, int256 executionCost, uint256 round);

    event RequestIncreasePositionCollateral(uint256 collateralAmount, uint256 round);
    event IncreasePositionCollateral(uint256 collateralAmount, uint256 round);

    event RequestDecreasePositionCollateral(uint256 collateralAmount, uint256 round);
    event DecreasePositionCollateral(uint256 collateralAmount, uint256 round);

    event AgentTransfer(address indexed caller, uint256 amount, bool toAgent);

    event ReportState(uint256 positionSizeInTokens, uint256 positionNetBalance, uint256 markPrice, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAgent() {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        _;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE
    //////////////////////////////////////////////////////////////*/

    function apiVersion() external view returns (string memory) {
        return "0.0.0";
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function adjustPosition(RequestParams memory params) external {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if (msg.sender != $.strategy) {
            revert Errors.CallerNotStrategy();
        }

        uint256 round = $.currentRound + 1;

        $.requests[round] = RequestParams({
            sizeDeltaInTokens: params.sizeDeltaInTokens,
            collateralDeltaAmount: params.collateralDeltaAmount,
            isIncrease: params.isIncrease
        });

        if (params.isIncrease) {
            if (params.collateralDeltaAmount > 0) {
                emit RequestIncreasePositionCollateral(params.collateralDeltaAmount, round);
            }
            if (params.sizeDeltaInTokens > 0) {
                emit RequestIncreasePositionSize(params.sizeDeltaInTokens, round);
            }
        } else {
            if (params.collateralDeltaAmount > 0) {
                emit RequestDecreasePositionCollateral(params.collateralDeltaAmount, round);
            }
            if (params.sizeDeltaInTokens > 0) {
                emit RequestDecreasePositionSize(params.sizeDeltaInTokens, round);
            }
        }

        $.positionStates[round] = $.positionStates[round - 1];
        $.currentRound = round;
    }

    function reportStateAndExecuteRequest(
        uint256 sizeInTokens,
        uint256 netBalance,
        uint256 markPrice,
        PositionManagerCallbackParams calldata params
    ) external onlyAgent {
        // TODO: add validation for prices (difference between mark price, execution price and oracle price should be within the threshold)
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        uint256 round = $.currentRound;

        // if agent submits state without request, it means that it is regular state update
        // no need to report back to strategy
        PositionState storage state = $.positionStates[round];
        state.sizeInTokens = sizeInTokens;
        state.netBalance = netBalance;
        state.markPrice = markPrice;
        state.timestamp = block.timestamp;
        if (params.isIncrease) {
            $.pendingCollateralIncrease -= params.collateralDeltaAmount;
        } else {
            if (params.collateralDeltaAmount > 0) {
                _transferFromAgent(params.collateralDeltaAmount);
            }
        }
        $.currentRound = round;

        IManagedBasisStrategy($.strategy).afterAdjustPosition(params);

        emit ReportState(state.sizeInTokens, state.netBalance, state.markPrice, state.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            AGENT LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferToAgent() external onlyAgent {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        if (msg.sender != $.agent) {
            revert Errors.CallerNotAgent();
        }

        RequestParams memory request = $.requests[$.currentRound];
        if (!request.isIncrease || request.collateralDeltaAmount == 0) {
            revert Errors.InvalidActiveRequestType();
        }

        $.pendingCollateralIncrease += request.collateralDeltaAmount;

        _transferToAgent(request.collateralDeltaAmount);
    }

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
        IERC20($.collateralToken).transfer(msg.sender, amount);

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
        IERC20($.collateralToken).transferFrom(msg.sender, address(this), amount);

        emit AgentTransfer(msg.sender, amount, false);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION STATE LOGIC
    //////////////////////////////////////////////////////////////*/

    function positionNetBalance() external view virutal returns (uint256 netBalance) {
        (netBalance,) = _positionNetBalance();
    }

    function currentLeverage() external view virtual returns (uint256) {
        (uint256 netBalance, uint256 positionValue) = _positionNetBalance();
        return positionValue.mulDiv(y, denominator);
    }

    function _positionNetBalance() public view virtual returns (uint256 netBalance, uint256 positionValue) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        PositionState memory state = $.positionStates[$.currentRound];
        uint256 initialNetBalance =
            state.netBalance + $.pendingCollateralIncrease + IERC20($.collateralToken).balanceOf(address(this));

        positionValue = IOracle($.oracle).convertTokenAmount($.indexToken, $.collateralToken, state.sizeInTokens);
        uint256 positionSize =
            state.sizeInTokens.mulDiv(state.markPrice, 10 ** uint256(IERC20Metadata($.indexToken).decimals()));
        int256 virtualPnl = $.isLong
            ? positionValue.toInt256() - positionSize.toInt256()
            : positionSize.toInt256() - positionValue.toInt256();

        if (virtualPnl >= 0) {
            netBalance = initialNetBalance + uint256(virtualPnl);
        } else if (initialNetBalance > uint256(-virtualPnl)) {
            netBalance = initialNetBalance - uint256(-virtualPnl);
        } else {
            netBalance = 0;
        }
    }

    function currentPositionState() public view returns (PositionState memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.positionStates[$.currentRound];
    }

    /*//////////////////////////////////////////////////////////////
                        EXERNAL STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

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

    function requests(uint256 round) external view returns (RequestParams memory) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.requests[round];
    }

    function positionSizeInTokens() external view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
        return $.positionStates[$.currentRound].sizeInTokens;
    }

    function currentLeverage() external view returns (uint256) {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();
    }
}
