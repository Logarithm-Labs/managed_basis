// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {TimelockManager} from "src/TimelockManager.sol";

contract MockTarget {
    address public lastSender;
    uint256 public lastValue;

    function targetFunction(address sender, uint256 value) external payable {
        lastSender = sender;
        lastValue = value;
    }
}

contract TimelockManagerTest is Test {
    TimelockManager timelockManager;
    MockTarget mockTarget;
    address owner = makeAddr("owner");
    uint256 delay = 1 days;
    uint256 eta = block.timestamp + delay;
    uint256 value = 1 ether;

    function setUp() public {
        timelockManager = new TimelockManager(owner, delay);
        mockTarget = new MockTarget();
    }

    function test_setDelay_cannotSetSmallerThanMin() public {
        vm.startPrank(owner);
        vm.expectRevert(TimelockManager.TM__SmallerThanMinDelay.selector);
        timelockManager.setDelay(0);
    }

    function test_setDelay_cannotSetBiggerThanMax() public {
        vm.startPrank(owner);
        vm.expectRevert(TimelockManager.TM__BiggerThanMaxDelay.selector);
        timelockManager.setDelay(70 days);
    }

    function test_queueTransaction() public {
        vm.startPrank(owner);
        bytes32 txHash = timelockManager.queueTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
        assertTrue(timelockManager.queuedTransactions(txHash), "queued");
    }

    function test_queueTransaction_revert() public {
        vm.startPrank(owner);
        vm.expectRevert(TimelockManager.TM__EtaMustSatisfyDelay.selector);
        timelockManager.queueTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta - 1
        );
    }

    function test_cancelTransaction() public {
        vm.startPrank(owner);
        bytes32 txHash = timelockManager.queueTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
        timelockManager.cancelTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
        assertFalse(timelockManager.queuedTransactions(txHash), "canceled");
    }

    function test_executeTransaction() public {
        vm.startPrank(owner);
        timelockManager.queueTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
        vm.warp(eta);
        timelockManager.executeTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
        assertEq(mockTarget.lastSender(), owner);
        assertEq(mockTarget.lastValue(), value);
    }

    function test_executeTransaction_revert_wrongCalldata() public {
        vm.startPrank(owner);
        timelockManager.queueTransaction(
            address(mockTarget), 0, "targetFunction(uint256)", abi.encode(owner, value), eta
        );
        vm.warp(eta);
        vm.expectRevert(TimelockManager.TM__ExecutionReverted.selector);
        timelockManager.executeTransaction(
            address(mockTarget), 0, "targetFunction(uint256)", abi.encode(owner, value), eta
        );
    }

    function test_executeTransaction_revert_earlierThanEta() public {
        vm.startPrank(owner);
        timelockManager.queueTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
        vm.warp(eta - 1);
        vm.expectRevert(TimelockManager.TM__NotSurpassedTimeLock.selector);
        timelockManager.executeTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
    }

    function test_executeTransaction_revert_notQueued() public {
        vm.startPrank(owner);
        vm.warp(eta);
        vm.expectRevert(TimelockManager.TM__NotQueued.selector);
        timelockManager.executeTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
    }

    function test_executeTransaction_revert_stable() public {
        vm.startPrank(owner);
        timelockManager.queueTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
        vm.warp(eta + 15 days);
        vm.expectRevert(TimelockManager.TM__Stable.selector);
        timelockManager.executeTransaction(
            address(mockTarget), 0, "targetFunction(address,uint256)", abi.encode(owner, value), eta
        );
    }
}
