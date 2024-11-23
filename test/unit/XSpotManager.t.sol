// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {ForkTest} from "test/base/ForkTest.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

import {MockOracle} from "test/mock/MockOracle.sol";
import {MockMessenger} from "test/mock/MockMessenger.sol";
import {MockStrategy} from "test/mock/MockStrategy.sol";

contract XSpotManagerTest is ForkTest {
    address owner = makeAddr("owner");

    bytes32 constant swapper = bytes32(abi.encodePacked("swapper"));
    address constant ARBI_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant ARBI_STARTGATE = 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3;
    uint32 constant DST_EID = 30101;

    uint256 TEN_THOUSAND_USDC = 10_000 * USDC_PRECISION;

    MockStrategy strategy;
    GasStation gasStation;
    XSpotManager spotManager;
    MockMessenger messenger;
    MockOracle oracle;

    function setUp() public {
        _forkArbitrum(0);
        oracle = new MockOracle();
        strategy = new MockStrategy(address(oracle));
        gasStation = DeployHelper.deployGasStation(owner);
        messenger = new MockMessenger();
        spotManager = new XSpotManager(
            address(strategy), address(gasStation), ARBI_ENDPOINT, ARBI_STARTGATE, address(messenger), DST_EID
        );
        spotManager.initialize(owner);
        vm.startPrank(owner);
        spotManager.setSwapper(swapper);
        vm.deal(address(gasStation), 10000 ether);
        gasStation.registerManager(address(spotManager), true);
        _writeTokenBalance(address(strategy), USDC, TEN_THOUSAND_USDC);
    }

    function test_buy_request(uint256 amount) public {
        amount = bound(amount, 10, TEN_THOUSAND_USDC);
        vm.startPrank(address(strategy));
        IERC20(USDC).transfer(address(spotManager), amount);
        spotManager.buy(amount, ISpotManager.SwapType.MANUAL, "");
        assertEq(spotManager.pendingAssets(), amount, "pendingAssets");
        assertEq(spotManager.getAssetValue(), amount, "getAssetValue");
        assertEq(spotManager.exposure(), 0, "exposure");
    }

    function test_buy_response(uint256 amount) public {
        amount = bound(amount, 10, TEN_THOUSAND_USDC);
        vm.startPrank(address(strategy));
        IERC20(USDC).transfer(address(spotManager), amount);
        spotManager.buy(amount, ISpotManager.SwapType.MANUAL, "");
        vm.startPrank(address(messenger));
        uint64 productSD = uint64(USDC_PRECISION); // 6 decimals
        spotManager.receiveMessage(swapper, abi.encode(productSD));
        uint256 productLD = productSD * 1e12; // 18 decimals
        assertEq(strategy.buyAssetDelta(), amount, "buyAssetDelta");
        assertEq(strategy.buyProductDelta(), productLD, "buyProductDelta");
        assertEq(spotManager.pendingAssets(), 0, "pendingAssets");
        // convert rate between asset and product is 1:1
        assertEq(spotManager.getAssetValue(), productLD, "getAssetValue");
        assertEq(spotManager.exposure(), productLD, "exposure");
    }

    function test_sell_request(uint256 amount) public {
        vm.startPrank(address(strategy));
        spotManager.sell(amount, ISpotManager.SwapType.MANUAL, "");
    }

    function test_sell_response(uint256 amount) public {
        vm.startPrank(address(strategy));
        spotManager.sell(amount, ISpotManager.SwapType.MANUAL, "");
        uint64 productSD = uint64(amount / spotManager.decimalConversionRate());
        uint256 assetLD = 100 * 1e16;
        bytes memory composeMsg = abi.encodePacked(swapper, abi.encode(productSD));
        bytes memory message = OFTComposeMsgCodec.encode(0, 1, assetLD, composeMsg);
        vm.startPrank(ARBI_ENDPOINT);
        spotManager.lzCompose(ARBI_STARTGATE, bytes32(0), message, address(0), "");
        assertEq(strategy.sellAssetDelta(), assetLD, "asset delta");
        uint256 productsLD = productSD * spotManager.decimalConversionRate();
        assertEq(strategy.sellProductDelta(), productsLD, "product delta");
    }
}
