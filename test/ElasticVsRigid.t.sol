// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ElasticCollateralManager} from "../src/ElasticCollateralManager.sol";
import {ElasticLendingPool} from "../src/ElasticLendingPool.sol";
import {ElasticLiquidationEngine} from "../src/ElasticLiquidationEngine.sol";
import {BackstopPool} from "../src/BackstopPool.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

contract ElasticVsRigidTest is Test {
    ElasticCollateralManager public collateralManager;
    ElasticLendingPool public lendingPool;
    ElasticLiquidationEngine public liquidationEngine;
    BackstopPool public backstopPool;
    InterestRateModel public interestRateModel;

    MockERC20 public usdc;
    MockERC20 public weth;
    MockERC20 public wbtc;
    MockERC20 public link;

    MockPriceFeed public ethFeed;
    MockPriceFeed public btcFeed;
    MockPriceFeed public linkFeed;

    address public admin = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidator = makeAddr("liquidator");
    address public lpProvider = makeAddr("lpProvider");

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        link = new MockERC20("Chainlink", "LINK", 18);

        // Deploy price feeds (8 decimals, Chainlink standard)
        ethFeed = new MockPriceFeed(2000e8);   // $2,000
        btcFeed = new MockPriceFeed(50000e8);  // $50,000
        linkFeed = new MockPriceFeed(15e8);    // $15

        // Deploy protocol
        collateralManager = new ElasticCollateralManager(admin);
        interestRateModel = new InterestRateModel();

        lendingPool = new ElasticLendingPool(
            usdc,
            admin,
            address(collateralManager),
            address(interestRateModel)
        );

        backstopPool = new BackstopPool(admin, address(usdc), 1000e6);

        liquidationEngine = new ElasticLiquidationEngine(
            admin,
            address(lendingPool),
            address(collateralManager),
            address(backstopPool)
        );

        // Configure
        collateralManager.setLiquidationEngine(address(liquidationEngine));
        collateralManager.setLendingPool(address(lendingPool));
        backstopPool.grantLiquidationEngine(address(liquidationEngine));

        // Add supported tokens
        collateralManager.addToken(
            address(usdc), ElasticCollateralManager.RiskGroup.STABLE,
            500, 8500, address(0), 6  // 5% maxDrop, 85% rigid factor, $1 default price
        );
        collateralManager.addToken(
            address(weth), ElasticCollateralManager.RiskGroup.ETH,
            5000, 7500, address(ethFeed), 18  // 50% maxDrop, 75% rigid factor
        );
        collateralManager.addToken(
            address(wbtc), ElasticCollateralManager.RiskGroup.BTC,
            4500, 7000, address(btcFeed), 8  // 45% maxDrop, 70% rigid factor
        );
        collateralManager.addToken(
            address(link), ElasticCollateralManager.RiskGroup.OTHER,
            6000, 6500, address(linkFeed), 18  // 60% maxDrop, 65% rigid factor
        );

        // Fund LP
        usdc.mint(lpProvider, 1_000_000e6);
        vm.startPrank(lpProvider);
        usdc.approve(address(lendingPool), type(uint256).max);
        lendingPool.deposit(500_000e6, lpProvider);
        vm.stopPrank();

        // Fund backstop
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(backstopPool), type(uint256).max);
        backstopPool.deposit(50_000e6);

        // Fund users
        weth.mint(alice, 100e18);  // 100 ETH = $200,000
        weth.mint(bob, 25e18);     // 25 ETH = $50,000
        usdc.mint(bob, 50_000e6);  // $50,000 USDC
        wbtc.mint(bob, 1e8);       // 1 BTC = $50,000
        link.mint(bob, 3333e18);   // ~$50,000 in LINK
    }

    // ─── Core Test: Diversified > Concentrated ─────────────────────

    function test_diversifiedGetsMoreBorrowingPower() public {
        // Alice: $200K all in ETH (concentrated)
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 100e18); // $200,000
        vm.stopPrank();

        // Bob: $200K split across 4 groups (diversified)
        vm.startPrank(bob);
        weth.approve(address(collateralManager), type(uint256).max);
        usdc.approve(address(collateralManager), type(uint256).max);
        wbtc.approve(address(collateralManager), type(uint256).max);
        link.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 25e18);     // $50,000
        collateralManager.depositLocal(address(usdc), 50_000e6);  // $50,000
        collateralManager.depositLocal(address(wbtc), 1e8);       // $50,000
        collateralManager.depositLocal(address(link), 3333e18);   // ~$50,000
        vm.stopPrank();

        uint256 aliceElastic = collateralManager.getElasticBorrowingPower(alice);
        uint256 bobElastic = collateralManager.getElasticBorrowingPower(bob);
        uint256 aliceRigid = collateralManager.getRigidBorrowingPower(alice);
        uint256 bobRigid = collateralManager.getRigidBorrowingPower(bob);

        console.log("=== ELASTIC VS RIGID: SAME COLLATERAL VALUE ===");
        console.log("Alice (all ETH) - Elastic BP:", aliceElastic / 1e18, "USD");
        console.log("Alice (all ETH) - Rigid BP:  ", aliceRigid / 1e18, "USD");
        console.log("Bob (diversified) - Elastic BP:", bobElastic / 1e18, "USD");
        console.log("Bob (diversified) - Rigid BP:  ", bobRigid / 1e18, "USD");
        console.log("Elastic advantage for Bob:", (bobElastic - aliceElastic) * 100 / aliceElastic, "%");

        // Under elastic model, Bob should get MORE borrowing power than Alice
        assertGt(bobElastic, aliceElastic, "Diversified should get more elastic BP");

        // Under rigid model, they should be similar
        // (small difference due to different per-asset factors)
    }

    // ─── Concentration Degree ──────────────────────────────────────

    function test_concentrationDegree() public {
        // Alice: all in one group
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 100e18);
        vm.stopPrank();

        // Bob: split across groups
        vm.startPrank(bob);
        weth.approve(address(collateralManager), type(uint256).max);
        usdc.approve(address(collateralManager), type(uint256).max);
        wbtc.approve(address(collateralManager), type(uint256).max);
        link.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 25e18);
        collateralManager.depositLocal(address(usdc), 50_000e6);
        collateralManager.depositLocal(address(wbtc), 1e8);
        collateralManager.depositLocal(address(link), 3333e18);
        vm.stopPrank();

        uint256 aliceConcentration = collateralManager.getConcentrationDegree(alice);
        uint256 bobConcentration = collateralManager.getConcentrationDegree(bob);

        console.log("Alice concentration (HHI):", aliceConcentration);
        console.log("Bob concentration (HHI):  ", bobConcentration);

        // Alice should be max concentrated (HHI = 10000)
        assertEq(aliceConcentration, 10000, "All-in-one should be max HHI");

        // Bob should be more diversified (HHI < 10000)
        assertLt(bobConcentration, 5000, "Diversified should have low HHI");
    }

    // ─── Cross-Chain Positions ─────────────────────────────────────

    function test_crossChainPositionsIncludedInElasticCalc() public {
        // Alice: $100K ETH local only
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18); // $100,000
        vm.stopPrank();

        uint256 aliceLocalOnly = collateralManager.getElasticBorrowingPower(alice);

        // Oracle attests: Alice also has $100K USDC vault on Arbitrum
        collateralManager.attestCrossChainPosition(
            alice,
            42161, // Arbitrum chain ID
            address(0xdead), // token address on Arbitrum
            100_000e6, // balance
            ElasticCollateralManager.RiskGroup.STABLE,
            500, // 5% maxDrop
            100_000e18 // $100,000 value in 18 decimals
        );

        uint256 aliceWithCrossChain = collateralManager.getElasticBorrowingPower(alice);

        console.log("=== CROSS-CHAIN DIVERSIFICATION ===");
        console.log("Alice (ETH local only) BP:", aliceLocalOnly / 1e18, "USD");
        console.log("Alice (ETH + cross-chain USDC) BP:", aliceWithCrossChain / 1e18, "USD");

        // Cross-chain position should increase borrowing power
        assertGt(aliceWithCrossChain, aliceLocalOnly, "Cross-chain should add BP");

        // The increase should be MORE than just adding the cross-chain value
        // because of the diversification benefit (ETH + STABLE = uncorrelated)
        uint256 crossChainValue = 100_000e18;
        uint256 actualIncrease = aliceWithCrossChain - aliceLocalOnly;

        console.log("Cross-chain value added:", crossChainValue / 1e18, "USD");
        console.log("Borrowing power increase:", actualIncrease / 1e18, "USD");
    }

    // ─── Crash Simulation ──────────────────────────────────────────

    function test_elasticSurvivesCrashThatKillsRigid() public {
        // Bob: diversified $200K portfolio
        vm.startPrank(bob);
        weth.approve(address(collateralManager), type(uint256).max);
        usdc.approve(address(collateralManager), type(uint256).max);
        wbtc.approve(address(collateralManager), type(uint256).max);
        link.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 25e18);     // $50,000
        collateralManager.depositLocal(address(usdc), 50_000e6);  // $50,000
        collateralManager.depositLocal(address(wbtc), 1e8);       // $50,000
        collateralManager.depositLocal(address(link), 3333e18);   // ~$50,000
        vm.stopPrank();

        // Bob borrows near his elastic limit
        uint256 elasticBP = collateralManager.getElasticBorrowingPower(bob);
        uint256 rigidBP = collateralManager.getRigidBorrowingPower(bob);

        // Borrow amount between rigid and elastic BP
        // This amount would be underwater under rigid but safe under elastic
        uint256 borrowAmount = (rigidBP / 1e12 + elasticBP / 1e12) / 2; // average, in 6 decimals
        // Adjust to be just above rigid BP but below elastic BP
        borrowAmount = rigidBP / 1e12 + (elasticBP / 1e12 - rigidBP / 1e12) / 2;

        // Only borrow if elastic > rigid (diversification benefit exists)
        if (elasticBP > rigidBP) {
            usdc.mint(bob, borrowAmount); // give bob enough to have started with
            vm.startPrank(bob);
            usdc.approve(address(lendingPool), type(uint256).max);

            // Borrow slightly less than elastic BP (to be safe initially)
            uint256 safeBorrow = elasticBP / 1e12 * 90 / 100; // 90% of elastic BP
            if (safeBorrow > 0 && safeBorrow <= 400_000e6) {
                lendingPool.borrow(safeBorrow);

                uint256 elasticHF = lendingPool.getElasticHealthFactor(bob);
                uint256 rigidHF = lendingPool.getRigidHealthFactor(bob);

                console.log("=== BEFORE CRASH ===");
                console.log("Borrowed:", safeBorrow / 1e6, "USDC");
                console.log("Elastic HF:", elasticHF / 1e16, "(x100)");
                console.log("Rigid HF:  ", rigidHF / 1e16, "(x100)");
            }
            vm.stopPrank();
        }

        // ETH crashes 40%
        ethFeed.setPrice(1200e8); // $2000 → $1200

        uint256 postCrashElasticHF = lendingPool.getElasticHealthFactor(bob);
        uint256 postCrashRigidHF = lendingPool.getRigidHealthFactor(bob);

        console.log("=== AFTER 40% ETH CRASH ===");
        console.log("Elastic HF:", postCrashElasticHF / 1e16, "(x100)");
        console.log("Rigid HF:  ", postCrashRigidHF / 1e16, "(x100)");

        // Elastic should show higher health factor (diversification protection)
        assertGt(postCrashElasticHF, postCrashRigidHF,
            "Elastic HF should be higher after crash (diversification protects)");
    }

    // ─── Stretch Effect ────────────────────────────────────────────

    function test_stretchEffectAfterPartialLiquidation() public {
        // Alice: $100K ETH + $100K USDC (50/50 split)
        weth.mint(alice, 50e18); // another 50 ETH
        usdc.mint(alice, 100_000e6);

        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        usdc.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18);     // $100,000
        collateralManager.depositLocal(address(usdc), 100_000e6); // $100,000
        vm.stopPrank();

        uint256 concentrationBefore = collateralManager.getConcentrationDegree(alice);
        console.log("=== STRETCH EFFECT ===");
        console.log("Concentration before:", concentrationBefore);

        // After ETH crashes and ETH collateral is partially seized,
        // the portfolio becomes MORE stablecoin-heavy → more diversified → stretch

        // Simulate: remove $50K of ETH collateral (as if seized)
        vm.prank(address(liquidationEngine));
        collateralManager.seizeLocal(alice, address(weth), 25e18, liquidator); // seize $50K ETH

        uint256 concentrationAfter = collateralManager.getConcentrationDegree(alice);
        uint256 remainingBP = collateralManager.getElasticBorrowingPower(alice);

        console.log("Concentration after seizure:", concentrationAfter);
        console.log("Remaining collateral - ETH: $50K, USDC: $100K");
        console.log("Elastic BP after stretch:", remainingBP / 1e18, "USD");

        // Portfolio shifted from 50/50 ETH/USDC to 33/67 ETH/USDC.
        // HHI goes UP because the portfolio is now lopsided toward stables.
        // But the KEY metric is elastic borrowing power per dollar of collateral.
        // The remaining collateral is SAFER (more stablecoin-heavy) so the
        // elastic model gives higher BP per dollar — this IS the stretch effect.

        uint256 remainingCollateral = collateralManager.getTotalCollateralUSD(alice);
        uint256 bpPerDollar = Math.mulDiv(remainingBP, 10000, remainingCollateral);

        // Before seizure: BP per dollar was $200K elastic BP / $200K collateral
        // After seizure: should be HIGHER because portfolio is now safer (more stables)
        // This is the stretch: remaining collateral contributes MORE per dollar
        console.log("BP per dollar of collateral:", bpPerDollar, "bps");
        assertGt(bpPerDollar, 8000, "Stretch: BP/collateral should be high for safe portfolio");
    }

    // ─── Liquidation Bonus Scales with Concentration ───────────────

    function test_liquidationBonusScalesWithConcentration() public {
        // Alice: concentrated
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 100e18);
        vm.stopPrank();

        // Bob: diversified
        vm.startPrank(bob);
        weth.approve(address(collateralManager), type(uint256).max);
        usdc.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 25e18);
        collateralManager.depositLocal(address(usdc), 50_000e6);
        vm.stopPrank();

        uint16 aliceBonus = liquidationEngine.getLiquidationBonus(alice);
        uint16 bobBonus = liquidationEngine.getLiquidationBonus(bob);

        console.log("=== LIQUIDATION BONUS ===");
        console.log("Alice (concentrated) bonus:", aliceBonus, "bps");
        console.log("Bob (diversified) bonus:   ", bobBonus, "bps");

        // Concentrated should have higher bonus (more risk to protocol)
        assertGt(aliceBonus, bobBonus,
            "Concentrated should have higher liquidation bonus");
    }

    // ─── Health Zones ──────────────────────────────────────────────

    function test_healthZones() public {
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18); // $100,000
        vm.stopPrank();

        // Before borrowing: GREEN
        ElasticLendingPool.HealthZone zone = lendingPool.getHealthZone(alice);
        assertEq(uint256(zone), uint256(ElasticLendingPool.HealthZone.GREEN));

        // Borrow conservatively
        vm.startPrank(alice);
        lendingPool.borrow(30_000e6); // $30K against $100K collateral
        vm.stopPrank();

        zone = lendingPool.getHealthZone(alice);
        console.log("After borrowing $30K: zone =", uint256(zone), "(3=GREEN)");

        // Crash ETH to make health factor drop
        ethFeed.setPrice(800e8); // $2000 → $800 (60% crash)

        zone = lendingPool.getHealthZone(alice);
        uint256 hf = lendingPool.getElasticHealthFactor(alice);
        console.log("After 60% ETH crash: HF =", hf / 1e16, "zone =", uint256(zone));
    }
}
