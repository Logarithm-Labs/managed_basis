// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./AddressLib.sol";

library ProtocolLib {
    using AddressLib for Address;

    enum Protocol {
        UniswapV2,
        UniswapV3,
        Curve
    }

    uint256 private constant _PROTOCOL_OFFSET = 253;
    uint256 private constant _WETH_UNWRAP_FLAG = 1 << 252;
    uint256 private constant _WETH_NOT_WRAP_FLAG = 1 << 251;
    uint256 private constant _USE_PERMIT2_FLAG = 1 << 250;

    function protocol(Address self) internal pure returns(Protocol) {
        // there is no need to mask because protocol is stored in the highest 3 bits
        return Protocol((Address.unwrap(self) >> _PROTOCOL_OFFSET));
    }

    function shouldUnwrapWeth(Address self) internal pure returns(bool) {
        return self.getFlag(_WETH_UNWRAP_FLAG);
    }

    function shouldWrapWeth(Address self) internal pure returns(bool) {
        return !self.getFlag(_WETH_NOT_WRAP_FLAG);
    }

    function usePermit2(Address self) internal pure returns(bool) {
        return self.getFlag(_USE_PERMIT2_FLAG);
    }

    function addressForPreTransfer(Address self) internal view returns(address) {
        if (protocol(self) == Protocol.UniswapV2) {
            return self.get();
        }
        return address(this);
    }
}