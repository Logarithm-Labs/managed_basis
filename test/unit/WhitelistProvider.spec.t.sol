// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";

import {WhitelistProvider} from "src/whitelist/WhitelistProvider.sol";

contract WhitelistProviderSpecTest is Test {
    WhitelistProvider provider;
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public {
        provider = new WhitelistProvider();
        provider.initialize(owner);
    }

    function test_whitelist() public {
        vm.startPrank(owner);
        provider.whitelist(user1);
        assertTrue(provider.isWhitelisted(user1));
        assertFalse(provider.isWhitelisted(user2));
        provider.whitelist(user2);
        assertTrue(provider.isWhitelisted(user2));
        address[] memory whitelists = provider.whitelistedUsers();
        assertEq(user1, whitelists[0]);
        assertEq(user2, whitelists[1]);
    }

    function test_removeWhitelist() public {
        vm.startPrank(owner);
        provider.whitelist(user1);
        provider.whitelist(user2);
        provider.removeWhitelist(user1);
        assertTrue(provider.isWhitelisted(user2));
        assertFalse(provider.isWhitelisted(user1));
        address[] memory whitelists = provider.whitelistedUsers();
        assertEq(user2, whitelists[0]);
    }
}
