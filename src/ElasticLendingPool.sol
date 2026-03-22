// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ElasticCollateralManager} from "./ElasticCollateralManager.sol";
import {InterestRateModel} from "./InterestRateModel.sol";

/// @title ElasticLendingPool
/// @notice ERC4626 vault where LPs deposit USDC and borrowers take loans against
///         elastic portfolio-aware collateral. Uses graduated health zones instead
///         of a binary liquidation threshold.
contract ElasticLendingPool is ERC4626, AccessControl, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant POOL_ADMIN_ROLE = keccak256("POOL_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    // ─── Health Zones ─────────────────────────────────────────────
    // Maps to the paper's robustness analysis: different levels of
    // security correspond to different protocol responses.

    enum HealthZone { RED, ORANGE, YELLOW, GREEN }

    uint256 public constant HF_RED = 1.0e18;       // Full liquidation
    uint256 public constant HF_ORANGE = 1.1e18;    // Partial liquidation
    uint256 public constant HF_YELLOW = 1.3e18;    // No new borrows
    // Above YELLOW = GREEN (full access)

    // ─── Storage ──────────────────────────────────────────────────

    ElasticCollateralManager public collateralManager;
    InterestRateModel public interestRateModel;

    uint256 public totalBorrowed;
    mapping(address => uint256) public userBorrowed;

    uint256 public lastAccrualTimestamp;
    uint256 public borrowIndex = 1e18;
    mapping(address => uint256) public userBorrowIndex;

    // ─── Events ───────────────────────────────────────────────────

    event Borrowed(address indexed user, uint256 amount, uint256 totalDebt);
    event Repaid(address indexed user, uint256 amount, uint256 remainingDebt);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debtRepaid);
    event InterestAccrued(uint256 interest, uint256 newBorrowIndex, uint256 utilization);

    // ─── Errors ───────────────────────────────────────────────────

    error InsufficientBorrowingPower(uint256 available, uint256 requested);
    error InsufficientPoolLiquidity(uint256 available, uint256 requested);
    error HealthFactorAboveMin(uint256 healthFactor);
    error BorrowingRestricted(HealthZone zone);
    error ZeroAmount();
    error NothingToRepay();

    // ─── Constructor ──────────────────────────────────────────────

    constructor(
        IERC20 asset_,
        address admin,
        address _collateralManager,
        address _interestRateModel
    ) ERC4626(asset_) ERC20("ElasticLend Vault Share", "elVAULT") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(LIQUIDATOR_ROLE, admin);

        collateralManager = ElasticCollateralManager(_collateralManager);
        interestRateModel = InterestRateModel(_interestRateModel);
        lastAccrualTimestamp = block.timestamp;
    }

    // ─── Interest Accrual ─────────────────────────────────────────

    function accrueInterest() public {
        if (block.timestamp <= lastAccrualTimestamp) return;

        uint256 timeElapsed = block.timestamp - lastAccrualTimestamp;
        uint256 totalAssets_ = totalAssets();
        uint256 annualRate = interestRateModel.getRate(totalBorrowed, totalAssets_);

        uint256 interest = Math.mulDiv(totalBorrowed, annualRate * timeElapsed, 365.25 days * 1e18);

        if (interest > 0) {
            totalBorrowed += interest;
            borrowIndex += Math.mulDiv(borrowIndex, annualRate * timeElapsed, 365.25 days * 1e18);
        }

        lastAccrualTimestamp = block.timestamp;
        uint256 utilization = totalAssets_ > 0 ? Math.mulDiv(totalBorrowed, 1e18, totalAssets_) : 0;
        emit InterestAccrued(interest, borrowIndex, utilization);
    }

    // ─── Borrowing ────────────────────────────────────────────────

    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        accrueInterest();

        // Check health zone — must be GREEN to borrow
        HealthZone zone = getHealthZone(msg.sender);
        if (zone != HealthZone.GREEN) revert BorrowingRestricted(zone);

        uint256 currentDebt = _getUserDebt(msg.sender);
        uint256 borrowingPower = collateralManager.getElasticBorrowingPower(msg.sender);

        uint256 assetDecimals = ERC20(asset()).decimals();
        uint256 newDebtNormalized = (currentDebt + amount) * (10 ** (18 - assetDecimals));

        if (newDebtNormalized > borrowingPower) {
            uint256 availableInAssetDecimals = borrowingPower / (10 ** (18 - assetDecimals));
            uint256 available = availableInAssetDecimals > currentDebt ? availableInAssetDecimals - currentDebt : 0;
            revert InsufficientBorrowingPower(available, amount);
        }

        uint256 poolBalance = IERC20(asset()).balanceOf(address(this));
        if (amount > poolBalance) revert InsufficientPoolLiquidity(poolBalance, amount);

        userBorrowed[msg.sender] += amount;
        userBorrowIndex[msg.sender] = borrowIndex;
        totalBorrowed += amount;

        IERC20(asset()).safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, currentDebt + amount);
    }

    function repay(uint256 amount) external nonReentrant whenNotPaused {
        accrueInterest();

        uint256 debt = _getUserDebt(msg.sender);
        if (debt == 0) revert NothingToRepay();

        uint256 repayAmount = amount == type(uint256).max ? debt : amount;
        if (repayAmount > debt) repayAmount = debt;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), repayAmount);

        userBorrowed[msg.sender] = debt - repayAmount;
        userBorrowIndex[msg.sender] = borrowIndex;
        totalBorrowed -= repayAmount > totalBorrowed ? totalBorrowed : repayAmount;

        emit Repaid(msg.sender, repayAmount, debt - repayAmount);
    }

    // ─── Liquidation ──────────────────────────────────────────────

    /// @notice Called by LiquidationEngine to repay debt on behalf of borrower
    function liquidate(address user, uint256 debtAmount) external nonReentrant whenNotPaused {
        accrueInterest();

        uint256 healthFactor = getElasticHealthFactor(user);
        if (healthFactor >= HF_RED) revert HealthFactorAboveMin(healthFactor);

        uint256 userDebt = _getUserDebt(user);
        uint256 repayAmount = debtAmount > userDebt ? userDebt : debtAmount;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), repayAmount);

        userBorrowed[user] = userDebt - repayAmount;
        userBorrowIndex[user] = borrowIndex;
        totalBorrowed -= repayAmount > totalBorrowed ? totalBorrowed : repayAmount;

        emit Liquidated(user, msg.sender, repayAmount);
    }

    // ─── Health Factor ────────────────────────────────────────────

    /// @notice Elastic health factor: borrowingPower / debt
    /// @dev Uses the elastic model — diversified portfolios have higher health factors
    function getElasticHealthFactor(address user) public view returns (uint256) {
        uint256 debt = _getUserDebt(user);
        if (debt == 0) return type(uint256).max;

        uint256 borrowingPower = collateralManager.getElasticBorrowingPower(user);
        uint256 assetDecimals = ERC20(asset()).decimals();
        uint256 debtNormalized = debt * (10 ** (18 - assetDecimals));

        return Math.mulDiv(borrowingPower, 1e18, debtNormalized);
    }

    /// @notice Rigid health factor for comparison
    function getRigidHealthFactor(address user) public view returns (uint256) {
        uint256 debt = _getUserDebt(user);
        if (debt == 0) return type(uint256).max;

        uint256 borrowingPower = collateralManager.getRigidBorrowingPower(user);
        uint256 assetDecimals = ERC20(asset()).decimals();
        uint256 debtNormalized = debt * (10 ** (18 - assetDecimals));

        return Math.mulDiv(borrowingPower, 1e18, debtNormalized);
    }

    /// @notice Graduated health zone
    function getHealthZone(address user) public view returns (HealthZone) {
        uint256 hf = getElasticHealthFactor(user);
        if (hf < HF_RED) return HealthZone.RED;
        if (hf < HF_ORANGE) return HealthZone.ORANGE;
        if (hf < HF_YELLOW) return HealthZone.YELLOW;
        return HealthZone.GREEN;
    }

    // ─── View Functions ───────────────────────────────────────────

    function getUserDebt(address user) external view returns (uint256) {
        return _getUserDebt(user);
    }

    function getUtilization() public view returns (uint256) {
        uint256 totalAssets_ = totalAssets();
        if (totalAssets_ == 0) return 0;
        return Math.mulDiv(totalBorrowed, 1e18, totalAssets_);
    }

    function getBorrowRate() public view returns (uint256) {
        return interestRateModel.getRate(totalBorrowed, totalAssets());
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalBorrowed;
    }

    // ─── Admin ────────────────────────────────────────────────────

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function setCollateralManager(address cm) external onlyRole(POOL_ADMIN_ROLE) {
        collateralManager = ElasticCollateralManager(cm);
    }

    function setInterestRateModel(address model) external onlyRole(POOL_ADMIN_ROLE) {
        interestRateModel = InterestRateModel(model);
    }

    // ─── Internal ─────────────────────────────────────────────────

    function _getUserDebt(address user) internal view returns (uint256) {
        uint256 principal = userBorrowed[user];
        if (principal == 0) return 0;

        uint256 userIndex = userBorrowIndex[user];
        if (userIndex == 0) return principal;

        return Math.mulDiv(principal, borrowIndex, userIndex);
    }
}
