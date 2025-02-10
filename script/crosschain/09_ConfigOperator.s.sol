// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {Arb, Bsc} from "script/utils/ProtocolAddresses.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {BscAddresses} from "script/utils/BscAddresses.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {ILogarithmMessenger} from "src/messenger/ILogarithmMessenger.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";

contract ConfigOperatorScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    address constant gmxOperator = 0x46eC45418cC71df561c676b89b982B1cF52C824C;
    address constant hlOperator = 0xC3AcB9dF13095E7A27919D78aD8323CF7717Bb16;
    address constant agent = 0xA184231aAE8DE21E7FcD962746Ef350CbB650FbD;

    BasisStrategy gmxStrategy = BasisStrategy(Arb.STRATEGY_GMX_USDC_DOGE);
    BasisStrategy hlStrategy = BasisStrategy(Arb.STRATEGY_HL_USDC_DOGE);
    OffChainPositionManager hlManager = OffChainPositionManager(Arb.HL_POSITION_MANAGER_USDC_DOGE);

    function run() public {
        vm.startBroadcast();
        gmxStrategy.setOperator(gmxOperator);
        hlStrategy.setOperator(hlOperator);
        hlManager.setAgent(agent);
    }
}
