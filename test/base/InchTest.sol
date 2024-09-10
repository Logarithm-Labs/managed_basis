// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ForkTest} from "./ForkTest.sol";

contract InchTest is ForkTest {
    // inch swap data variables
    string constant slippage = "1";
    string constant pathLocation = "router/path.json";
    string constant inchPyLocation = "router/inch.py";
    string constant inchJsonLocation = "router/inch.json";

    function _generateInchCallData(address tokenIn, address tokenOut, uint256 amount, address from)
        internal
        returns (bytes memory data)
    {
        string memory pathObj = "path_obj";
        vm.serializeAddress(pathObj, "src", tokenIn);
        vm.serializeAddress(pathObj, "dst", tokenOut);
        vm.serializeUint(pathObj, "amount", amount);
        vm.serializeAddress(pathObj, "from", from);
        string memory finalPathJson = vm.serializeString(pathObj, "slippage", slippage);
        vm.writeJson(finalPathJson, pathLocation);
        assertTrue(vm.isFile(pathLocation), "invalid path location");

        // get inch calldata
        string[] memory inputs = new string[](4);
        inputs[0] = "python3";
        inputs[1] = inchPyLocation;
        inputs[2] = "--json_data_file";
        inputs[3] = pathLocation;

        data = vm.ffi(inputs);
        vm.sleep(1_000);
        vm.removeFile(pathLocation);
    }
}
