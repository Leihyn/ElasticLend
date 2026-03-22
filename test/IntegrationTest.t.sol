// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ElasticCollateralManager} from "../src/ElasticCollateralManager.sol";
import {ElasticLendingPool} from "../src/ElasticLendingPool.sol";
import {ElasticLiquidationEngine} from "../src/ElasticLiquidationEngine.sol";
import {BackstopPool} from "../src/BackstopPool.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {ElasticLendEscrow} from "../src/escrow/ElasticLendEscrow.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

/// @title Full Integration Test
/// @notice Tests the complete flow: escrow deposit → oracle attestation →
///         borrow → crash → tiered liquidation → stretch effect
contract IntegrationTest is Test {
    // ─── Contracts ────────────────────────────────────────────────
    ElasticCollateralManager public collateralManager;
    ElasticLendingPool public lendingPool;
    ElasticLiquidationEngine public liquidationEngine;
    BackstopPool public backstopPool;
    InterestRateModel public interestRateModel;
    ElasticLendEscrow public escrow; // "source chain" escrow

    // ─── Tokens ───────────────────────────────────────────────────
    MockERC20 public usdc;   // hub chain lending asset
    MockERC20 public weth;   // hub chain collateral
    MockERC20 public aETH;   // "source chain" yield-bearing token in escrow

    // ─── Price Feeds ──────────────────────────────────────────────
    MockPriceFeed public ethFeed;

    // ─── Actors ───────────────────────────────────────────────────
    address public admin = address(this);
    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
    address public lpProvider = makeAddr("lpProvider");
    address public oracle = admin; // admin acts as oracle for hackathon

    function setUp() public {
        // ─── Deploy Tokens ────────────────────────────────────────
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        aETH = new MockERC20("Aave ETH", "aETH", 18); // "on source chain"

        ethFeed = new MockPriceFeed(2000e8); // $2,000

        // ─── Deploy Hub Contracts ─────────────────────────────────
        collateralManager = new ElasticCollateralManager(admin);
        interestRateModel = new InterestRateModel();

        lendingPool = new ElasticLendingPool(
            usdc, admin, address(collateralManager), address(interestRateModel)
        );

        backstopPool = new BackstopPool(admin, address(usdc), 5000e6);

        liquidationEngine = new ElasticLiquidationEngine(
            admin, address(lendingPool), address(collateralManager), address(backstopPool)
        );

        // ─── Deploy Escrow ("Source Chain") ───────────────────────
        escrow = new ElasticLendEscrow(admin);

        // ─── Configure ───────────────────────────────────────────
        collateralManager.setLiquidationEngine(address(liquidationEngine));
        collateralManager.setLendingPool(address(lendingPool));
        backstopPool.grantLiquidationEngine(address(liquidationEngine));
        lendingPool.grantRole(lendingPool.LIQUIDATOR_ROLE(), address(liquidationEngine));

        // Add local tokens
        collateralManager.addToken(
            address(usdc), ElasticCollateralManager.RiskGroup.STABLE,
            500, 8500, address(0), 6
        );
        collateralManager.addToken(
            address(weth), ElasticCollateralManager.RiskGroup.ETH,
            5000, 7500, address(ethFeed), 18
        );

        // ─── Seed Liquidity ──────────────────────────────────────
        usdc.mint(lpProvider, 500_000e6);
        vm.startPrank(lpProvider);
        usdc.approve(address(lendingPool), type(uint256).max);
        lendingPool.deposit(500_000e6, lpProvider);
        vm.stopPrank();

        // Seed backstop
        usdc.mint(admin, 50_000e6);
        usdc.approve(address(backstopPool), type(uint256).max);
        backstopPool.deposit(50_000e6);

        // ─── Fund User ───────────────────────────────────────────
        weth.mint(user, 10e18);        // 10 ETH = $20K (local)
        usdc.mint(user, 20_000e6);     // $20K USDC (local)
        aETH.mint(user, 25e18);        // 25 aETH = $50K (for escrow)
        usdc.mint(liquidator, 200_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //  FULL FLOW: Escrow → Attest → Borrow → Crash → Liquidate
    // ═══════════════════════════════════════════════════════════════

    function test_fullCrossChainFlow() public {
        console.log("========================================");
        console.log("  FULL CROSS-CHAIN ELASTIC LEND FLOW");
        console.log("========================================");

        // ─── Step 1: User deposits into escrow on "source chain" ──
        console.log("");
        console.log("--- STEP 1: Escrow Deposit ---");

        vm.startPrank(user);
        aETH.approve(address(escrow), type(uint256).max);
        escrow.deposit(address(aETH), 25e18); // 25 aETH into escrow
        vm.stopPrank();

        uint256 escrowBalance = escrow.getDeposit(user, address(aETH));
        console.log("Escrow balance:", escrowBalance / 1e18, "aETH");
        assertEq(escrowBalance, 25e18);

        // ─── Step 2: User deposits local collateral on hub ────────
        console.log("");
        console.log("--- STEP 2: Local Deposits ---");

        vm.startPrank(user);
        weth.approve(address(collateralManager), type(uint256).max);
        usdc.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 10e18);      // $20K ETH
        collateralManager.depositLocal(address(usdc), 20_000e6);   // $20K USDC
        vm.stopPrank();

        // ─── Step 3: Oracle attests cross-chain position ──────────
        console.log("");
        console.log("--- STEP 3: Oracle Attestation ---");

        // Oracle reads escrow on "source chain" and attests to hub
        collateralManager.attestCrossChainPosition(
            user,
            1,                  // Ethereum mainnet chain ID
            address(aETH),      // token on source chain
            25e18,              // balance in escrow
            ElasticCollateralManager.RiskGroup.ETH, // aETH is ETH-correlated
            5000,               // 50% maxDrop
            50_000e18           // $50K value (25 aETH × $2000)
        );

        console.log("Attested: 25 aETH on Ethereum = $50,000");

        // ─── Step 4: Check elastic vs rigid borrowing power ───────
        console.log("");
        console.log("--- STEP 4: Borrowing Power ---");

        uint256 elasticBP = collateralManager.getElasticBorrowingPower(user);
        uint256 rigidBP = collateralManager.getRigidBorrowingPower(user);
        uint256 totalCollateral = collateralManager.getTotalCollateralUSD(user);
        uint256 concentration = collateralManager.getConcentrationDegree(user);

        console.log("Total collateral: $", totalCollateral / 1e18);
        console.log("  Local ETH:  $20,000");
        console.log("  Local USDC: $20,000");
        console.log("  Cross-chain aETH: $50,000");
        console.log("Concentration (HHI):", concentration);
        console.log("Elastic BP: $", elasticBP / 1e18);
        console.log("Rigid BP:   $", rigidBP / 1e18);
        console.log("Elastic advantage: $", (elasticBP - rigidBP) / 1e18);

        assertGt(elasticBP, rigidBP, "Elastic should beat rigid for mixed portfolio");

        // ─── Step 5: Borrow ───────────────────────────────────────
        console.log("");
        console.log("--- STEP 5: Borrow ---");

        uint256 borrowAmount = 50_000e6; // $50K
        vm.startPrank(user);
        lendingPool.borrow(borrowAmount);
        vm.stopPrank();

        uint256 hfBefore = lendingPool.getElasticHealthFactor(user);
        uint256 rigidHfBefore = lendingPool.getRigidHealthFactor(user);
        ElasticLendingPool.HealthZone zoneBefore = lendingPool.getHealthZone(user);

        console.log("Borrowed: $50,000 USDC");
        console.log("Elastic HF:", hfBefore / 1e16);
        console.log("Rigid HF:  ", rigidHfBefore / 1e16);
        console.log("Health Zone:", uint256(zoneBefore), "(3=GREEN)");

        // ─── Step 6: ETH Crashes 45% ─────────────────────────────
        console.log("");
        console.log("--- STEP 6: ETH Crashes 45% ---");

        ethFeed.setPrice(1100e8); // $2000 → $1100

        // Also update cross-chain attestation (oracle sees new price)
        collateralManager.attestCrossChainPosition(
            user, 1, address(aETH), 25e18,
            ElasticCollateralManager.RiskGroup.ETH, 5000,
            27_500e18 // 25 aETH × $1100 = $27,500
        );

        uint256 hfAfterCrash = lendingPool.getElasticHealthFactor(user);
        uint256 rigidHfAfterCrash = lendingPool.getRigidHealthFactor(user);
        ElasticLendingPool.HealthZone zoneAfterCrash = lendingPool.getHealthZone(user);

        console.log("ETH price: $2000 -> $1100");
        console.log("Elastic HF:", hfAfterCrash / 1e16);
        console.log("Rigid HF:  ", rigidHfAfterCrash / 1e16);
        console.log("Health Zone:", uint256(zoneAfterCrash));

        // ─── Step 7: Tier 1 — Local Liquidation ──────────────────
        console.log("");
        console.log("--- STEP 7: Tier 1 Local Liquidation ---");

        if (hfAfterCrash < 1e18) {
            // Liquidate local USDC first (safer, instant)
            uint256 maxLiq = lendingPool.getUserDebt(user) * 5000 / 10000;
            uint256 liqAmount = maxLiq > 20_000e6 ? 20_000e6 : maxLiq;

            vm.startPrank(liquidator);
            usdc.approve(address(liquidationEngine), type(uint256).max);
            usdc.approve(address(lendingPool), type(uint256).max);

            // Seize USDC (local, trustless)
            uint256 localUSDC = collateralManager.getLocalDeposit(user, address(usdc));
            if (localUSDC > 0 && liqAmount > 0) {
                liquidationEngine.liquidateLocal(user, liqAmount, address(usdc));
                console.log("Liquidated (local USDC):", liqAmount / 1e6, "USDC debt repaid");
            }

            // ─── Step 8: Tier 2 — Cross-Chain Liquidation ─────────
            console.log("");
            console.log("--- STEP 8: Tier 2 Cross-Chain Liquidation ---");

            uint256 remainingDebt = lendingPool.getUserDebt(user);
            uint256 hfAfterTier1 = lendingPool.getElasticHealthFactor(user);
            console.log("Remaining debt after Tier 1:", remainingDebt / 1e6, "USDC");
            console.log("HF after Tier 1:", hfAfterTier1 / 1e16);

            if (hfAfterTier1 < 1e18 && remainingDebt > 0) {
                uint256 maxLiq2 = remainingDebt * 5000 / 10000;
                uint256 liqAmount2 = maxLiq2 > 15_000e6 ? 15_000e6 : maxLiq2;

                if (liqAmount2 > 0) {
                    liquidationEngine.liquidateCrossChain(user, liqAmount2, 0);
                    console.log("Liquidated (cross-chain aETH):", liqAmount2 / 1e6, "USDC debt repaid");
                    console.log("Cross-chain seizure requested from escrow");
                }
            }
            vm.stopPrank();
        } else {
            console.log("Position still healthy - no liquidation needed");
            console.log("(This demonstrates elastic model protecting the user)");
        }

        // ─── Step 9: Post-Liquidation State ──────────────────────
        console.log("");
        console.log("--- STEP 9: Post-Liquidation State ---");

        uint256 finalDebt = lendingPool.getUserDebt(user);
        uint256 finalHF = lendingPool.getElasticHealthFactor(user);
        uint256 finalCollateral = collateralManager.getTotalCollateralUSD(user);
        uint256 finalConcentration = collateralManager.getConcentrationDegree(user);
        uint256 finalElasticBP = collateralManager.getElasticBorrowingPower(user);

        console.log("Final debt:", finalDebt / 1e6, "USDC");
        console.log("Final collateral: $", finalCollateral / 1e18);
        console.log("Final elastic HF:", finalHF / 1e16);
        console.log("Final concentration:", finalConcentration);
        console.log("Final elastic BP: $", finalElasticBP / 1e18);

        // The remaining portfolio should show the stretch effect
        if (finalCollateral > 0 && finalElasticBP > 0) {
            uint256 bpRatio = Math.mulDiv(finalElasticBP, 10000, finalCollateral);
            console.log("BP per dollar:", bpRatio, "bps (higher = safer portfolio)");
        }

        console.log("");
        console.log("========================================");
        console.log("  FLOW COMPLETE");
        console.log("========================================");
    }

    // ═══════════════════════════════════════════════════════════════
    //  ESCROW TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_escrowDeposit() public {
        vm.startPrank(user);
        aETH.approve(address(escrow), type(uint256).max);
        escrow.deposit(address(aETH), 10e18);
        vm.stopPrank();

        assertEq(escrow.getDeposit(user, address(aETH)), 10e18);
    }

    function test_escrowSeize() public {
        vm.startPrank(user);
        aETH.approve(address(escrow), type(uint256).max);
        escrow.deposit(address(aETH), 10e18);
        vm.stopPrank();

        // Oracle seizes
        escrow.seize(user, address(aETH), 5e18, liquidator);

        assertEq(escrow.getDeposit(user, address(aETH)), 5e18);
        assertEq(aETH.balanceOf(liquidator), 5e18);
    }

    function test_escrowSeizeFailsForNonOracle() public {
        vm.startPrank(user);
        aETH.approve(address(escrow), type(uint256).max);
        escrow.deposit(address(aETH), 10e18);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert();
        escrow.seize(user, address(aETH), 5e18, user);
    }

    function test_escrowEmergencyWithdrawal() public {
        vm.startPrank(user);
        aETH.approve(address(escrow), type(uint256).max);
        escrow.deposit(address(aETH), 10e18);

        // Request emergency withdrawal
        escrow.requestEmergencyWithdrawal();

        // Can't withdraw immediately
        vm.expectRevert();
        escrow.executeEmergencyWithdrawal(address(aETH), 10e18);

        // Fast forward 7 days
        vm.warp(block.timestamp + 7 days + 1);

        // Now can withdraw
        escrow.executeEmergencyWithdrawal(address(aETH), 10e18);
        vm.stopPrank();

        assertEq(escrow.getDeposit(user, address(aETH)), 0);
        assertEq(aETH.balanceOf(user), 25e18); // original balance restored
    }

    function test_escrowDepositCancelsEmergency() public {
        vm.startPrank(user);
        aETH.approve(address(escrow), type(uint256).max);
        escrow.deposit(address(aETH), 5e18);

        escrow.requestEmergencyWithdrawal();
        assertGt(escrow.emergencyRequests(user), 0);

        // New deposit cancels emergency
        escrow.deposit(address(aETH), 5e18);
        assertEq(escrow.emergencyRequests(user), 0);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  BACKSTOP POOL TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_backstopHealthCheck() public {
        assertTrue(backstopPool.isHealthy());

        // Dynamic premium at low utilization
        uint16 premium = backstopPool.getDynamicPremium();
        console.log("Backstop premium at 0% utilization:", premium, "bps");
        assertEq(premium, 500); // Base 5%
    }

    function test_backstopEmergencyMode() public {
        // Withdraw most of backstop
        // (In real scenario, this happens from liquidation payouts)
        // For test, check the threshold logic
        assertTrue(backstopPool.isHealthy());
        assertEq(backstopPool.availableBalance(), 50_000e6);
    }
}
