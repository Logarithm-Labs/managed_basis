// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Constants} from "../utils/Constants.sol";

library CommonLib {
    using Math for uint256;
    using SafeCast for uint256;

    function _capAmount(uint256 amount, uint256 cap) internal pure returns (uint256) {
        return amount > cap ? cap : amount;
    }

    function _maxUtilization(uint256 _idleAssets, uint256 _utilizedAssets, uint256 _maxUtilizePct)
        internal
        pure
        returns (uint256)
    {
        return (_idleAssets + _utilizedAssets).mulDiv(_maxUtilizePct, Constants.FLOAT_PRECISION);
    }

    function _clamp(uint256 min, uint256 value) internal pure returns (uint256 result) {
        result = value < min ? 0 : value;
    }

    /// @dev Should be called under the condition that denominator != 0.
    /// Note: check if response of position adjustment is in the allowed deviation
    function _checkDeviation(uint256 numerator, uint256 denominator, uint256 deviationThreshold)
        internal
        pure
        returns (bool exceedsThreshold, int256 deviation)
    {
        deviation = numerator.toInt256() - denominator.toInt256();
        exceedsThreshold = (deviation < 0 ? uint256(-deviation) : uint256(deviation)).mulDiv(
            Constants.FLOAT_PRECISION, denominator
        ) > deviationThreshold;
        return (exceedsThreshold, deviation);
    }
}
