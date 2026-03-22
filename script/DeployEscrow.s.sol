// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ElasticLendEscrow} from "../src/escrow/ElasticLendEscrow.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Deploy ElasticLend Escrow (Sepolia - Source Chain)
/// @notice Deploys escrow contract where users deposit yield-bearing tokens
contract DeployEscrow is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy escrow
        ElasticLendEscrow escrow = new ElasticLendEscrow(deployer);

        // Deploy mock yield-bearing token (simulates aETH on Ethereum)
        MockERC20 aETH = new MockERC20("Aave ETH", "aETH", 18);

        // Mint test tokens
        aETH.mint(deployer, 100e18);

        vm.stopBroadcast();

        console.log("=== ElasticLend Escrow Deployed ===");
        console.log("Escrow:  ", address(escrow));
        console.log("aETH:    ", address(aETH));
    }
}
