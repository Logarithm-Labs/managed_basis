// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library Arb {
    address constant ORACLE = 0x70cfA166f710a3f5f4C91c67f17541aC75d52432;
    address constant DATA_PROVIDER = 0xD588209dFd70a71347B5D09bDdeee993f038fF77;
    address constant GAS_STATION = address(0);

    address constant BEACON_VAULT = 0x23f685bD55D5A1AEb626Cb3F2aAf6124E65dA555;
    address constant BEACON_STRATEGY = 0xc57Be8bAf545dc63d1135a9Fb43B94765565C7c8;
    address constant BEACON_SPOT_MANAGER = 0x30eD7e8E8103AB57d5d21d48F001E0EaE371dC7e;
    address constant BEACON_X_SPOT_MANAGER = 0x3981CedD1001A847848aCdd616EEB7f68f2a0748;
    address constant BEACON_OFF_CHAIN_POSITION_MANAGER = 0x105755108a8dfcD90c5a0de597BB3A8bce83C535;

    address constant CONFIG_STRATEGY = 0xBf2bFCEf1135389A91c1a9742D60AAc7FAb432b3;
    address constant CONFIG_HL = 0x47b8D09B3Bcba3F5687b223336cf6a76944572E1;

    // wbtc hl vault
    address constant VAULT_HL_USDC_WBTC = 0xe5fc579f20C2dbffd78a92ddD124871a35519659;
    address constant STRATEGY_HL_USDC_WBTC = 0x705e55748D245657914148e9bd3C0183B15Ebb00;
    address constant SPOT_MANAGER_HL_USDC_WBTC = 0x28D21b1B23440DEc140D74f569a0Aeb98B0C5201;
    address constant HEDGE_MANAGER_HL_USDC_WBTC = 0x47EF0Fa6DD0Bbff9E2fA97D2Ab3b2731d0fACc45;

    // link hl vault
    address constant VAULT_HL_USDC_LINK = 0x79f76E343807eA194789D114e61bE6676e6BBeDA;
    address constant STRATEGY_HL_USDC_LINK = 0xd6e39c22C22fF1d13457e226a75B73b382441632;
    address constant SPOT_MANAGER_HL_USDC_LINK = 0x47310058B08D108e75E582bF718A10E97990eaFB;
    address constant OFF_CHAIN_POSITION_MANAGER_HL_USDC_LINK = 0x4D79DB3bF2788Ec1C9cCF6dE023c95AEcf984204;

    // virtual hl x vault
    address constant VAULT_HL_USDC_VIRTUAL = address(0);
    address constant STRATEGY_HL_USDC_VIRTUAL = address(0);
    address constant X_SPOT_MANAGER_HL_USDC_VIRTUAL = address(0);
    address constant HEDGE_MANAGER_HL_USDC_VIRTUAL = address(0);
}

library Bsc {
    address constant GAS_STATION = address(0);
    address constant BEACON_BROTHER_SWAPPER = address(0);
    address constant BROTHER_SWAPPER_HL_USDC_DOGE = address(0);
}

library Base {
    address constant GAS_STATION = address(0);
    address constant BEACON_BROTHER_SWAPPER = address(0);
    address constant BROTHER_SWAPPER_HL_USDC_VIRTUAL = address(0);
}

library Eth {
    address constant GAS_STATION = address(0);
    address constant BEACON_BROTHER_SWAPPER = address(0);
    address constant BROTHER_SWAPPER_HL_USDC_PEPE = address(0);
}
