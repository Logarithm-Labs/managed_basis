// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract MockPriceFeed {
    uint8 public decimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    function setOracleData(
        uint80 _roundId,
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _answeredInRound,
        uint8 _decimals
    ) external {
        roundId = _roundId;
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
        decimals = _decimals;
    }

    function updatePrice(int256 _answer) external {
        answer = _answer;
    }

    function setUpdatedAt(uint256 _timestamp) external {
        startedAt = _timestamp;
        updatedAt = _timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _strartedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }
}
