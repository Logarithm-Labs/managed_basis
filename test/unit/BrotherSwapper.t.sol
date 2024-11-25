// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test, console, stdStorage, StdStorage} from "forge-std/Test.sol";
import {MockMessenger} from "test/mock/MockMessenger.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {Constants} from "src/libraries/utils/Constants.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {BscAddresses} from "script/utils/BscAddresses.sol";

contract BrotherSwapperTest is Test {
    using stdStorage for StdStorage;

    address owner = makeAddr("owner");

    address constant BSC_ENDPOINT = BscAddresses.LZ_V2_ENDPOINT;
    address constant BSC_STARTGATE = BscAddresses.STARGATE_POOL_USDC;
    uint32 constant DST_EID = 30101;
    bytes32 constant dstSpotManager = bytes32(abi.encodePacked("dstSpotManager"));

    uint256 DOGE_DECIMAL = 8;
    uint256 USDC_DECIMAL = 18;
    uint256 TEN_THOUSAND_USDC = 10_000 * 10 ** USDC_DECIMAL;

    BrotherSwapper swapper;
    MockMessenger messenger;
    address beacon;
    GasStation gasStation;

    function setUp() public {
        vm.createSelectFork("https://bsc-dataseed.binance.org");
        messenger = new MockMessenger();
        gasStation = DeployHelper.deployGasStation(owner);
        beacon = DeployHelper.deployBeacon(address(new BrotherSwapper()), owner);
        address[] memory path = new address[](5);
        path[0] = BscAddresses.USDC;
        path[1] = BscAddresses.PCS_V3_POOL_WBNB_USDC;
        path[2] = BscAddresses.WBNB;
        path[3] = BscAddresses.PCS_V3_POOL_DOGE_WBNB;
        path[4] = BscAddresses.DOGE;

        swapper = DeployHelper.deployBrotherSwapper(
            DeployHelper.DeployBrotherSwapperParams({
                beacon: beacon,
                owner: owner,
                asset: BscAddresses.USDC,
                product: BscAddresses.DOGE,
                endpoint: BSC_ENDPOINT,
                stargate: BSC_STARTGATE,
                messenger: address(messenger),
                gasStation: address(gasStation),
                dstSpotManager: dstSpotManager,
                dstEid: DST_EID,
                assetToProductSwapPath: path
            })
        );
        vm.startPrank(owner);
        gasStation.registerManager(address(swapper), true);
        vm.deal(address(gasStation), 0.5 ether);
    }

    function test_buy_atomic() public {
        uint256 assets = TEN_THOUSAND_USDC;
        _writeTokenBalance(address(swapper), BscAddresses.USDC, assets);
        bytes memory swapData;
        uint128 gaslimit = 200_000;
        bytes memory composeMsg =
            abi.encodePacked(dstSpotManager, abi.encode(gaslimit, ISpotManager.SwapType.MANUAL, swapData));
        bytes memory message = OFTComposeMsgCodec.encode(0, 1, assets, composeMsg);
        vm.startPrank(BSC_ENDPOINT);
        swapper.lzCompose(BSC_STARTGATE, bytes32(0), message, address(0), "");

        assertEq(IERC20(BscAddresses.USDC).balanceOf(address(swapper)), 0, "asset balance");
        assertGt(IERC20(BscAddresses.DOGE).balanceOf(address(swapper)), 0, "product balance");
    }

    function test_buy(uint256 assets) public {
        assets = bound(assets, 10, TEN_THOUSAND_USDC);
        _writeTokenBalance(address(swapper), BscAddresses.USDC, assets);
        bytes memory swapData;
        uint128 gaslimit = 200_000;
        bytes memory composeMsg =
            abi.encodePacked(dstSpotManager, abi.encode(gaslimit, ISpotManager.SwapType.MANUAL, swapData));
        bytes memory message = OFTComposeMsgCodec.encode(0, 1, assets, composeMsg);
        vm.startPrank(BSC_ENDPOINT);
        swapper.lzCompose(BSC_STARTGATE, bytes32(0), message, address(0), "");

        assertEq(IERC20(BscAddresses.USDC).balanceOf(address(swapper)), 0, "asset balance");
        assertGt(IERC20(BscAddresses.DOGE).balanceOf(address(swapper)), 0, "product balance");
    }

    function test_sell(uint256 products) public {
        products = bound(products, 1e13, 10 ether);
        uint64 productsSD = uint64(products / swapper.decimalConversionRate());
        uint256 productsLD = productsSD * swapper.decimalConversionRate();
        _writeTokenBalance(address(swapper), BscAddresses.DOGE, productsLD);
        assertEq(IERC20(BscAddresses.DOGE).balanceOf(address(swapper)), productsLD);
        bytes memory swapData;
        bytes memory payload = abi.encode(uint128(200_000), productsSD, ISpotManager.SwapType.MANUAL, swapData);
        vm.startPrank(address(messenger));
        swapper.receiveMessage(dstSpotManager, payload);
        assertGt(IERC20(BscAddresses.USDC).balanceOf(address(swapper)), 0, "asset balance");
        assertEq(IERC20(BscAddresses.DOGE).balanceOf(address(swapper)), 0, "product balance");
    }

    function test_sell_atomic() public {
        uint256 products = 10000 * 10 ** DOGE_DECIMAL;
        uint64 productsSD = uint64(products / swapper.decimalConversionRate());
        uint256 productsLD = productsSD * swapper.decimalConversionRate();
        _writeTokenBalance(address(swapper), BscAddresses.DOGE, productsLD);
        assertEq(IERC20(BscAddresses.DOGE).balanceOf(address(swapper)), productsLD);
        bytes memory swapData;
        bytes memory payload = abi.encode(uint128(200_000), productsSD, ISpotManager.SwapType.MANUAL, swapData);
        vm.startPrank(address(messenger));
        swapper.receiveMessage(dstSpotManager, payload);
        assertGt(IERC20(BscAddresses.USDC).balanceOf(address(swapper)), 0, "asset balance");
        assertEq(IERC20(BscAddresses.DOGE).balanceOf(address(swapper)), 0, "product balance");
    }

    function _writeTokenBalance(address who, address token, uint256 amt) internal {
        stdstore.target(token).sig(IERC20(token).balanceOf.selector).with_key(who).checked_write(amt);
        assertEq(IERC20(token).balanceOf(who), amt);
    }
}
