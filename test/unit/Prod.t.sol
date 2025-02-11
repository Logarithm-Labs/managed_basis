// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {DataProvider} from "src/DataProvider.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ArbGasInfoMock} from "test/mock/ArbGasInfoMock.sol";
import {ArbSysMock} from "test/mock/ArbSysMock.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";

contract ProdTest is Test {
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    address constant hlOperator = 0xC3AcB9dF13095E7A27919D78aD8323CF7717Bb16;
    address constant sender = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    LogarithmVault hlVault = LogarithmVault(Arb.VAULT_HL_USDC_DOGE);
    BasisStrategy constant hlStrategy = BasisStrategy(Arb.STRATEGY_HL_USDC_DOGE);
    DataProvider constant dataProvider = DataProvider(Arb.DATA_PROVIDER);
    OffChainPositionManager constant hlPositionManager = OffChainPositionManager(Arb.HEDGE_MANAGER_HL_USDC_DOGE);

    UpgradeableBeacon strategyBeacon = UpgradeableBeacon(Arb.BEACON_STRATEGY);
    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    string constant rpcUrl = "https://arb-mainnet.g.alchemy.com/v2/PeyMa7ljzBjqJxkH6AnLfVH8zRWOtE1n";

    bytes call_data =
        hex"000000000000000000000000000000000000000000000000000000000d693a40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000";
    bytes32 request = 0x3c2a45c9fa3439fdc17b5bb4ac31bd9926877f3e44ae24741f232b87df204c6a;

    function test_replay_deutilize() public {
        vm.createSelectFork(rpcUrl, 271867714);

        address _arbsys = address(new ArbSysMock());
        address _arbgasinfo = address(new ArbGasInfoMock());
        vm.etch(address(100), _arbsys.code);
        vm.etch(address(108), _arbgasinfo.code);

        (, uint256 deutilization) = hlStrategy.pendingUtilizations();
        console.log("deutilization", deutilization);
        (uint256 amount, ISpotManager.SwapType swapType, bytes memory swapData) =
            abi.decode(call_data, (uint256, ISpotManager.SwapType, bytes));
        console.log("amount", amount);
        vm.startPrank(hlOperator);
        hlStrategy.deutilize(amount, swapType, swapData);
        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(hlStrategy));
        _logState(state);
    }

    function test_replay_utilize() public {
        vm.createSelectFork(rpcUrl);

        address _arbsys = address(new ArbSysMock());
        address _arbgasinfo = address(new ArbGasInfoMock());
        vm.etch(address(100), _arbsys.code);
        vm.etch(address(108), _arbgasinfo.code);

        (uint256 utilization,) = hlStrategy.pendingUtilizations();
        console.log("utilization", utilization);
        (uint256 amount, ISpotManager.SwapType swapType, bytes memory swapData) =
            abi.decode(call_data, (uint256, ISpotManager.SwapType, bytes));
        console.log("amount", amount);
        vm.startPrank(hlOperator);
        hlStrategy.utilize(amount, swapType, swapData);

        vm.startPrank(0xC539cB358a58aC67185BaAD4d5E3f7fCfc903700);
        address(0xB0Fc2a48b873da40e7bc25658e5E6137616AC2Ee).call(
            hex"7ebc83f79b2c0ff49fa6b229412b47efbbe517a1e3a124178da3fdb1c475a0530a2280180000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000000200000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e5831000000000000000000000000000000000000000000000000000000000000000200000000000000000000000083cbb05aa78014305194450c4aadac887fe5df7f00000000000000000000000083cbb05aa78014305194450c4aadac887fe5df7f00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000044000000000000000000000000000000000000000000000000000000000000003e00006f100c86a0007ed73322d6e26606c9985fd511be9d92cf5af6b3dda8143c7000000000000000000000000000000000000000000000000000000001eb4f416000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000000000000000000000000000000000000000030001010100010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120000362205e10b3a147d02792eccee483dca6c7b44ecce7012cb8c6e0b68b3ae900000000000000000000000000000000000000000000000000000000672c49a100000000000000000000000000000000000000000000000000000000672c49a1000000000000000000000000000000000000000000000000000066584a2626dc000000000000000000000000000000000000000000000000005af9beaaefbf4c00000000000000000000000000000000000000000000000000000000672d9b2100000000000000000000000000000000000000000000009a2849a0084eabab0000000000000000000000000000000000000000000000009a2813375ab0e5c00000000000000000000000000000000000000000000000009a2bda43cfe4c240000000000000000000000000000000000000000000000000000000000000000006036e0b653f5d1ef864272a7241b43aea6abe73ef7322b1fca37e1b2aaf6fdd9fdb07eeba1faa7852e02686f5776cd0f906947190ed62b36e1b86741b78b7db77f2651dcb6a29907180a649af22aaa35c97e7b234e0c193258ee672c7150b20ea52ab8b8c8da7530d5c6bc9a7e4ad6929742882847f5471a27e862d01b1ec525de4e82a868b97d412a6032f3465dda99dbe4f334ee51bb76a93afad86d3f7b35e59b6cba2a488168f0b3ad9655ed0bd46c616413d3fdb4589e9995f7f42deab00000000000000000000000000000000000000000000000000000000000000000650b3559eab7342cfb631e46450d8c489c917b7cc64143f38db24cd128bcd9ba739ecf1806acba7716b3345938cb7658cb4457eb013636b78d262685422b520ad47868969d8645a4be92ea63454a19ee6987666c17394d9e70fef84084c39323719767c05dd84ead599f673805ef66ce75209f70b6c14d4bd4ec63872cf018f2959d931a5e1decea3456c8401bb97cf9fbaba9afda24a614b157c9162f261dfc02c580c4ee1b714ac109fbd4e0f32b10c54ef2ab5041a551bb9369ace215220a000000000000000000000000000000000000000000000000000000000000003e000064c28ccf99cc505d648ffcbc4c2c613859826fd4552841a6822b51800d961000000000000000000000000000000000000000000000000000000001dff4a01000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000003000100010100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd99200000000000000000000000000000000000000000000000000000000672c49a100000000000000000000000000000000000000000000000000000000672c49a100000000000000000000000000000000000000000000000000006658436fd11c000000000000000000000000000000000000000000000000005af8fc7d6c949000000000000000000000000000000000000000000000000000000000672d9b210000000000000000000000000000000000000000000000000de0456eecee28000000000000000000000000000000000000000000000000000de009e5d4e220000000000000000000000000000000000000000000000000000de04c1296d650000000000000000000000000000000000000000000000000000000000000000006921d650a03704724ca595152c3dcba38aff1a4d311b0cecf36dd6be31d26b622eadd06b7b6a1da3ea37411adcdb1e87548d8eb4ec3776844c9b29f57597dddf4686b370205e3aaa050d7c7f7bee3cd92724cd3071359309d6b3c6ba0663a5a41fdfedb950bf029cfd1403c50da7bdb545e1336ee1c2972ed990c5e27fc3bfbdacfc053acae21c611d87efe3778c7501601ebaf399151a7c8e6bedab913df77e47654bc9368a0d15dc21306f77bc8b70b2a645b6979d2d9e2606f89fb4d14b14f00000000000000000000000000000000000000000000000000000000000000065c344f67bdab837517a76802bca2b58fb7c3d4a7b5a3ff81540307c87c00371b751bb787c0ce7f1c96a0209207cdc202b5e938f96cb605c2bc79a3f591ed395014418a83e0f04d903ee06ecbcbde7b7587e2077bb363f3d41915ea36379f361f0b654a6534cc050628e6a407ec29b4a26671a7d13ba2d5e6c32334ae0bfbdf00362d33c2f757085c8ca6b330e66d7457a1af7cfa0203b686f5ad2462d48d2b794c671077a37493f49e99f040c3061361a302061f292326e41e7392aaa0377c95"
        );
    }

    function test_getState() public {
        vm.createSelectFork(rpcUrl);
        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(hlStrategy));
        _logState(state);
        // DataProvider.GmxPositionInfo memory info = dataProvider.getGmxPositionInfo(hlStrategy.hedgeManager());
    }

    function _logState(DataProvider.StrategyState memory state) internal view {
        // log all strategy state
        console.log("strategyStatus: ", state.strategyStatus);
        console.log("totalSupply: ", state.totalSupply);
        console.log("totalAssets: ", state.totalAssets);
        console.log("utilizedAssets: ", state.utilizedAssets);
        console.log("idleAssets: ", state.idleAssets);
        console.log("assetBalance: ", state.assetBalance);
        console.log("productBalance: ", state.productBalance);
        console.log("productValueInAsset: ", state.productValueInAsset);
        console.log("assetsToWithdraw: ", state.assetsToWithdraw);
        console.log("assetsToClaim: ", state.assetsToClaim);
        console.log("totalPendingWithdraw: ", vm.toString(state.totalPendingWithdraw));
        console.log("pendingUtilization: ", state.pendingUtilization);
        console.log("pendingDeutilization: ", state.pendingDeutilization);
        console.log("accRequestedWithdrawAssets: ", state.accRequestedWithdrawAssets);
        console.log("processedWithdrawAssets: ", state.processedWithdrawAssets);
        console.log("positionNetBalance: ", state.positionNetBalance);
        console.log("positionLeverage: ", state.positionLeverage);
        console.log("positionSizeInTokens: ", state.positionSizeInTokens);
        console.log("positionSizeInAsset: ", state.positionSizeInAsset);
        console.log("upkeepNeeded: ", state.upkeepNeeded);
        console.log("rebalanceUpNeeded: ", state.rebalanceUpNeeded);
        console.log("rebalanceDownNeeded: ", state.rebalanceDownNeeded);
        console.log("deleverageNeeded: ", state.deleverageNeeded);
        console.log("rehedgeNeeded: ", state.rehedgeNeeded);
        console.log("hedgeManagerKeepNeeded: ", state.hedgeManagerKeepNeeded);
        console.log("processingRebalanceDown: ", state.processingRebalanceDown);
        console.log("strategyPaused: ", state.strategyPaused);
        console.log("vaultPaused: ", state.vaultPaused);
    }
}
