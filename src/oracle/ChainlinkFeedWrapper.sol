// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ICustomPriceFeed {
    struct RoundData {
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint32 expiresAt;
        int192 price;
        uint80 verifiedInRound;
        bytes signedReport;
    }

    function latestRoundData() external view returns (RoundData memory);
    function latestRound() external view returns (uint80);
    function latestAnswer() external view returns (uint256);
    function getRoundData(uint256 round) external view returns (RoundData memory);
    function decimals() external view returns (uint8);
}

contract ChainlinkFeedWrapper {
    ICustomPriceFeed immutable customPriceFeed;
    uint8 public immutable decimals;

    constructor(address _customPriceFeed) {
        require(_customPriceFeed != address(0));
        customPriceFeed = ICustomPriceFeed(_customPriceFeed);
        decimals = customPriceFeed.decimals();
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = customPriceFeed.latestRound();
        ICustomPriceFeed.RoundData memory roundData = customPriceFeed.latestRoundData();
        answer = roundData.price;
        startedAt = roundData.validFromTimestamp;
        updatedAt = roundData.observationsTimestamp;
        answeredInRound = roundId;
    }
}
