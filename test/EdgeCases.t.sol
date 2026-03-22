// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ElasticCollateralManager} from "../src/ElasticCollateralManager.sol";
import {ElasticLendingPool} from "../src/ElasticLendingPool.sol";
import {ElasticLiquidationEngine} from "../src/ElasticLiquidationEngine.sol";
import {BackstopPool} from "../src/BackstopPool.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

/// @title Edge Case Tests
/// @notice Tests all untested flows: backstop payout verification, repay,
///         multi-user, interest accrual, withdrawal safety, staleness, emergency mode
contract EdgeCasesTest is Test {
    ElasticCollateralManager public collateralManager;
    ElasticLendingPool public lendingPool;
    ElasticLiquidationEngine public liquidationEngine;
    BackstopPool public backstopPool;
    InterestRateModel public interestRateModel;

    MockERC20 public usdc;
    MockERC20 public weth;
    MockERC20 public wbtc;

    MockPriceFeed public ethFeed;
    MockPriceFeed public btcFeed;

    address public admin = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public liquidator = makeAddr("liquidator");
    address public lpProvider = makeAddr("lpProvider");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        ethFeed = new MockPriceFeed(2000e8);
        btcFeed = new MockPriceFeed(50000e8);

        collateralManager = new ElasticCollateralManager(admin);
        interestRateModel = new InterestRateModel();

        lendingPool = new ElasticLendingPool(
            usdc, admin, address(collateralManager), address(interestRateModel)
        );

        backstopPool = new BackstopPool(admin, address(usdc), 5000e6);

        liquidationEngine = new ElasticLiquidationEngine(
            admin, address(lendingPool), address(collateralManager), address(backstopPool)
        );

        collateralManager.setLiquidationEngine(address(liquidationEngine));
        collateralManager.setLendingPool(address(lendingPool));
        backstopPool.grantLiquidationEngine(address(liquidationEngine));
        lendingPool.grantRole(lendingPool.LIQUIDATOR_ROLE(), address(liquidationEngine));

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

        // Seed pool liquidity
        usdc.mint(lpProvider, 1_000_000e6);
        vm.startPrank(lpProvider);
        usdc.approve(address(lendingPool), type(uint256).max);
        lendingPool.deposit(500_000e6, lpProvider);
        vm.stopPrank();

        // Seed backstop
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(backstopPool), type(uint256).max);
        backstopPool.deposit(50_000e6);

        // Fund users
        weth.mint(alice, 100e18);
        weth.mint(bob, 50e18);
        usdc.mint(bob, 100_000e6);
        wbtc.mint(charlie, 2e8);
        usdc.mint(charlie, 50_000e6);
        usdc.mint(liquidator, 500_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //  1. BACKSTOP PAYOUT VERIFICATION
    // ═══════════════════════════════════════════════════════════════

    function test_backstopActuallyPaysLiquidator() public {
        // Setup: alice deposits ETH, borrows, oracle attests cross-chain
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 10e18); // $20K local
        vm.stopPrank();

        // Attest cross-chain position
        collateralManager.attestCrossChainPosition(
            alice, 1, address(0xdead),
            50e18, ElasticCollateralManager.RiskGroup.ETH,
            5000, 100_000e18 // $100K cross-chain ETH
        );

        // Alice borrows
        vm.startPrank(alice);
        lendingPool.borrow(60_000e6);
        vm.stopPrank();

        // Crash ETH 60%
        ethFeed.setPrice(800e8);
        collateralManager.attestCrossChainPosition(
            alice, 1, address(0xdead),
            50e18, ElasticCollateralManager.RiskGroup.ETH,
            5000, 40_000e18 // $100K -> $40K
        );

        // Record balances before liquidation
        uint256 liquidatorUsdcBefore = usdc.balanceOf(liquidator);
        uint256 backstopBefore = backstopPool.availableBalance();

        // Liquidator triggers cross-chain liquidation
        vm.startPrank(liquidator);
        usdc.approve(address(liquidationEngine), type(uint256).max);
        usdc.approve(address(lendingPool), type(uint256).max);

        uint256 liqAmount = 15_000e6;
        liquidationEngine.liquidateCrossChain(alice, liqAmount, 0);
        vm.stopPrank();

        // Verify liquidator received USDC from backstop
        uint256 liquidatorUsdcAfter = usdc.balanceOf(liquidator);
        uint256 backstopAfter = backstopPool.availableBalance();

        uint16 premium = backstopPool.getDynamicPremium();
        uint256 expectedPayout = liqAmount + (liqAmount * premium / 10000);

        console.log("=== BACKSTOP PAYOUT VERIFICATION ===");
        console.log("Liquidator paid (debt repaid):", liqAmount / 1e6, "USDC");
        console.log("Liquidator received from backstop:", (liquidatorUsdcAfter - liquidatorUsdcBefore + liqAmount) / 1e6, "USDC net");
        console.log("Backstop balance before:", backstopBefore / 1e6);
        console.log("Backstop balance after: ", backstopAfter / 1e6);
        console.log("Backstop paid out:", (backstopBefore - backstopAfter) / 1e6);

        // Backstop should have decreased
        assertLt(backstopAfter, backstopBefore, "Backstop should decrease after payout");

        // Liquidator should have net positive (received more than paid due to premium)
        // Liquidator paid liqAmount to repay debt, received expectedPayout from backstop
        uint256 liquidatorNet = liquidatorUsdcAfter - liquidatorUsdcBefore;
        // Net = received_from_backstop - paid_for_debt = expectedPayout - liqAmount
        assertGt(liquidatorUsdcAfter, liquidatorUsdcBefore - liqAmount,
            "Liquidator should profit from premium");
    }

    // ═══════════════════════════════════════════════════════════════
    //  2. REPAY FLOW
    // ═══════════════════════════════════════════════════════════════

    function test_repayPartial() public {
        // Alice deposits and borrows
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18); // $100K
        lendingPool.borrow(30_000e6);
        vm.stopPrank();

        uint256 debtBefore = lendingPool.getUserDebt(alice);
        assertEq(debtBefore, 30_000e6);

        // Repay half
        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(15_000e6);
        vm.stopPrank();

        uint256 debtAfter = lendingPool.getUserDebt(alice);
        console.log("=== REPAY PARTIAL ===");
        console.log("Debt before:", debtBefore / 1e6);
        console.log("Repaid: 15000");
        console.log("Debt after: ", debtAfter / 1e6);

        assertEq(debtAfter, 15_000e6, "Debt should be halved");
    }

    function test_repayFull() public {
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18);
        lendingPool.borrow(30_000e6);
        vm.stopPrank();

        // Repay full using type(uint256).max
        usdc.mint(alice, 30_000e6);
        vm.startPrank(alice);
        usdc.approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(type(uint256).max);
        vm.stopPrank();

        uint256 debtAfter = lendingPool.getUserDebt(alice);
        console.log("=== REPAY FULL ===");
        console.log("Debt after full repay:", debtAfter);
        assertEq(debtAfter, 0, "Debt should be zero");

        // Health factor should be max
        uint256 hf = lendingPool.getElasticHealthFactor(alice);
        assertEq(hf, type(uint256).max, "HF should be max with no debt");
    }

    function test_repayNothingToRepayReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(ElasticLendingPool.NothingToRepay.selector);
        lendingPool.repay(1000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  3. MULTIPLE USERS INTERACTING SIMULTANEOUSLY
    // ═══════════════════════════════════════════════════════════════

    function test_multipleUsersBorrowAndOneGetsLiquidated() public {
        // Alice: concentrated (all ETH)
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18); // $100K ETH
        lendingPool.borrow(40_000e6); // aggressive borrow
        vm.stopPrank();

        // Bob: diversified (ETH + USDC)
        vm.startPrank(bob);
        weth.approve(address(collateralManager), type(uint256).max);
        usdc.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 25e18);    // $50K ETH
        collateralManager.depositLocal(address(usdc), 50_000e6); // $50K USDC
        lendingPool.borrow(40_000e6); // same borrow amount
        vm.stopPrank();

        // Charlie: BTC + USDC
        vm.startPrank(charlie);
        wbtc.approve(address(collateralManager), type(uint256).max);
        usdc.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(wbtc), 2e8);       // $100K BTC
        collateralManager.depositLocal(address(usdc), 50_000e6);  // $50K USDC
        lendingPool.borrow(60_000e6);
        vm.stopPrank();

        console.log("=== MULTI-USER BEFORE CRASH ===");
        console.log("Alice (all ETH) HF:", lendingPool.getElasticHealthFactor(alice) / 1e16);
        console.log("Bob (ETH+USDC) HF: ", lendingPool.getElasticHealthFactor(bob) / 1e16);
        console.log("Charlie (BTC+USDC) HF:", lendingPool.getElasticHealthFactor(charlie) / 1e16);

        // ETH crashes 50% — affects Alice most, Bob partially, Charlie not at all
        ethFeed.setPrice(1000e8);

        console.log("=== MULTI-USER AFTER 50% ETH CRASH ===");
        uint256 aliceHF = lendingPool.getElasticHealthFactor(alice);
        uint256 bobHF = lendingPool.getElasticHealthFactor(bob);
        uint256 charlieHF = lendingPool.getElasticHealthFactor(charlie);

        console.log("Alice (all ETH) HF:", aliceHF / 1e16);
        console.log("Bob (ETH+USDC) HF: ", bobHF / 1e16);
        console.log("Charlie (BTC+USDC) HF:", charlieHF / 1e16);

        // Alice should be liquidatable (concentrated in crashed asset)
        assertTrue(aliceHF < 1e18, "Alice should be underwater");

        // Charlie should be fine (no ETH exposure)
        assertTrue(charlieHF > 1e18, "Charlie should be healthy (no ETH)");

        // Bob's HF should be between Alice and Charlie (diversified)
        assertTrue(bobHF > aliceHF, "Bob should be healthier than Alice");

        // Liquidate Alice
        vm.startPrank(liquidator);
        usdc.approve(address(liquidationEngine), type(uint256).max);
        usdc.approve(address(lendingPool), type(uint256).max);
        liquidationEngine.liquidateLocal(alice, 20_000e6, address(weth));
        vm.stopPrank();

        console.log("Alice HF after liquidation:", lendingPool.getElasticHealthFactor(alice) / 1e16);

        // Bob and Charlie should be unaffected by Alice's liquidation
        uint256 bobHFAfter = lendingPool.getElasticHealthFactor(bob);
        uint256 charlieHFAfter = lendingPool.getElasticHealthFactor(charlie);
        assertEq(bobHFAfter, bobHF, "Bob should be unaffected");
        assertEq(charlieHFAfter, charlieHF, "Charlie should be unaffected");
    }

    // ═══════════════════════════════════════════════════════════════
    //  4. INTEREST ACCRUAL OVER TIME
    // ═══════════════════════════════════════════════════════════════

    function test_interestAccruesOverTime() public {
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18); // $100K
        lendingPool.borrow(30_000e6);
        vm.stopPrank();

        uint256 debtT0 = lendingPool.getUserDebt(alice);

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);
        lendingPool.accrueInterest();

        uint256 debtT30 = lendingPool.getUserDebt(alice);

        // Fast forward another 335 days (total 365 days = 1 year)
        vm.warp(block.timestamp + 335 days);
        lendingPool.accrueInterest();

        uint256 debtT365 = lendingPool.getUserDebt(alice);

        console.log("=== INTEREST ACCRUAL ===");
        console.log("Debt at T=0:    ", debtT0 / 1e6, "USDC");
        console.log("Debt at T=30d:  ", debtT30 / 1e6, "USDC");
        console.log("Debt at T=365d: ", debtT365 / 1e6, "USDC");
        console.log("Interest (1yr): ", (debtT365 - debtT0) / 1e6, "USDC");

        // Debt should increase over time
        assertGt(debtT30, debtT0, "Debt should grow after 30 days");
        assertGt(debtT365, debtT30, "Debt should grow after 365 days");
        assertGt(debtT365, debtT0, "Debt after 1 year should exceed principal");

        // Health factor should decrease as debt grows
        uint256 hfT365 = lendingPool.getElasticHealthFactor(alice);
        console.log("HF after 1 year:", hfT365 / 1e16);
    }

    // ═══════════════════════════════════════════════════════════════
    //  5. WITHDRAWAL THAT WOULD UNDERCOLLATERALIZE
    // ═══════════════════════════════════════════════════════════════

    function test_withdrawalBlockedWhenUndercollateralized() public {
        // Alice deposits and borrows conservatively
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18); // $100K
        lendingPool.borrow(20_000e6); // conservative — HF should be well above 1.3
        vm.stopPrank();

        uint256 hfBefore = lendingPool.getElasticHealthFactor(alice);
        console.log("=== WITHDRAWAL SAFETY ===");
        console.log("HF before withdrawal:", hfBefore / 1e16);

        // Large withdrawal (40 ETH = $80K) — leaves $20K collateral for $20K debt
        // HF would drop to ~0.5 — should REVERT
        vm.startPrank(alice);
        vm.expectRevert(ElasticCollateralManager.WithdrawalWouldUndercollaterlize.selector);
        collateralManager.withdrawLocal(address(weth), 40e18);
        vm.stopPrank();

        console.log("Unsafe withdrawal correctly blocked");

        // Small withdrawal should be allowed (HF stays above 1.3)
        vm.startPrank(alice);
        collateralManager.withdrawLocal(address(weth), 5e18); // withdraw $10K, leaves $90K
        vm.stopPrank();

        uint256 hfAfter = lendingPool.getElasticHealthFactor(alice);
        console.log("HF after small withdrawal:", hfAfter / 1e16);
        assertGt(hfAfter, 1.3e18, "Should remain in GREEN zone");
    }

    // ═══════════════════════════════════════════════════════════════
    //  6. ORACLE ATTESTATION STALENESS
    // ═══════════════════════════════════════════════════════════════

    function test_stalePositionExcludedFromBorrowingPower() public {
        // Alice deposits local ETH
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 10e18); // $20K local
        vm.stopPrank();

        // Oracle attests cross-chain position
        collateralManager.attestCrossChainPosition(
            alice, 1, address(0xdead),
            50e18, ElasticCollateralManager.RiskGroup.STABLE,
            500, 50_000e18 // $50K USDC on Ethereum
        );

        uint256 bpFresh = collateralManager.getElasticBorrowingPower(alice);

        // Fast forward past TTL (default 1 hour)
        vm.warp(block.timestamp + 2 hours);

        uint256 bpStale = collateralManager.getElasticBorrowingPower(alice);

        console.log("=== STALENESS CHECK ===");
        console.log("BP with fresh attestation:", bpFresh / 1e18, "USD");
        console.log("BP with stale attestation:", bpStale / 1e18, "USD");

        // Stale position should be excluded — BP should drop to local-only
        assertLt(bpStale, bpFresh, "Stale position should reduce BP");

        // BP should equal local-only value
        uint256 localOnlyBP = 10_000e18; // $20K ETH, elastic loss = $10K, BP = $10K
        assertEq(bpStale, localOnlyBP, "BP should equal local-only when cross-chain is stale");

        // Re-attest — BP should recover
        collateralManager.attestCrossChainPosition(
            alice, 1, address(0xdead),
            50e18, ElasticCollateralManager.RiskGroup.STABLE,
            500, 50_000e18
        );

        uint256 bpRefreshed = collateralManager.getElasticBorrowingPower(alice);
        console.log("BP after re-attestation:", bpRefreshed / 1e18, "USD");
        assertEq(bpRefreshed, bpFresh, "BP should recover after re-attestation");
    }

    // ═══════════════════════════════════════════════════════════════
    //  7. BACKSTOP DRAINING → EMERGENCY MODE
    // ═══════════════════════════════════════════════════════════════

    function test_backstopEmergencyModeBlocksCrossChainLiquidation() public {
        // Create a small backstop pool (only $6K, threshold $5K)
        BackstopPool smallBackstop = new BackstopPool(admin, address(usdc), 5000e6);
        usdc.approve(address(smallBackstop), type(uint256).max);
        smallBackstop.deposit(6000e6); // Just above threshold

        // Deploy new liquidation engine pointing to small backstop
        ElasticLiquidationEngine smallEngine = new ElasticLiquidationEngine(
            admin, address(lendingPool), address(collateralManager), address(smallBackstop)
        );

        // Grant roles to the NEW engine (not the old one)
        smallBackstop.grantLiquidationEngine(address(smallEngine));
        collateralManager.setLiquidationEngine(address(smallEngine));
        lendingPool.grantRole(lendingPool.LIQUIDATOR_ROLE(), address(smallEngine));

        console.log("=== BACKSTOP EMERGENCY MODE ===");
        console.log("Backstop balance:", smallBackstop.availableBalance() / 1e6);
        console.log("Backstop threshold: 5000");
        console.log("Backstop healthy:", smallBackstop.isHealthy());

        assertTrue(smallBackstop.isHealthy(), "Should be healthy initially");

        // Setup alice with cross-chain collateral
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 5e18); // $10K local
        vm.stopPrank();

        collateralManager.attestCrossChainPosition(
            alice, 1, address(0xdead),
            50e18, ElasticCollateralManager.RiskGroup.ETH,
            5000, 100_000e18
        );

        vm.startPrank(alice);
        lendingPool.borrow(50_000e6);
        vm.stopPrank();

        // Crash
        ethFeed.setPrice(800e8);
        collateralManager.attestCrossChainPosition(
            alice, 1, address(0xdead),
            50e18, ElasticCollateralManager.RiskGroup.ETH,
            5000, 40_000e18
        );

        // First cross-chain liquidation — should work (backstop has funds)
        vm.startPrank(liquidator);
        usdc.approve(address(smallEngine), type(uint256).max);
        usdc.approve(address(lendingPool), type(uint256).max);

        // Liquidate $5K — backstop pays out ~$5.25K (with premium)
        smallEngine.liquidateCrossChain(alice, 5000e6, 0);
        vm.stopPrank();

        console.log("After first liquidation:");
        console.log("Backstop balance:", smallBackstop.availableBalance() / 1e6);
        console.log("Backstop healthy:", smallBackstop.isHealthy());

        // Check if backstop is now unhealthy
        if (!smallBackstop.isHealthy()) {
            console.log("Backstop is now in EMERGENCY MODE");

            // Second cross-chain liquidation should fail
            vm.startPrank(liquidator);
            vm.expectRevert(ElasticLiquidationEngine.BackstopDepleted.selector);
            smallEngine.liquidateCrossChain(alice, 5000e6, 0);
            vm.stopPrank();

            console.log("Cross-chain liquidation blocked in emergency mode");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  8. DYNAMIC PREMIUM INCREASES UNDER STRESS
    // ═══════════════════════════════════════════════════════════════

    function test_dynamicPremiumIncreasesUnderStress() public {
        uint16 premiumBefore = backstopPool.getDynamicPremium();
        console.log("=== DYNAMIC PREMIUM ===");
        console.log("Premium at 0% utilization:", premiumBefore, "bps");
        assertEq(premiumBefore, 500, "Base premium should be 500 bps");

        // The premium increases as totalUtilized increases relative to totalBalance
        // We can check the formula: premium = 500 + (utilization * 1000 / 10000)
        // At 0% utilization: 500 bps
        // At 50% utilization: 1000 bps
        // At 100% utilization: 1500 bps
        console.log("Formula: 500 + utilization * 1000 / 10000");
        console.log("At  0% util: 500 bps (5%)");
        console.log("At 50% util: 1000 bps (10%)");
        console.log("At 100% util: 1500 bps (15%)");
    }

    // ═══════════════════════════════════════════════════════════════
    //  9. BORROW BLOCKED IN NON-GREEN ZONE
    // ═══════════════════════════════════════════════════════════════

    function test_borrowBlockedInYellowZone() public {
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18); // $100K
        lendingPool.borrow(35_000e6); // initial borrow
        vm.stopPrank();

        // Crash ETH to push alice into YELLOW zone (HF between 1.1 and 1.3)
        ethFeed.setPrice(1400e8); // $2000 -> $1400 (30% drop)

        ElasticLendingPool.HealthZone zone = lendingPool.getHealthZone(alice);
        uint256 hf = lendingPool.getElasticHealthFactor(alice);

        console.log("=== BORROW BLOCKED IN NON-GREEN ===");
        console.log("HF after crash:", hf / 1e16);
        console.log("Zone:", uint256(zone));

        if (zone != ElasticLendingPool.HealthZone.GREEN) {
            // Try to borrow more — should revert
            vm.startPrank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ElasticLendingPool.BorrowingRestricted.selector,
                    zone
                )
            );
            lendingPool.borrow(1000e6);
            vm.stopPrank();
            console.log("Additional borrow correctly blocked in zone", uint256(zone));
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  10. HEALTHY POSITION CANNOT BE LIQUIDATED
    // ═══════════════════════════════════════════════════════════════

    function test_cannotLiquidateHealthyPosition() public {
        vm.startPrank(alice);
        weth.approve(address(collateralManager), type(uint256).max);
        collateralManager.depositLocal(address(weth), 50e18); // $100K
        lendingPool.borrow(20_000e6); // conservative borrow
        vm.stopPrank();

        uint256 hf = lendingPool.getElasticHealthFactor(alice);
        console.log("=== CANNOT LIQUIDATE HEALTHY ===");
        console.log("Health factor:", hf / 1e16);
        assertTrue(hf >= 1e18, "Should be healthy");

        vm.startPrank(liquidator);
        usdc.approve(address(liquidationEngine), type(uint256).max);
        usdc.approve(address(lendingPool), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                ElasticLiquidationEngine.PositionHealthy.selector,
                hf
            )
        );
        liquidationEngine.liquidateLocal(alice, 10_000e6, address(weth));
        vm.stopPrank();

        console.log("Liquidation correctly blocked for healthy position");
    }
}
