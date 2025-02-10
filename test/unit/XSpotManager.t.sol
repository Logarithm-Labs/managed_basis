// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {ForkTest} from "test/base/ForkTest.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

import {MockOracle} from "test/mock/MockOracle.sol";
import {MockMessenger} from "test/mock/MockMessenger.sol";
import {MockStrategy} from "test/mock/MockStrategy.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";

contract XSpotManagerTest is ForkTest {
    address owner = makeAddr("owner");

    address constant ARBI_ENDPOINT = ArbAddresses.LZ_V2_ENDPOINT;
    address constant ARBI_STARTGATE = ArbAddresses.STARGATE_POOL_USDC;
    uint256 constant chainId = 56;

    uint256 TEN_THOUSAND_USDC = 10_000 * USDC_PRECISION;

    MockStrategy strategy;
    GasStation gasStation;
    XSpotManager spotManager;
    BrotherSwapper swapper;
    MockMessenger messenger;
    MockOracle oracle;
    address asset;
    address product;

    function setUp() public {
        _forkArbitrum(0);
        vm.startPrank(owner);
        oracle = new MockOracle();
        strategy = new MockStrategy(address(oracle));
        gasStation = DeployHelper.deployGasStation(owner);
        messenger = new MockMessenger();
        address beaconSpot = DeployHelper.deployBeacon(address(new XSpotManager()), owner);
        spotManager = DeployHelper.deployXSpotManager(
            DeployHelper.DeployXSpotManagerParams({
                beacon: beaconSpot,
                owner: owner,
                strategy: address(strategy),
                messenger: address(messenger),
                dstChainId: chainId
            })
        );

        asset = strategy.asset();
        product = strategy.product();

        address[] memory pathWeth = new address[](3);
        pathWeth[0] = asset;
        pathWeth[1] = ArbAddresses.UNI_V3_POOL_WETH_USDC;
        pathWeth[2] = product;

        address beaconSwapper = DeployHelper.deployBeacon(address(new BrotherSwapper()), owner);
        swapper = DeployHelper.deployBrotherSwapper(
            DeployHelper.DeployBrotherSwapperParams({
                beacon: beaconSwapper,
                owner: owner,
                asset: asset,
                product: product,
                messenger: address(messenger),
                spotManager: AddressCast.addressToBytes32(address(spotManager)),
                dstChainId: chainId,
                assetToProductSwapPath: pathWeth
            })
        );

        spotManager.setSwapper(AddressCast.addressToBytes32(address(swapper)));

        _writeTokenBalance(address(strategy), asset, TEN_THOUSAND_USDC);
    }

    function test_buy(uint256 amount) public {
        amount = bound(amount, 10, TEN_THOUSAND_USDC);
        vm.startPrank(address(strategy));
        IERC20(asset).transfer(address(spotManager), amount);
        spotManager.buy(amount, ISpotManager.SwapType.MANUAL, "");
        uint256 productBalance = IERC20(product).balanceOf(address(swapper));
        uint256 rate = spotManager.decimalConversionRate();
        uint256 productsLD = productBalance / rate * rate;
        assertGt(productBalance, 0, "productBalance");
        assertEq(strategy.buyAssetDelta(), amount, "buyAssetDelta");
        assertEq(strategy.buyProductDelta(), productsLD, "buyProductDelta");
        assertEq(strategy.timestamp(), block.timestamp, "timestamp");
        assertEq(spotManager.pendingAssets(), 0, "pendingAssets");
        // convert rate between asset and product is 1:1
        assertEq(spotManager.getAssetValue(), productsLD, "getAssetValue");
        assertEq(spotManager.exposure(), productsLD, "exposure");
        assertEq(IERC20(asset).balanceOf(address(spotManager)), 0, "manager asset balance");
        assertEq(IERC20(asset).balanceOf(address(swapper)), 0, "swapper asset balance");
    }

    function test_sell(uint256 amount) public {
        amount = bound(amount, 0.000001 ether, 50 ether);
        _writeTokenBalance(address(swapper), product, amount);
        vm.startPrank(address(strategy));
        spotManager.sell(amount, ISpotManager.SwapType.MANUAL, "");
        uint256 rate = spotManager.decimalConversionRate();
        uint256 productsLD = (amount / rate) * rate;

        uint256 assetBalance = IERC20(asset).balanceOf(address(spotManager));
        assertGt(assetBalance, 0, "asset balance");
        assertEq(strategy.sellAssetDelta(), assetBalance, "asset delta");
        assertEq(strategy.sellProductDelta(), productsLD, "product delta");
        assertEq(strategy.timestamp(), block.timestamp, "timestamp");
        uint256 productBalance = IERC20(product).balanceOf(address(swapper));
        assertEq(amount - productBalance, productsLD, "product balance");
        assertEq(IERC20(asset).balanceOf(address(swapper)), 0, "swapper asset balance");
    }
}
