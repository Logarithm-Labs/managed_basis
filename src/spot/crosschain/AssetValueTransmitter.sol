// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract AssetValueTransmitter {
    uint256 public immutable decimalConversionRate;

    error InvalidLocalDecimals();

    constructor(address asset) {
        uint8 localDecimals = IERC20Metadata(asset).decimals();
        if (localDecimals < sharedDecimals()) revert InvalidLocalDecimals();
        decimalConversionRate = 10 ** (localDecimals - sharedDecimals());
    }

    /// @dev Retrieves the shared decimals of the transmitter.
    /// @return The shared decimals of the transmitter.
    ///
    /// @dev Sets an implicit cap on the amount of tokens, over uint64.max() will need some sort of outbound cap / totalSupply cap
    /// Lowest common decimal denominator between chains.
    /// Defaults to 6 decimal places to provide up to 18,446,744,073,709.551615 units (max uint64).
    /// For tokens exceeding this totalSupply(), they will need to override the sharedDecimals function with something smaller.
    /// ie. 4 sharedDecimals would be 1,844,674,407,370,955.1615
    function sharedDecimals() public view virtual returns (uint8) {
        return 6;
    }

    /// @dev Internal function to remove dust from the given local decimal amount.
    /// @param _amountLD The amount in local decimals.
    /// @return amountLD The amount after removing dust.
    ///
    /// @dev Prevents the loss of dust when moving amounts between chains with different decimals.
    /// @dev eg. uint(123) with a conversion rate of 100 becomes uint(100).
    function _removeDust(uint256 _amountLD) internal view virtual returns (uint256 amountLD) {
        return (_amountLD / decimalConversionRate) * decimalConversionRate;
    }

    /// @dev Internal function to convert an amount from shared decimals into local decimals.
    /// @param _amountSD The amount in shared decimals.
    /// @return amountLD The amount in local decimals.
    function _toLD(uint64 _amountSD) internal view virtual returns (uint256 amountLD) {
        return _amountSD * decimalConversionRate;
    }

    /// @dev Internal function to convert an amount from local decimals into shared decimals.
    /// @param _amountLD The amount in local decimals.
    /// @return amountSD The amount in shared decimals.
    function _toSD(uint256 _amountLD) internal view virtual returns (uint64 amountSD) {
        return uint64(_amountLD / decimalConversionRate);
    }
}
