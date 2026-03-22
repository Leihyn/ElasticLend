// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ElasticCollateralManager} from "../src/ElasticCollateralManager.sol";
import {ElasticLendingPool} from "../src/ElasticLendingPool.sol";
import {ElasticLiquidationEngine} from "../src/ElasticLiquidationEngine.sol";
import {BackstopPool} from "../src/BackstopPool.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

/// @title Deploy ElasticLend Hub (Base Sepolia)
/// @notice Deploys all hub contracts with mock tokens for testnet demo
contract DeployHub is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ─── Mock Tokens ──────────────────────────────────────────
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped ETH", "WETH", 18);
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        MockERC20 link = new MockERC20("Chainlink", "LINK", 18);

        // ─── Mock Price Feeds ─────────────────────────────────────
        MockPriceFeed ethFeed = new MockPriceFeed(2000e8);
        MockPriceFeed btcFeed = new MockPriceFeed(50000e8);
        MockPriceFeed linkFeed = new MockPriceFeed(15e8);

        // ─── Core Protocol ────────────────────────────────────────
        ElasticCollateralManager collateralManager = new ElasticCollateralManager(deployer);
        InterestRateModel interestRateModel = new InterestRateModel();

        ElasticLendingPool lendingPool = new ElasticLendingPool(
            usdc, deployer, address(collateralManager), address(interestRateModel)
        );

        BackstopPool backstopPool = new BackstopPool(deployer, address(usdc), 1000e6);

        ElasticLiquidationEngine liquidationEngine = new ElasticLiquidationEngine(
            deployer, address(lendingPool), address(collateralManager), address(backstopPool)
        );

        // ─── Configure ───────────────────────────────────────────
        collateralManager.setLiquidationEngine(address(liquidationEngine));
        collateralManager.setLendingPool(address(lendingPool));
        backstopPool.grantLiquidationEngine(address(liquidationEngine));
        lendingPool.grantRole(lendingPool.LIQUIDATOR_ROLE(), address(liquidationEngine));

        // ─── Add Supported Tokens ─────────────────────────────────
        collateralManager.addToken(
            address(usdc), ElasticCollateralManager.RiskGroup.STABLE,
            500, 8500, address(0), 6
        );
        collateralManager.addToken(
            address(weth), ElasticCollateralManager.RiskGroup.ETH,
            5000, 7500, address(ethFeed), 18
        );
        collateralManager.addToken(
            address(wbtc), ElasticCollateralManager.RiskGroup.BTC,
            4500, 7000, address(btcFeed), 8
        );
        collateralManager.addToken(
            address(link), ElasticCollateralManager.RiskGroup.OTHER,
            6000, 6500, address(linkFeed), 18
        );

        // ─── Seed Demo Data ───────────────────────────────────────
        // Mint USDC for LP and backstop
        usdc.mint(deployer, 1_000_000e6);
        usdc.approve(address(lendingPool), type(uint256).max);
        lendingPool.deposit(500_000e6, deployer);

        usdc.approve(address(backstopPool), type(uint256).max);
        backstopPool.deposit(50_000e6);

        // Mint test tokens for demo
        weth.mint(deployer, 100e18);
        wbtc.mint(deployer, 2e8);
        link.mint(deployer, 10_000e18);

        vm.stopBroadcast();

        // ─── Log Addresses ────────────────────────────────────────
        console.log("=== ElasticLend Hub Deployed ===");
        console.log("USDC:                ", address(usdc));
        console.log("WETH:                ", address(weth));
        console.log("WBTC:                ", address(wbtc));
        console.log("LINK:                ", address(link));
        console.log("ETH Price Feed:      ", address(ethFeed));
        console.log("BTC Price Feed:      ", address(btcFeed));
        console.log("LINK Price Feed:     ", address(linkFeed));
        console.log("CollateralManager:   ", address(collateralManager));
        console.log("InterestRateModel:   ", address(interestRateModel));
        console.log("LendingPool:         ", address(lendingPool));
        console.log("BackstopPool:        ", address(backstopPool));
        console.log("LiquidationEngine:   ", address(liquidationEngine));
    }
}
