// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract AssetValueTransmitter is Initializable {
    struct AssetValueTransmitterStorage {
        uint256 decimalConversionRate;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.AssetValueTransmitter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AssetValueTransmitterStorageLocation =
        0xffa42cc651855e3cdbd9f807a4ac01c247d708aaa78a63ef65214d3514c36800;

    function _getAssetValueTransmitterStorage() private pure returns (AssetValueTransmitterStorage storage $) {
        assembly {
            $.slot := AssetValueTransmitterStorageLocation
        }
    }

    error InvalidLocalDecimals();

    function __AssetValueTransmitter_init(address asset) internal {
        uint8 localDecimals = IERC20Metadata(asset).decimals();
        if (localDecimals < sharedDecimals()) revert InvalidLocalDecimals();
        _getAssetValueTransmitterStorage().decimalConversionRate = 10 ** (localDecimals - sharedDecimals());
    }

    function decimalConversionRate() public view returns (uint256) {
        return _getAssetValueTransmitterStorage().decimalConversionRate;
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
        uint256 _decimalConversionRate = decimalConversionRate();
        return (_amountLD / _decimalConversionRate) * _decimalConversionRate;
    }

    /// @dev Internal function to convert an amount from shared decimals into local decimals.
    /// @param _amountSD The amount in shared decimals.
    /// @return amountLD The amount in local decimals.
    function _toLD(uint64 _amountSD) internal view virtual returns (uint256 amountLD) {
        return _amountSD * decimalConversionRate();
    }

    /// @dev Internal function to convert an amount from local decimals into shared decimals.
    /// @param _amountLD The amount in local decimals.
    /// @return amountSD The amount in shared decimals.
    function _toSD(uint256 _amountLD) internal view virtual returns (uint64 amountSD) {
        return uint64(_amountLD / decimalConversionRate());
    }
}
