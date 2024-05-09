// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IAggregationRouter {

    type Address is uint256;

    struct SwapDescription {
        address srcToken;
        address dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function unoswap(Address token, uint256 amount, uint256 minReturn, Address dex) external returns(uint256 returnAmount); // 83800a8e

    function unoswapTo(Address to, Address token, uint256 amount, uint256 minReturn, Address dex) external returns(uint256 returnAmount); // e2c95c82

    function ethUnoswap(uint256 minReturn, Address dex) external payable returns(uint256 returnAmount); // a76dfc3b

    function ethUnoswapTo(Address to, uint256 minReturn, Address dex) external payable returns(uint256 returnAmount); // 175accdc

    function unoswap2(Address token, uint256 amount, uint256 minReturn, Address dex, Address dex2) external returns(uint256 returnAmount); // 8770ba91

    function unoswapTo2(Address to, Address token, uint256 amount, uint256 minReturn, Address dex, Address dex2) external returns(uint256 returnAmount); // ea76dddf

    function ethUnoswap2(uint256 minReturn, Address dex, Address dex2) external payable returns(uint256 returnAmount); // 89af926a

    function ethUnoswapTo2(Address to, uint256 minReturn, Address dex, Address dex2) external payable returns(uint256 returnAmount); // 0f449d71

    function unoswap3(Address token, uint256 amount, uint256 minReturn, Address dex, Address dex2, Address dex3) external returns(uint256 returnAmount); // 19367472

    function unoswapTo3(Address to, Address token, uint256 amount, uint256 minReturn, Address dex, Address dex2, Address dex3) external returns(uint256 returnAmount); // f7a70056

    function ethUnoswap3(uint256 minReturn, Address dex, Address dex2, Address dex3) external payable returns(uint256 returnAmount); // 188ac35d

    function ethUnoswapTo3(Address to, uint256 minReturn, Address dex, Address dex2, Address dex3) external payable returns(uint256 returnAmount); // 493189f0

    function swap(
        address executor,
        SwapDescription calldata desc,
        bytes calldata data
    ) external returns (uint256 returnAmount, uint256 spentAmount); // 07ed2379
}


