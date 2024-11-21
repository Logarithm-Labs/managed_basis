// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {MessagingFee, OFTReceipt, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {IStargate, Ticket} from "src/externals/stargate/interfaces/IStargate.sol";

library StargateUtils {
    using OptionsBuilder for bytes;

    function prepareTakeTaxi(
        address _stargate,
        uint32 _dstEid,
        uint256 _amount,
        address _composer,
        uint128 _composeCallGasLimit,
        uint128 _composeCallValue,
        bytes memory _composeMsg
    ) internal view returns (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) {
        bytes memory extraOptions = _composeMsg.length > 0
            ? OptionsBuilder.newOptions().addExecutorLzComposeOption(0, _composeCallGasLimit, _composeCallValue)
            : bytes("");

        sendParam = SendParam({
            dstEid: _dstEid,
            to: addressToBytes32(_composer),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: extraOptions,
            composeMsg: _composeMsg,
            oftCmd: ""
        });

        IStargate stargate = IStargate(_stargate);

        (,, OFTReceipt memory receipt) = stargate.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        messagingFee = stargate.quoteSend(sendParam, false);
        valueToSend = messagingFee.nativeFee;

        if (stargate.token() == address(0x0)) {
            valueToSend += sendParam.amountLD;
        }
    }

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }
}
