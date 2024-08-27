// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./IBaseOrderUtils.sol";

interface IExchangeRouter {
    function createOrder(IBaseOrderUtils.CreateOrderParams calldata params) external payable returns (bytes32);

    function sendWnt(address receiver, uint256 amount) external payable;

    function sendTokens(address token, address receiver, uint256 amount) external payable;

    function sendNativeToken(address receiver, uint256 amount) external payable;

    function claimFundingFees(address[] memory markets, address[] memory tokens, address receiver)
        external
        payable
        returns (uint256[] memory);

    function claimCollateral(
        address[] memory markets,
        address[] memory tokens,
        uint256[] memory timeKeys,
        address receiver
    ) external payable returns (uint256[] memory);

    function depositHandler() external view returns (address);

    function withdrawalHandler() external view returns (address);

    function orderHandler() external view returns (address);

    function dataStore() external view returns (address);

    function router() external view returns (address);
}
