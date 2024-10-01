// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";

contract InchTest is Test {
    using stdStorage for StdStorage;

    address public owner;
    BasisStrategy public strategy;
    LogarithmOracle public oracle;

    address public USDC = ArbiAddresses.USDC;
    address public usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    address public asset = ArbiAddresses.USDC; // USDC
    address public product = ArbiAddresses.WETH; // WETH
    address public assetPriceFeed = ArbiAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address public productPriceFeed = ArbiAddresses.CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed
    uint256 public entryCost = 0.01 ether;
    uint256 public exitCost = 0.02 ether;
    bool public isLong = false;

    string public slippage = "1";
    string public pathLocation = "router/path.json";
    string public inchPyLocation = "router/inch.py";
    string public inchJsonLocation = "router/inch.json";

    function setUp() public {
        owner = vm.addr(1);
        vm.startPrank(owner);

        // deploy oracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        oracle = LogarithmOracle(oracleProxy);

        // deploy strategy
        address strategyImpl = address(new BasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector, asset, product, owner, oracle, entryCost, exitCost, isLong
                )
            )
        );
        strategy = BasisStrategy(strategyProxy);

        // set oracle price feed
        address[] memory assets = new address[](2);
        address[] memory feeds = new address[](2);
        assets[0] = asset;
        assets[1] = product;
        feeds[0] = assetPriceFeed;
        feeds[1] = productPriceFeed;

        oracle.setPriceFeeds(assets, feeds);
    }

    function test_inchUtilize() public {
        uint256 amount = 1000 * 1e6;
        writeTokenBalance(address(strategy), asset, amount);

        bytes memory data = generateInchCallData(asset, product, amount);

        // call utilize
        strategy.utilize(amount, BasisStrategy.SwapType.INCH_V6, data);
        console.log("amountOut: ", IERC20(product).balanceOf(address(strategy)));
    }

    function test_inchDeutilize() public {
        uint256 amount = 1e18;
        writeTokenBalance(address(strategy), product, amount);

        bytes memory data = generateInchCallData(product, asset, amount);

        // call deutilize
        strategy.deutilize(amount, BasisStrategy.SwapType.INCH_V6, data);
        console.log("amountOut: ", IERC20(asset).balanceOf(address(strategy)));
    }

    function writeTokenBalance(address who, address token, uint256 amt) internal {
        if (token == USDC) {
            vm.startPrank(usdcWhale);
            IERC20(asset).transfer(who, amt);
            vm.startPrank(owner);
        } else {
            stdstore.target(token).sig(IERC20(token).balanceOf.selector).with_key(who).checked_write(amt);
        }
        assertEq(IERC20(token).balanceOf(who), amt);
    }

    function generateInchCallData(address tokenIn, address tokenOut, uint256 amount)
        internal
        returns (bytes memory data)
    {
        string memory pathObj = "path_obj";
        vm.serializeAddress(pathObj, "src", tokenIn);
        vm.serializeAddress(pathObj, "dst", tokenOut);
        vm.serializeUint(pathObj, "amount", amount);
        vm.serializeAddress(pathObj, "from", address(strategy));
        string memory finalPathJson = vm.serializeString(pathObj, "slippage", slippage);
        vm.writeJson(finalPathJson, pathLocation);

        // get inch calldata
        string[] memory inputs = new string[](4);
        inputs[0] = "python3";
        inputs[1] = inchPyLocation;
        inputs[2] = "--json_data_file";
        inputs[3] = pathLocation;

        data = vm.ffi(inputs);
    }
}
