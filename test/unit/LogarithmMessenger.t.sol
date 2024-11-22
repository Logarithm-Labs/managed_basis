// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {LogarithmMessenger, SendParams} from "src/messenger/LogarithmMessenger.sol";
import {MockMessageRecipient} from "test/mock/MockMessageRecipient.sol";

contract LogarithmMessengerTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 aEid = 1;
    uint32 bEid = 2;

    LogarithmMessenger aMessenger;
    LogarithmMessenger bMessenger;
    MockMessageRecipient recipient;

    function setUp() public virtual override {
        super.setUp();

        setUpEndpoints(2, LibraryType.UltraLightNode);

        address[] memory uas = setupOApps(type(LogarithmMessenger).creationCode, 1, 2);
        aMessenger = LogarithmMessenger(payable(uas[0]));
        bMessenger = LogarithmMessenger(payable(uas[1]));

        recipient = new MockMessageRecipient();

        vm.deal(address(this), 1000 ether);
    }

    function test_sendUint64(uint64 amount, uint128 value) public {
        value = uint128(bound(value, 0, 1 ether));
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, value);
        SendParams memory params = SendParams({
            dstEid: bEid,
            value: value,
            receiver: addressToBytes32(address(recipient)),
            payload: abi.encode(amount),
            lzReceiveOption: options
        });
        (uint256 nativeFee,) = aMessenger.quote(address(this), params);
        aMessenger.sendMessage(params);

        // verify packet to bMessenger manually
        verifyPackets(bEid, address(bMessenger));

        assertEq(recipient.amount(), amount, "amount");
        assertEq(recipient.caller(), address(aMessenger), "caller");
        assertEq(recipient.sender(), address(this), "sender");
        assertEq(address(recipient).balance, value, "value");
    }
}
