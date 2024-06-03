// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IOrderHandler {
    function referralStorage() external view returns (address);
}

contract MockFactory {
    address public oracle;
    address public referralStorage;
    address public dataStore = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address public reader = 0xdA5A70c885187DaA71E7553ca9F728464af8d2ad;
    address public orderVault = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    address public orderHandler = 0x352f684ab9e97a6321a13CF03A61316B681D9fD2;
    address public exchangeRouter = 0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8;

    uint256 public callbackGasLimit = 2_000_000;
    bytes32 public referralCode;

    constructor(address _oracle) {
        oracle = _oracle;
        referralStorage = IOrderHandler(orderHandler).referralStorage();
    }

    /// @return always returns the ETH-USDC market of gmx on mainet
    function marketKey(address, address) external pure returns (address) {
        return address(0x70d95587d40A2caf56bd97485aB3Eec10Bee6336);
    }
}
