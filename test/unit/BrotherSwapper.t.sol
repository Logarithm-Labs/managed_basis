// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {ForkTest} from "test/base/ForkTest.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {LogarithmMessenger} from "src/messenger/LogarithmMessenger.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";

contract BrotherSwapperTest is ForkTest {
    address owner = makeAddr("owner");

    address constant ARBI_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant ARBI_STARTGATE = 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3;
    uint32 constant DST_EID = 232;
    bytes32 constant dstSpotManager = bytes32(abi.encodePacked("dstSpotManager"));

    uint256 TEN_THOUSAND_USDC = 10_000 * USDC_PRECISION;
    BrotherSwapper swapper;
    LogarithmMessenger messenger;

    function setUp() public {
        _forkArbitrum(0);
        messenger = new LogarithmMessenger(ARBI_ENDPOINT, owner);
        swapper =
            new BrotherSwapper(USDC, WETH, ARBI_ENDPOINT, ARBI_STARTGATE, address(messenger), dstSpotManager, DST_EID);

        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNISWAPV3_WETH_USDC;
        pathWeth[2] = WETH;

        swapper.initialize(owner, pathWeth);
    }

    function test_buy(uint256 assets) public {
        assets = bound(assets, 0, TEN_THOUSAND_USDC);
        bytes memory composeMsg = abi.encode(200_000, ISpotManager.SwapType.MANUAL, "");
        bytes memory message = OFTComposeMsgCodec.encode(0, 1, assets, composeMsg);
        vm.startPrank(ARBI_ENDPOINT);
        swapper.lzCompose(ARBI_STARTGATE, bytes32(0), message, address(0), "");

        assertEq(IERC20(USDC).balanceOf(address(swapper)), 0);
        assertGt(IERC20(WETH).balanceOf(address(swapper)), 0);
    }

    function test_sell(uint256 products) public {
        products = bound(products, 0, 10 ether);
        uint64 productsSD = uint64(products / swapper.decimalConversionRate());
        _writeTokenBalance(address(swapper), WETH, products);
        assertEq(IERC20(WETH).balanceOf(address(swapper)), products);
        bytes memory payload = abi.encode(200_000, productsSD, ISpotManager.SwapType.MANUAL, "");
        vm.startPrank(address(messenger));
        swapper.receiveMessage(dstSpotManager, payload);
        assertEq(IERC20(USDC).balanceOf(address(swapper)), 0);
        assertEq(IERC20(WETH).balanceOf(address(swapper)), 0);
    }
}
