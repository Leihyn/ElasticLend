// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BackstopPool
/// @notice USDC reserve for cross-chain liquidation payouts.
///         When a cross-chain liquidation triggers, the backstop pays the liquidator
///         instantly. The oracle later executes the seizure on the source chain and
///         replenishes the backstop.
///
///         Includes emergency mode: if backstop drops below threshold, cross-chain
///         features are frozen until replenished.
contract BackstopPool is AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant BACKSTOP_ADMIN = keccak256("BACKSTOP_ADMIN");
    bytes32 public constant LIQUIDATION_ENGINE = keccak256("LIQUIDATION_ENGINE");

    // ─── Storage ──────────────────────────────────────────────────

    IERC20 public immutable usdc;

    /// @notice Minimum backstop balance before emergency mode triggers
    uint256 public emergencyThreshold;

    /// @notice Total amount currently utilized (paid out, awaiting replenishment)
    uint256 public totalUtilized;

    /// @notice Pending seizures: commitment hash => amount
    mapping(bytes32 => PendingSeizure) public pendingSeizures;

    struct PendingSeizure {
        address liquidator;
        uint256 amount;
        uint256 timestamp;
    }

    // ─── Events ───────────────────────────────────────────────────

    event BackstopDeposited(address indexed depositor, uint256 amount);
    event LiquidatorPaid(address indexed liquidator, uint256 amount, bytes32 seizureId);
    event SeizureReplenished(bytes32 indexed seizureId, uint256 amount);
    event EmergencyThresholdUpdated(uint256 newThreshold);

    // ─── Errors ───────────────────────────────────────────────────

    error InsufficientBackstop(uint256 available, uint256 requested);
    error SeizureNotFound(bytes32 seizureId);
    error ZeroAmount();

    // ─── Constructor ──────────────────────────────────────────────

    constructor(address admin, address _usdc, uint256 _emergencyThreshold) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKSTOP_ADMIN, admin);
        usdc = IERC20(_usdc);
        emergencyThreshold = _emergencyThreshold;
    }

    // ─── Deposit ──────────────────────────────────────────────────

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit BackstopDeposited(msg.sender, amount);
    }

    // ─── Liquidation Payout ───────────────────────────────────────

    /// @notice Pay liquidator from backstop for cross-chain liquidation
    /// @return seizureId Unique ID for tracking the pending cross-chain seizure
    function payLiquidator(
        address liquidator,
        uint256 amount
    ) external onlyRole(LIQUIDATION_ENGINE) returns (bytes32 seizureId) {
        uint256 available = availableBalance();
        if (amount > available) revert InsufficientBackstop(available, amount);

        seizureId = keccak256(abi.encode(liquidator, amount, block.timestamp, block.number));

        pendingSeizures[seizureId] = PendingSeizure({
            liquidator: liquidator,
            amount: amount,
            timestamp: block.timestamp
        });

        totalUtilized += amount;
        usdc.safeTransfer(liquidator, amount);

        emit LiquidatorPaid(liquidator, amount, seizureId);
    }

    // ─── Replenishment ────────────────────────────────────────────

    /// @notice Oracle replenishes backstop after cross-chain seizure completes
    function replenish(bytes32 seizureId, uint256 amount) external onlyRole(BACKSTOP_ADMIN) {
        PendingSeizure memory seizure = pendingSeizures[seizureId];
        if (seizure.amount == 0) revert SeizureNotFound(seizureId);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUtilized -= seizure.amount > totalUtilized ? totalUtilized : seizure.amount;
        delete pendingSeizures[seizureId];

        emit SeizureReplenished(seizureId, amount);
    }

    // ─── View Functions ───────────────────────────────────────────

    function availableBalance() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function totalBalance() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + totalUtilized;
    }

    /// @notice Check if backstop is healthy (above emergency threshold)
    function isHealthy() public view returns (bool) {
        return availableBalance() >= emergencyThreshold;
    }

    /// @notice Dynamic premium: higher when backstop is stressed
    /// @return premiumBps Bonus in basis points (500 = 5% at full health, up to 1500 = 15%)
    function getDynamicPremium() public view returns (uint16) {
        uint256 total = totalBalance();
        if (total == 0) return 1500;

        uint256 utilization = Math.mulDiv(totalUtilized, 10000, total);
        // 500 bps (5%) at 0% utilization, up to 1500 bps (15%) at 100%
        return uint16(500 + Math.mulDiv(utilization, 1000, 10000));
    }

    // ─── Admin ────────────────────────────────────────────────────

    function setEmergencyThreshold(uint256 threshold) external onlyRole(BACKSTOP_ADMIN) {
        emergencyThreshold = threshold;
        emit EmergencyThresholdUpdated(threshold);
    }

    function grantLiquidationEngine(address engine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(LIQUIDATION_ENGINE, engine);
    }
}
