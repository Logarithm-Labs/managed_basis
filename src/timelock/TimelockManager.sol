// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {DirectFunctionSelectors} from "./DirectFunctions.sol";

/// @title TimelockManager
/// @author
/// @notice Manages the timelock for administrative transactions within the protocol.
/// @dev Has the owner role for all protocol smart contracts.
/// The owner of this contract is a multi-signature wallet.
contract TimelockManager is Ownable2Step {
    uint256 constant GRACE_PERIOD = 14 days;
    uint256 constant MINIMUM_DELAY = 1 days;
    uint256 constant MAXIMUM_DELAY = 30 days;

    /// @notice Time delay for timelocked transactions.
    uint256 public delay;

    /// @notice Mapping of transaction hashes to their queued status.
    mapping(bytes32 => bool) public queuedTransactions;

    /// @notice Mapping of function selectors to their direct execution availability.
    mapping(bytes4 selector => bool isDirect) public isDirectSelector;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when the delay is updated.
    /// @param newDelay The new delay value in seconds.
    event DelayUpdated(uint256 indexed newDelay);

    /// @dev Emitted when a timelocked transaction is canceled.
    /// @param txHash The hash of the transaction.
    /// @param target The address of the target contract.
    /// @param value The amount of Ether to send.
    /// @param signature The function signature to call.
    /// @param data The calldata to send.
    /// @param eta The timestamp at which the timelocked transaction can be executed.
    event TransactionCanceled(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    /// @dev Emitted when a timelocked transaction is executed.
    /// @param txHash The hash of the transaction.
    /// @param target The address of the target contract.
    /// @param value The amount of Ether to send.
    /// @param signature The function signature to call.
    /// @param data The calldata to send.
    /// @param eta The timestamp at which the timelocked transaction can be executed.
    event TransactionExecuted(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    /// @dev Emitted when a timelocked transaction is queued.
    /// @param txHash The hash of the transaction.
    /// @param target The address of the target contract.
    /// @param value The amount of Ether to send.
    /// @param signature The function signature to call.
    /// @param data The calldata to send.
    /// @param eta The timestamp at which the timelocked transaction can be executed.
    event TransactionQueued(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TM__SmallerThanMinDelay();
    error TM__BiggerThanMaxDelay();
    error TM__EtaMustSatisfyDelay();
    error TM__NotQueued();
    error TM__NotSurpassedTimeLock();
    error TM__Stable();
    error TM__ExecutionReverted();

    constructor(address _owner, uint256 _delay) Ownable(_owner) {
        _setDelay(_delay);

        // register direct functions
        isDirectSelector[DirectFunctionSelectors.PAUSE] = true;
        isDirectSelector[DirectFunctionSelectors.PAUSE_WITH_OPTION] = true;
        isDirectSelector[DirectFunctionSelectors.SET_DEPOSIT_LIMITS] = true;
        isDirectSelector[DirectFunctionSelectors.SET_ENTRY_COST] = true;
        isDirectSelector[DirectFunctionSelectors.SET_EXIT_COST] = true;
        isDirectSelector[DirectFunctionSelectors.SET_PRIORITY_PROVIDER] = true;
        isDirectSelector[DirectFunctionSelectors.SET_WHITELIST_PROVIDER] = true;
        isDirectSelector[DirectFunctionSelectors.SHUTDOWN] = true;
        isDirectSelector[DirectFunctionSelectors.STOP] = true;
        isDirectSelector[DirectFunctionSelectors.UNPAUSE] = true;
    }

    function _setDelay(uint256 _delay) internal {
        if (_delay < MINIMUM_DELAY) revert TM__SmallerThanMinDelay();
        if (_delay > MAXIMUM_DELAY) revert TM__BiggerThanMaxDelay();
        delay = _delay;
        emit DelayUpdated(_delay);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                        ADMIN EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setDelay(uint256 newDelay) external onlyOwner {
        _setDelay(newDelay);
    }

    function queueTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        onlyOwner
        returns (bytes32)
    {
        if (eta < block.timestamp + delay) revert TM__EtaMustSatisfyDelay();

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = true;

        emit TransactionQueued(txHash, target, value, signature, data, eta);
        return txHash;
    }

    function cancelTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        onlyOwner
    {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = false;

        emit TransactionCanceled(txHash, target, value, signature, data, eta);
    }

    /// @notice Executes a queued transaction or none-timelocked transaction.
    /// @dev When executing a none-timelocked transaction, `eta` can be any value.
    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        payable
        onlyOwner
        returns (bytes memory)
    {
        bytes4 selector = bytes4(keccak256(bytes(signature)));
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));

        if (!isDirectSelector[selector]) {
            if (!queuedTransactions[txHash]) revert TM__NotQueued();
            if (block.timestamp < eta) revert TM__NotSurpassedTimeLock();
            if (block.timestamp > eta + GRACE_PERIOD) revert TM__Stable();

            queuedTransactions[txHash] = false;
        }

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(selector, data);
        }

        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        if (!success) revert TM__ExecutionReverted();

        emit TransactionExecuted(txHash, target, value, signature, data, eta);

        return returnData;
    }
}
