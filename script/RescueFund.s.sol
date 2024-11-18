// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GasStation} from "src/gas-station/GasStation.sol";

contract RescueFundScript is Script {
    GasStation public oldGasStation = GasStation(payable(0xB758989eeBB4D5EF2da4FbD6E37f898dd1d49b2a));
    GasStation public newGasStation = GasStation(payable(0xB11d9DBeCe15C9d379D85B93BB7026A6e86Fa45c));

    function run() public {
        vm.startBroadcast();
        uint256 withdrawable = address(oldGasStation).balance;
        oldGasStation.withdraw(withdrawable);
        (bool success,) = address(newGasStation).call{value: 1 wei}("");
        assert(success);
    }
}
