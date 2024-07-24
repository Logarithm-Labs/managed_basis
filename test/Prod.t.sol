// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {AccumulatedBasisStrategy} from "src/AccumulatedBasisStrategy.sol";

contract ProdTest is Test {
    AccumulatedBasisStrategy public strategy = AccumulatedBasisStrategy(0xC69c6A3228BB8EE5Bdd0C656eEA43Bf8713B0740);

    function test_run() public {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        (bool statusKeep, bool hedgeDeviation, bool decreaseCollateral) = abi.decode(performData, (bool, bool, bool));
        console.log("upkeepNeeded", upkeepNeeded);
        console.log("statusKeep", statusKeep);
        console.log("hedgeDeviation", hedgeDeviation);
        console.log("decreaseCollateral", decreaseCollateral);
    }
}
