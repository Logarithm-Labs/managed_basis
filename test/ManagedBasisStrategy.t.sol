// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {MockExchange} from "test/mock/MockExchange.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ManagedBasisStrategyTest is Test {
    using Math for uint256;
    using stdStorage for StdStorage;

    address public owner;
    address public depositor;
    ManagedBasisStrategy public strategy;
    MockExchange public mockExchange;
    LogarithmOracle public oracle;

    uint256 depositAmount = 1000 * 1e6;

    address public USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    address public asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address public product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address public assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address public productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed
    uint256 public entryCost = 0.01 ether;
    uint256 public exitCost = 0.02 ether;
    bool public isLong = false;

    uint256 targetLeverage = 3 ether;

    string public slippage = "1";
    string public pathLocation = "router/path.json";
    string public inchPyLocation = "router/inch.py";
    string public inchJsonLocation = "router/inch.json";

    function setUp() public {
        owner = vm.addr(1);
        vm.startPrank(owner);

        depositor = vm.addr(2);
        writeTokenBalance(depositor, asset, depositAmount);

        // deploy oracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        oracle = LogarithmOracle(oracleProxy);

        // deploy strategy
        address strategyImpl = address(new ManagedBasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    ManagedBasisStrategy.initialize.selector, asset, product, owner, oracle, entryCost, exitCost, isLong
                )
            )
        );
        strategy = ManagedBasisStrategy(strategyProxy);

        // set oracle price feed
        address[] memory assets = new address[](2);
        address[] memory feeds = new address[](2);
        assets[0] = asset;
        assets[1] = product;
        feeds[0] = assetPriceFeed;
        feeds[1] = productPriceFeed;

        oracle.setPriceFeeds(assets, feeds);

        // deploy mock exchange
        mockExchange = new MockExchange(address(strategy), address(oracle), product, asset, isLong);

        // grant operator role to owner
        strategy.grantRole(strategy.OPERATOR_ROLE(), owner);
        assertEq(strategy.hasRole(strategy.OPERATOR_ROLE(), owner), true);

        // grant opertor role to mock exchange
        strategy.grantRole(strategy.OPERATOR_ROLE(), address(mockExchange));
        assertEq(strategy.hasRole(strategy.OPERATOR_ROLE(), address(mockExchange)), true);
    }

    function test_firstDeposit() public {
        vm.startPrank(depositor);
        uint256 shares = strategy.deposit(depositAmount, depositor);

        assertEq(shares, depositAmount);
        assertEq(strategy.totalSupply(), shares);
        assertEq(strategy.balanceOf(depositor), shares);
        assertEq(strategy.totalAssets(), depositAmount);
        assertEq(strategy.totalAssets(), strategy.idleAssets());
        vm.startPrank(owner);
    }

    function test_firstDepositAndExecute() public {
        test_firstDeposit();

        uint256 amountToUtilize = strategy.idleAssets().mulDiv(targetLeverage, targetLeverage + 1 ether);
        uint256 amountToRequest = strategy.idleAssets() - amountToUtilize;

        // reques asset from strategy
        mockExchange.requestAsset(amountToRequest);
        assertEq(IERC20(asset).balanceOf(address(mockExchange)), amountToRequest);

        // get inch swap data
        bytes memory data = generateInchCallData(asset, product, amountToUtilize);

        // call utilize
        uint256 amountOut = mockExchange.utilize(amountToUtilize, data);
        assertEq(IERC20(product).balanceOf(address(strategy)), amountOut);
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
