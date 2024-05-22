// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "src/interfaces/IOracle.sol";
import "src/ManagedBasisStrategy.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract MockExchange {
    using SafeCast for uint256;
    using SafeCast for int256;

    ManagedBasisStrategy public strategy;
    IOracle public oracle;
    address public indexToken;
    address public collateralToken;
    bool public isLong;
    uint256 public currentRound;
    mapping(uint256 => ManagedBasisStrategy.PositionState) public positionStates;

    constructor(address _strategy, address _oracle, address _indexToken, address _collateralToken, bool _isLong) {
        strategy = ManagedBasisStrategy(_strategy);
        oracle = IOracle(_oracle);
        indexToken = _indexToken;
        collateralToken = _collateralToken;
        isLong = _isLong;
    }

    function increasePosition(uint256 sizeDeltaInTokens, uint256 collateralDelta) external {
        ManagedBasisStrategy.PositionState memory state0 = positionStates[currentRound];
        int256 pnl = _getVirtualPnl();
        uint256 netBalance = state0.netBalance + collateralDelta;
        netBalance = pnl > 0 ? netBalance + pnl.toUint256() : netBalance - (-pnl).toUint256();
        ManagedBasisStrategy.PositionState memory state1 = ManagedBasisStrategy.PositionState({
            netBalance: netBalance,
            sizeInTokens: state0.sizeInTokens + sizeDeltaInTokens,
            markPrice: oracle.getAssetPrice(indexToken),
            timestamp: block.timestamp
        });
        currentRound++;
        positionStates[currentRound] = state1;
    }

    function decreasePosition(uint256 sizeDeltaInTokens, uint256 collateralDelta) external {
        ManagedBasisStrategy.PositionState memory state0 = positionStates[currentRound];
        int256 pnl = _getVirtualPnl();
        uint256 netBalance = state0.netBalance - collateralDelta;
        netBalance = pnl > 0 ? netBalance + pnl.toUint256() : netBalance - (-pnl).toUint256();
        ManagedBasisStrategy.PositionState memory state1 = ManagedBasisStrategy.PositionState({
            netBalance: netBalance,
            sizeInTokens: state0.sizeInTokens - sizeDeltaInTokens,
            markPrice: oracle.getAssetPrice(indexToken),
            timestamp: block.timestamp
        });
        currentRound++;
        positionStates[currentRound] = state1;
    }

    function reportState() public {
        ManagedBasisStrategy.PositionState memory state0 = positionStates[currentRound];
        strategy.reportState(state0); 
    }

    function executeWithdrawal(bytes32 requestId, uint256 amountExecuted) public {
        bytes32[] memory requestIds = new bytes32[](1);
        requestIds[0] = requestId;
        uint256[] memory amountsExecuted = new uint256[](1);
        amountsExecuted[0] = amountExecuted;

        strategy.executeWithdrawals(requestIds, amountsExecuted);
    }

    function executeWithdrawals(bytes32[] calldata requestIds, uint256[] calldata amountsExecuted) public {
        strategy.executeWithdrawals(requestIds, amountsExecuted);
    }

    function reportStateAndExecuteWithdrawal(bytes32 requestId, uint256 amountExecuted) external {
        ManagedBasisStrategy.PositionState memory state0 = positionStates[currentRound];
        bytes32[] memory requestIds = new bytes32[](1);
        requestIds[0] = requestId;
        uint256[] memory amountsExecuted = new uint256[](1);
        amountsExecuted[0] = amountExecuted;

        strategy.reportStateAndExecuteWithdrawals(state0, requestIds, amountsExecuted);
    }

    function reportStateAndExecuteWithdrawals(bytes32[] calldata requestIds, uint256[] calldata amountsExecuted) external {
        ManagedBasisStrategy.PositionState memory state0 = positionStates[currentRound];
        strategy.reportStateAndExecuteWithdrawals(state0, requestIds, amountsExecuted);

    }

    function _getVirtualPnl() internal view returns (int256 pnl) {
        ManagedBasisStrategy.PositionState memory state = positionStates[currentRound];
        uint256 price = oracle.getAssetPrice(indexToken);
        uint256 positionValue = state.sizeInTokens * price;
        uint256 positionSize = state.sizeInTokens * state.markPrice;
        pnl = isLong
            ? positionValue.toInt256() - positionSize.toInt256()
            : positionSize.toInt256() - positionValue.toInt256();
    }

    function requestAsset(uint256 amount) external {
        strategy.sendToOperator(amount);
    }

    function utilize(uint256 utilizeAmount, bytes calldata data)
        public
        returns (uint256)
    {
        return strategy.utilize(utilizeAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
    }

    function deutilize(uint256 deutilizeAmount, bytes calldata data)
        public
        returns (uint256)
    {
        return strategy.deutilize(deutilizeAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
    }
    
}