// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OApp} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder, ExecutorOptions} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import {MsgCodec} from "./MsgCodec.sol";
import {ILogarithmMessenger, SendParams} from "./ILogarithmMessenger.sol";
import {IMessageRecipient} from "./IMessageRecipient.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";

contract LogarithmMessenger is OApp, ILogarithmMessenger {
    using MsgCodec for bytes;

    uint32 public eid;
    mapping(address account => bool) public isAuthorized;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Authorized(address indexed caller, address indexed account, bool authorized);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error LM__WITHDRAW_FAIL();
    error LM__INVALID_AUTHORIZE();
    error LM__AUTH_FAILED();
    error LM__INSUFFICIENT_VALUE();

    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {
        eid = ILayerZeroEndpointV2(_endpoint).eid();
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN LOGIC
    //////////////////////////////////////////////////////////////*/

    function authorize(address account) external onlyOwner {
        if (!isAuthorized[account]) {
            isAuthorized[account] = true;
            emit Authorized(_msgSender(), account, true);
        } else {
            revert LM__INVALID_AUTHORIZE();
        }
    }

    function unauthorize(address account) external onlyOwner {
        if (isAuthorized[account]) {
            isAuthorized[account] = false;
            emit Authorized(_msgSender(), account, false);
        } else {
            revert LM__INVALID_AUTHORIZE();
        }
    }

    function withdraw(address payable _to, uint256 _amount) external onlyOwner {
        (bool success,) = _to.call{value: _amount}("");
        if (!success) {
            revert LM__WITHDRAW_FAIL();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MESSAGING LOGIC
    //////////////////////////////////////////////////////////////*/

    function quote(address sender, SendParams calldata params)
        public
        view
        returns (uint256 nativeFee, uint256 lzTokenFee)
    {
        MessagingFee memory fee = _quote(
            params.dstEid,
            MsgCodec.encode(sender, params.receiver, params.value, params.payload),
            params.lzReceiveOption,
            false
        );
        return (fee.nativeFee, fee.lzTokenFee);
    }

    /// @dev Can be called only by authorized accounts.
    function sendMessage(SendParams calldata params) external payable {
        _authCaller(_msgSender());
        _lzSend(
            params.dstEid,
            MsgCodec.encode(_msgSender(), params.receiver, params.value, params.payload),
            params.lzReceiveOption,
            MessagingFee(msg.value, 0),
            payable(_msgSender())
        );
    }

    function _lzReceive(
        Origin calldata, /*_origin*/
        bytes32, /*_guid*/
        bytes calldata _message,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) internal override {
        // validate vale
        if (msg.value < _message.value()) {
            revert LM__INSUFFICIENT_VALUE();
        }
        address receiver = AddressCast.bytes32ToAddress(_message.receiver());
        IMessageRecipient(receiver).receiveMessage{value: msg.value}(_message.sender(), _message.payload());
    }

    /*//////////////////////////////////////////////////////////////
                                  AUTH
    //////////////////////////////////////////////////////////////*/
    function _authCaller(address caller) internal view {
        if (!isAuthorized[caller]) {
            revert LM__AUTH_FAILED();
        }
    }
}
