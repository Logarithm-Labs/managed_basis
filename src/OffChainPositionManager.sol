// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

contract OffChainPositionManager {
    struct PositionState {
        uint256 positionSizeInTokens;
        uint256 positionNetBalance;
        uint256 lastHedgeExecutionPrice;
        uint256 lastSpotExecutionPrice;
        uint256 timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.OffChainPositionManager
    struct OffChainPositionManagerStorage {
        // configuration
        address _strategy;
        address _indexToken;
        address _collateralToken;
        bool _isLong;
        uint256 _maxClaimableFundingShare;
        uint256 _maxHedgeDeviation;
        // position state
        uint256 _currentRound;
        mapping(uint256 => PositionState) _positionStates;
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

    event IncreasePositionSize(uint256 sizeDeltaIntokens);

    event DecreasePositionSize(uint256 sizeDeltaIntokens);

    event IncreasePositionCollateral(uint256 collateralAmount);

    event DecreasePositionCollateral(uint256 collateralAmount);

    event ReportState(
        uint256 positionSizeInTokens,
        uint256 positionNetBalance,
        uint256 lastHedgeExecutionPrice,
        uint256 lastSpotExecutionPrice,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                        POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function increasePositionSize(uint256 sizeDeltaIntokens) public {
        emit IncreasePositionSize(sizeDeltaIntokens);
    }

    function decreasePositionSize(uint256 sizeDeltaIntokens) public {
        emit DecreasePositionSize(sizeDeltaIntokens);
    }

    function increasePositionCollateral(uint256 collateralAmount) public {
        emit IncreasePositionCollateral(collateralAmount);
    }

    function decreasePositionCollateral(uint256 collateralAmount) public {
        emit DecreasePositionCollateral(collateralAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION STATE LOGIC
    //////////////////////////////////////////////////////////////*/

    function reportState(uint256 positionSizeInTokens, uint256 positionNetBalance, uint256 lastHedgeExecutionPrice)
        public
    {
        OffChainPositionManagerStorage storage $ = _getOffChainPositionManagerStorage();

        PositionState storage state = $._positionStates[$._currentRound];
        state.positionSizeInTokens = positionSizeInTokens;
        state.positionNetBalance = positionNetBalance;
        state.lastHedgeExecutionPrice = lastHedgeExecutionPrice;
        state.timestamp = block.timestamp;

        emit ReportState(
            state.positionSizeInTokens,
            state.positionNetBalance,
            state.lastHedgeExecutionPrice,
            state.lastSpotExecutionPrice,
            state.timestamp
        );
    }
}
