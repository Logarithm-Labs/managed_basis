// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IAggregationRouter {

    struct SwapDescription {
        address srcToken;
        address dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function swap(
        address executor,
        SwapDescription calldata desc,
        bytes calldata data
    ) external returns (uint256 returnAmount, uint256 spentAmount);
}


