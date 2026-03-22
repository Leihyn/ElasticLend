// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ElasticLendingPool} from "./ElasticLendingPool.sol";
import {ElasticCollateralManager} from "./ElasticCollateralManager.sol";
import {BackstopPool} from "./BackstopPool.sol";

/// @title ElasticLiquidationEngine
/// @notice Tiered liquidation implementing the paper's elastic slashing mechanism.
///
///         Tier 1: Seize local collateral (instant, trustless)
///         Tier 2: Request cross-chain seizure (oracle-mediated, backstop-funded)
///
///         The seizure order is determined by the elastic model: most-impaired
///         collateral (highest loss relative to maxDrop) is seized first. This
///         implements Section 3.4 of the paper — when a "Byzantine service" (crashed
///         asset class) is removed, remaining allocations stretch to cover surviving
///         obligations.
///
///         Liquidation bonus scales with portfolio concentration:
///         Concentrated (HHI=10000) → 10% bonus (more risk to protocol)
///         Diversified (HHI=2500)   → 5% bonus (less risk to protocol)
///         This incentivizes diversification from both sides: more borrowing power
///         AND lower liquidation penalty.
contract ElasticLiquidationEngine is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant ENGINE_ADMIN = keccak256("ENGINE_ADMIN");

    // ─── Storage ──────────────────────────────────────────────────

    ElasticLendingPool public lendingPool;
    ElasticCollateralManager public collateralManager;
    BackstopPool public backstopPool;

    /// @notice Maximum portion of debt liquidatable at once (basis points)
    uint16 public maxLiquidationBps = 5000; // 50%

    /// @notice Base liquidation bonus (for diversified portfolios)
    uint16 public baseBonusBps = 500; // 5%

    /// @notice Max liquidation bonus (for concentrated portfolios)
    uint16 public maxBonusBps = 1000; // 10%

    // ─── Events ───────────────────────────────────────────────────

    event LocalLiquidation(
        address indexed borrower,
        address indexed liquidator,
        address indexed collateralToken,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    event CrossChainLiquidation(
        address indexed borrower,
        address indexed liquidator,
        uint256 positionIndex,
        uint256 debtRepaid,
        uint256 valueSeized,
        bytes32 seizureId
    );

    // ─── Errors ───────────────────────────────────────────────────

    error PositionHealthy(uint256 healthFactor);
    error ExceedsMaxLiquidation(uint256 requested, uint256 maxAllowed);
    error NoCollateralToSeize();
    error ZeroAmount();
    error BackstopDepleted();

    // ─── Constructor ──────────────────────────────────────────────

    constructor(
        address admin,
        address _lendingPool,
        address _collateralManager,
        address _backstopPool
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ENGINE_ADMIN, admin);
        lendingPool = ElasticLendingPool(_lendingPool);
        collateralManager = ElasticCollateralManager(_collateralManager);
        backstopPool = BackstopPool(_backstopPool);
    }

    // ─── Tier 1: Local Liquidation ────────────────────────────────

    /// @notice Liquidate by seizing local collateral (trustless, instant)
    function liquidateLocal(
        address borrower,
        uint256 debtAmount,
        address collateralToken
    ) external nonReentrant {
        if (debtAmount == 0) revert ZeroAmount();

        // Check health factor
        uint256 hf = lendingPool.getElasticHealthFactor(borrower);
        if (hf >= lendingPool.HF_RED()) revert PositionHealthy(hf);

        // Check max liquidation
        uint256 userDebt = lendingPool.getUserDebt(borrower);
        uint256 maxLiq = userDebt * maxLiquidationBps / 10000;
        if (debtAmount > maxLiq) revert ExceedsMaxLiquidation(debtAmount, maxLiq);

        // Check borrower has local collateral
        uint256 collateralBalance = collateralManager.getLocalDeposit(borrower, collateralToken);
        if (collateralBalance == 0) revert NoCollateralToSeize();

        // Calculate collateral to seize (debt + concentration-scaled bonus)
        uint16 bonus = getLiquidationBonus(borrower);
        uint256 collateralToSeize = debtAmount * (10000 + bonus) / 10000;
        if (collateralToSeize > collateralBalance) {
            collateralToSeize = collateralBalance;
        }

        // Liquidator repays debt
        address asset = address(lendingPool.asset());
        IERC20(asset).safeTransferFrom(msg.sender, address(this), debtAmount);
        IERC20(asset).forceApprove(address(lendingPool), debtAmount);
        lendingPool.liquidate(borrower, debtAmount);

        // Seize local collateral
        collateralManager.seizeLocal(borrower, collateralToken, collateralToSeize, msg.sender);

        emit LocalLiquidation(borrower, msg.sender, collateralToken, debtAmount, collateralToSeize);
    }

    // ─── Tier 2: Cross-Chain Liquidation ──────────────────────────

    /// @notice Liquidate by requesting cross-chain seizure (oracle-mediated)
    /// @dev Liquidator repays debt on hub, receives payment from backstop pool.
    ///      Oracle executes actual seizure on source chain.
    function liquidateCrossChain(
        address borrower,
        uint256 debtAmount,
        uint256 positionIndex
    ) external nonReentrant {
        if (debtAmount == 0) revert ZeroAmount();

        // Check health factor
        uint256 hf = lendingPool.getElasticHealthFactor(borrower);
        if (hf >= lendingPool.HF_RED()) revert PositionHealthy(hf);

        // Check max liquidation
        uint256 userDebt = lendingPool.getUserDebt(borrower);
        uint256 maxLiq = userDebt * maxLiquidationBps / 10000;
        if (debtAmount > maxLiq) revert ExceedsMaxLiquidation(debtAmount, maxLiq);

        // Check cross-chain position exists
        ElasticCollateralManager.CrossChainPosition memory pos =
            collateralManager.getCrossChainPosition(borrower, positionIndex);
        if (pos.valueUSD == 0) revert NoCollateralToSeize();

        // Check backstop is healthy
        if (!backstopPool.isHealthy()) revert BackstopDepleted();

        // Calculate seizure value (debt + dynamic premium from backstop)
        uint16 premium = backstopPool.getDynamicPremium();
        uint256 seizeValueUSD = debtAmount * (10000 + premium) / 10000;
        if (seizeValueUSD > pos.valueUSD) {
            seizeValueUSD = pos.valueUSD;
        }

        // Liquidator repays debt
        address asset = address(lendingPool.asset());
        IERC20(asset).safeTransferFrom(msg.sender, address(this), debtAmount);
        IERC20(asset).forceApprove(address(lendingPool), debtAmount);
        lendingPool.liquidate(borrower, debtAmount);

        // Pay liquidator from backstop
        bytes32 seizureId = backstopPool.payLiquidator(msg.sender, debtAmount + (debtAmount * premium / 10000));

        // Reduce cross-chain position (oracle will execute actual seizure)
        collateralManager.reduceCrossChainPosition(borrower, positionIndex, seizeValueUSD);

        emit CrossChainLiquidation(
            borrower, msg.sender, positionIndex,
            debtAmount, seizeValueUSD, seizureId
        );
    }

    // ─── Concentration-Scaled Liquidation Bonus ───────────────────

    /// @notice Liquidation bonus scales with portfolio concentration
    /// @dev Concentrated = higher bonus (more risk). Diversified = lower bonus.
    ///      This incentivizes diversification: users get more borrowing power
    ///      AND lower liquidation penalty when diversified.
    function getLiquidationBonus(address borrower) public view returns (uint16) {
        uint256 concentration = collateralManager.getConcentrationDegree(borrower);

        // HHI 2500 (max diversified across 4 groups) → baseBonusBps (5%)
        // HHI 10000 (fully concentrated) → maxBonusBps (10%)
        if (concentration <= 2500) return baseBonusBps;
        if (concentration >= 10000) return maxBonusBps;

        return uint16(
            baseBonusBps + (concentration - 2500) * (maxBonusBps - baseBonusBps) / 7500
        );
    }

    // ─── View Functions ───────────────────────────────────────────

    function isLiquidatable(address user) external view returns (bool) {
        return lendingPool.getElasticHealthFactor(user) < lendingPool.HF_RED();
    }

    function getMaxLiquidation(address user) external view returns (uint256) {
        return lendingPool.getUserDebt(user) * maxLiquidationBps / 10000;
    }

    // ─── Admin ────────────────────────────────────────────────────

    function setMaxLiquidationBps(uint16 bps) external onlyRole(ENGINE_ADMIN) {
        maxLiquidationBps = bps;
    }

    function setBonusRange(uint16 baseBps, uint16 maxBps) external onlyRole(ENGINE_ADMIN) {
        baseBonusBps = baseBps;
        maxBonusBps = maxBps;
    }
}
