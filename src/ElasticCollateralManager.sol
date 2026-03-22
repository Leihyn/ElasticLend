// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ElasticCollateralManager
/// @notice Portfolio-aware collateral management applying elastic restaking theory.
///
/// The elastic restaking paper (Bar-Zur & Eyal, ACM CCS 2025) proves that elastic
/// allocation — where remaining resources stretch to cover losses — is strictly more
/// robust than rigid allocation (Corollary 1).
///
/// We apply this to lending: a borrower's collateral portfolio maps to a validator's
/// stake allocation. Risk factors (ETH, BTC, STABLE) map to services. The paper's
/// security condition becomes our borrowing power calculation.
///
/// Rigid model (Aave): borrowingPower = Σ (value × fixedFactor)
///   Treats each asset independently. Ignores correlation.
///
/// Elastic model (ours): borrowingPower = totalCollateral - sqrt(Σ expectedLoss²)
///   Accounts for diversification. Correlated losses add linearly within groups.
///   Uncorrelated losses combine sub-linearly across groups (sqrt of sum of squares).
///   Diversified portfolios get MORE borrowing power. Concentrated ones get LESS.
contract ElasticCollateralManager is AccessControl {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Math for uint256;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ─── Risk Groups ──────────────────────────────────────────────
    // Assets in the same group are treated as perfectly correlated.
    // Assets in different groups are treated as uncorrelated.
    // This maps to the paper's "services" — each group is a service
    // that can independently fail (crash).

    enum RiskGroup { ETH, BTC, STABLE, OTHER }
    uint256 public constant NUM_RISK_GROUPS = 4;

    // ─── Token Configuration ──────────────────────────────────────

    struct TokenConfig {
        RiskGroup group;
        uint16 maxDropBps;       // Worst plausible crash in bps (5000 = 50%)
        uint16 rigidFactorBps;   // Fixed collateral factor for rigid comparison (7500 = 75%)
        address priceFeed;       // Chainlink-compatible price feed
        uint8 decimals;
        bool active;
    }

    // ─── Cross-Chain Position ─────────────────────────────────────
    // Attested by oracle. Maps to the paper's allocation w(v,s) from
    // a remote chain's escrow contract.

    struct CrossChainPosition {
        uint256 chainId;
        address token;
        uint256 balance;
        RiskGroup group;
        uint16 maxDropBps;
        uint256 valueUSD;        // 18 decimals (1e18 = $1)
        uint256 lastVerified;
    }

    // ─── Storage ──────────────────────────────────────────────────

    /// @notice Local collateral deposits: user => token => amount
    mapping(address => mapping(address => uint256)) public localDeposits;

    /// @notice Token configurations
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Supported local tokens
    EnumerableSet.AddressSet private _supportedTokens;

    /// @notice Cross-chain positions: user => positions array
    mapping(address => CrossChainPosition[]) public crossChainPositions;

    /// @notice Authorized liquidation engine
    address public liquidationEngine;

    /// @notice Lending pool for health factor checks on withdrawal
    address public lendingPool;

    /// @notice Cross-chain position staleness threshold
    uint256 public positionTTL = 1 hours;

    // ─── Events ───────────────────────────────────────────────────

    event LocalDeposited(address indexed user, address indexed token, uint256 amount);
    event LocalWithdrawn(address indexed user, address indexed token, uint256 amount);
    event CrossChainPositionAttested(
        address indexed user, uint256 chainId, address token,
        RiskGroup group, uint256 valueUSD
    );
    event CrossChainPositionRemoved(address indexed user, uint256 index);
    event TokenAdded(address indexed token, RiskGroup group, uint16 maxDropBps);

    // ─── Errors ───────────────────────────────────────────────────

    error TokenNotSupported(address token);
    error InsufficientBalance(uint256 available, uint256 requested);
    error ZeroAmount();
    error OnlyLiquidationEngine();
    error PositionStale(uint256 age, uint256 maxAge);
    error WithdrawalWouldUndercollaterlize();

    // ─── Constructor ──────────────────────────────────────────────

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, admin);
        _grantRole(ORACLE_ROLE, admin);
    }

    // ─── Admin ────────────────────────────────────────────────────

    function addToken(
        address token,
        RiskGroup group,
        uint16 maxDropBps,
        uint16 rigidFactorBps,
        address priceFeed,
        uint8 decimals_
    ) external onlyRole(MANAGER_ROLE) {
        tokenConfigs[token] = TokenConfig({
            group: group,
            maxDropBps: maxDropBps,
            rigidFactorBps: rigidFactorBps,
            priceFeed: priceFeed,
            decimals: decimals_,
            active: true
        });
        _supportedTokens.add(token);
        emit TokenAdded(token, group, maxDropBps);
    }

    function setLiquidationEngine(address engine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        liquidationEngine = engine;
    }

    function setLendingPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lendingPool = pool;
    }

    function setPositionTTL(uint256 ttl) external onlyRole(MANAGER_ROLE) {
        positionTTL = ttl;
    }

    // ─── Local Collateral ─────────────────────────────────────────

    function depositLocal(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!tokenConfigs[token].active) revert TokenNotSupported(token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        localDeposits[msg.sender][token] += amount;

        emit LocalDeposited(msg.sender, token, amount);
    }

    function withdrawLocal(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = localDeposits[msg.sender][token];
        if (balance < amount) revert InsufficientBalance(balance, amount);

        localDeposits[msg.sender][token] -= amount;

        // Check health factor remains safe after withdrawal
        if (lendingPool != address(0)) {
            uint256 hf = IHealthCheck(lendingPool).getElasticHealthFactor(msg.sender);
            // Must remain in GREEN zone (HF >= 1.3) after withdrawal
            if (hf < 1.3e18) revert WithdrawalWouldUndercollaterlize();
        }

        IERC20(token).safeTransfer(msg.sender, amount);

        emit LocalWithdrawn(msg.sender, token, amount);
    }

    /// @notice Seize local collateral during liquidation
    function seizeLocal(address borrower, address token, uint256 amount, address recipient) external {
        if (msg.sender != liquidationEngine) revert OnlyLiquidationEngine();
        uint256 balance = localDeposits[borrower][token];
        if (balance < amount) revert InsufficientBalance(balance, amount);

        localDeposits[borrower][token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);
    }

    // ─── Cross-Chain Positions ────────────────────────────────────

    /// @notice Oracle attests a cross-chain position
    /// @dev Same trust model for granting AND seizing — if we trust the oracle
    ///      to report balances for borrowing power, we trust it for liquidation.
    function attestCrossChainPosition(
        address user,
        uint256 chainId,
        address token,
        uint256 balance,
        RiskGroup group,
        uint16 maxDropBps,
        uint256 valueUSD
    ) external onlyRole(ORACLE_ROLE) {
        // Check if position already exists for this chain+token, update it
        CrossChainPosition[] storage positions = crossChainPositions[user];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].chainId == chainId && positions[i].token == token) {
                positions[i].balance = balance;
                positions[i].valueUSD = valueUSD;
                positions[i].lastVerified = block.timestamp;
                emit CrossChainPositionAttested(user, chainId, token, group, valueUSD);
                return;
            }
        }

        // New position
        positions.push(CrossChainPosition({
            chainId: chainId,
            token: token,
            balance: balance,
            group: group,
            maxDropBps: maxDropBps,
            valueUSD: valueUSD,
            lastVerified: block.timestamp
        }));

        emit CrossChainPositionAttested(user, chainId, token, group, valueUSD);
    }

    /// @notice Reduce a cross-chain position after seizure
    /// @dev Called by liquidation engine. Actual seizure executed by oracle on source chain.
    function reduceCrossChainPosition(address user, uint256 positionIndex, uint256 reduceValueUSD) external {
        if (msg.sender != liquidationEngine) revert OnlyLiquidationEngine();
        CrossChainPosition storage pos = crossChainPositions[user][positionIndex];
        if (reduceValueUSD >= pos.valueUSD) {
            pos.valueUSD = 0;
            pos.balance = 0;
        } else {
            // Proportionally reduce balance
            uint256 ratio = Math.mulDiv(reduceValueUSD, 1e18, pos.valueUSD);
            pos.balance -= Math.mulDiv(pos.balance, ratio, 1e18);
            pos.valueUSD -= reduceValueUSD;
        }
    }

    // ─── Elastic Borrowing Power (Paper's Core Contribution) ──────

    /// @notice Calculate elastic borrowing power using sqrt-of-sum-of-squares
    /// @dev Maps to the paper's security condition (Proposition 3):
    ///      For each risk factor, expected loss = exposure × maxDrop.
    ///      Rigid: totalLoss = Σ expectedLoss (assumes perfect correlation)
    ///      Elastic: totalLoss = sqrt(Σ expectedLoss²) (accounts for independence)
    ///      Borrowing power = totalCollateral - totalExpectedLoss
    function getElasticBorrowingPower(address user) public view returns (uint256) {
        uint256[4] memory groupValues = _getGroupValues(user);
        uint256 totalCollateral = groupValues[0] + groupValues[1] + groupValues[2] + groupValues[3];
        if (totalCollateral == 0) return 0;

        uint256 elasticLoss = _computeElasticLoss(groupValues);
        if (elasticLoss >= totalCollateral) return 0;
        return totalCollateral - elasticLoss;
    }

    /// @notice Calculate rigid borrowing power for comparison (Aave-style)
    /// @dev Same risk parameters, but losses summed linearly (assumes all correlated)
    function getRigidBorrowingPower(address user) public view returns (uint256) {
        uint256[4] memory groupValues = _getGroupValues(user);
        uint256 totalCollateral = groupValues[0] + groupValues[1] + groupValues[2] + groupValues[3];
        if (totalCollateral == 0) return 0;

        uint256 rigidLoss = _computeRigidLoss(groupValues);
        if (rigidLoss >= totalCollateral) return 0;
        return totalCollateral - rigidLoss;
    }

    /// @notice Get concentration degree (maps to paper's restaking degree)
    /// @dev HHI (Herfindahl-Hirschman Index) of the portfolio
    ///      10000 = fully concentrated (all in one group)
    ///      2500 = equally split across 4 groups
    function getConcentrationDegree(address user) public view returns (uint256) {
        uint256[4] memory groupValues = _getGroupValues(user);
        uint256 total = groupValues[0] + groupValues[1] + groupValues[2] + groupValues[3];
        if (total == 0) return 0;

        uint256 hhi = 0;
        for (uint256 i = 0; i < NUM_RISK_GROUPS; i++) {
            uint256 share = Math.mulDiv(groupValues[i], 10000, total);
            hhi += Math.mulDiv(share, share, 10000);
        }
        return hhi;
    }

    /// @notice Get the elastic expected loss for a user's portfolio
    function getElasticExpectedLoss(address user) external view returns (uint256) {
        return _computeElasticLoss(_getGroupValues(user));
    }

    /// @notice Get the rigid expected loss for a user's portfolio
    function getRigidExpectedLoss(address user) external view returns (uint256) {
        return _computeRigidLoss(_getGroupValues(user));
    }

    /// @notice Get collateral values grouped by risk factor
    function getGroupValues(address user) external view returns (uint256[4] memory) {
        return _getGroupValues(user);
    }

    /// @notice Get total collateral value (local + cross-chain)
    function getTotalCollateralUSD(address user) public view returns (uint256) {
        uint256[4] memory gv = _getGroupValues(user);
        return gv[0] + gv[1] + gv[2] + gv[3];
    }

    // ─── View Helpers ─────────────────────────────────────────────

    function getLocalDeposit(address user, address token) external view returns (uint256) {
        return localDeposits[user][token];
    }

    function getCrossChainPositionCount(address user) external view returns (uint256) {
        return crossChainPositions[user].length;
    }

    function getCrossChainPosition(address user, uint256 index)
        external view returns (CrossChainPosition memory)
    {
        return crossChainPositions[user][index];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return _supportedTokens.values();
    }

    // ─── Max Drop Getters per Group ───────────────────────────────

    function getGroupMaxDrop(RiskGroup group) public pure returns (uint16) {
        if (group == RiskGroup.ETH) return 5000;    // 50%
        if (group == RiskGroup.BTC) return 4500;    // 45%
        if (group == RiskGroup.STABLE) return 500;  // 5%
        return 6000;                                 // 60% for OTHER
    }

    // ─── Internal ─────────────────────────────────────────────────

    function _getGroupValues(address user) internal view returns (uint256[4] memory groupValues) {
        // Local collateral
        uint256 length = _supportedTokens.length();
        for (uint256 i = 0; i < length; i++) {
            address token = _supportedTokens.at(i);
            TokenConfig memory config = tokenConfigs[token];
            if (!config.active) continue;

            uint256 balance = localDeposits[user][token];
            if (balance == 0) continue;

            uint256 price = _getPrice(config.priceFeed);
            uint256 valueUSD = Math.mulDiv(balance, price, 10 ** config.decimals);
            groupValues[uint256(config.group)] += valueUSD;
        }

        // Cross-chain collateral
        CrossChainPosition[] storage positions = crossChainPositions[user];
        for (uint256 i = 0; i < positions.length; i++) {
            CrossChainPosition memory pos = positions[i];
            if (pos.valueUSD == 0) continue;

            // Check staleness
            uint256 age = block.timestamp - pos.lastVerified;
            if (age > positionTTL) continue; // Skip stale positions

            groupValues[uint256(pos.group)] += pos.valueUSD;
        }
    }

    /// @notice Elastic loss: sqrt(Σ loss²) — uncorrelated combination
    /// @dev This is the paper's key insight applied to lending.
    ///      Diversified portfolios have lower expected loss because
    ///      uncorrelated risks partially cancel out.
    function _computeElasticLoss(uint256[4] memory groupValues) internal pure returns (uint256) {
        uint256 sumOfSquares = 0;
        for (uint256 i = 0; i < NUM_RISK_GROUPS; i++) {
            uint16 maxDrop = _getGroupMaxDropByIndex(i);
            uint256 loss = Math.mulDiv(groupValues[i], maxDrop, 10000);
            sumOfSquares += loss * loss;
        }
        return _sqrt(sumOfSquares);
    }

    /// @notice Rigid loss: Σ loss — assumes all risks are perfectly correlated
    function _computeRigidLoss(uint256[4] memory groupValues) internal pure returns (uint256) {
        uint256 totalLoss = 0;
        for (uint256 i = 0; i < NUM_RISK_GROUPS; i++) {
            uint16 maxDrop = _getGroupMaxDropByIndex(i);
            totalLoss += Math.mulDiv(groupValues[i], maxDrop, 10000);
        }
        return totalLoss;
    }

    function _getGroupMaxDropByIndex(uint256 index) internal pure returns (uint16) {
        if (index == 0) return 5000;  // ETH: 50%
        if (index == 1) return 4500;  // BTC: 45%
        if (index == 2) return 500;   // STABLE: 5%
        return 6000;                   // OTHER: 60%
    }

    /// @notice Get price from Chainlink-compatible feed (8 decimals → 18 decimals)
    function _getPrice(address feed) internal view returns (uint256) {
        if (feed == address(0)) return 1e18; // Default $1 for stablecoins

        // Chainlink AggregatorV3Interface.latestRoundData()
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) return 0;
        return uint256(answer) * 1e10; // 8 decimals → 18 decimals
    }

    /// @notice Integer square root (Babylonian method)
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}

interface IAggregatorV3 {
    function latestRoundData()
        external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IHealthCheck {
    function getElasticHealthFactor(address user) external view returns (uint256);
}
