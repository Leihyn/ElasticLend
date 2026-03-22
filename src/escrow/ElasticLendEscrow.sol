// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ElasticLendEscrow
/// @notice Holds yield-bearing tokens on source chains (Ethereum, Arbitrum, etc.).
///         Tokens keep earning yield while deposited. The oracle on the hub chain
///         reads balances and can trigger seizure for liquidation.
///
///         Deployed once per source chain. Protocol-agnostic — holds any ERC-20.
///
///         Trust model: the oracle role can seize deposits. This is consistent with
///         the attestation model — if we trust the oracle to report balances for
///         granting borrowing power, we trust it to execute seizure when positions
///         are underwater. Same trust assumption, both directions.
///
///         Emergency withdrawal: 7-day timelock if oracle disappears. Users are
///         never permanently locked out.
contract ElasticLendEscrow is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    uint256 public constant EMERGENCY_DELAY = 7 days;

    // ─── Storage ──────────────────────────────────────────────────

    /// @notice User deposits: user => token => amount
    mapping(address => mapping(address => uint256)) public deposits;

    /// @notice Emergency withdrawal requests: user => timestamp (0 = none)
    mapping(address => uint256) public emergencyRequests;

    // ─── Events ───────────────────────────────────────────────────

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Seized(address indexed user, address indexed token, uint256 amount, address indexed recipient);
    event EmergencyRequested(address indexed user, uint256 unlockTime);
    event EmergencyCancelled(address indexed user);
    event EmergencyWithdrawn(address indexed user, address indexed token, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientDeposit(uint256 available, uint256 requested);
    error NoEmergencyRequest();
    error EmergencyNotReady(uint256 unlockTime);

    // ─── Constructor ──────────────────────────────────────────────

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ROLE, admin);
    }

    // ─── Deposit ──────────────────────────────────────────────────

    /// @notice Deposit tokens into escrow for cross-chain collateral
    /// @dev Tokens keep earning yield (aTokens rebase, vault shares accrue)
    function deposit(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][token] += amount;

        // Cancel any pending emergency withdrawal
        if (emergencyRequests[msg.sender] != 0) {
            delete emergencyRequests[msg.sender];
            emit EmergencyCancelled(msg.sender);
        }

        emit Deposited(msg.sender, token, amount);
    }

    // ─── Seizure (Oracle-Mediated) ────────────────────────────────

    /// @notice Seize collateral during cross-chain liquidation
    /// @dev Called by oracle after hub chain requests seizure.
    ///      Same trust model as balance attestation — symmetric trust.
    function seize(
        address user,
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(ORACLE_ROLE) nonReentrant {
        uint256 available = deposits[user][token];
        if (available < amount) revert InsufficientDeposit(available, amount);

        deposits[user][token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);

        emit Seized(user, token, amount, recipient);
    }

    // ─── Emergency Withdrawal ─────────────────────────────────────

    /// @notice Request emergency withdrawal (7-day delay)
    function requestEmergencyWithdrawal() external {
        emergencyRequests[msg.sender] = block.timestamp;
        emit EmergencyRequested(msg.sender, block.timestamp + EMERGENCY_DELAY);
    }

    /// @notice Execute emergency withdrawal after delay
    function executeEmergencyWithdrawal(address token, uint256 amount) external nonReentrant {
        uint256 requestTime = emergencyRequests[msg.sender];
        if (requestTime == 0) revert NoEmergencyRequest();
        if (block.timestamp < requestTime + EMERGENCY_DELAY) {
            revert EmergencyNotReady(requestTime + EMERGENCY_DELAY);
        }

        uint256 available = deposits[msg.sender][token];
        if (available < amount) revert InsufficientDeposit(available, amount);

        deposits[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit EmergencyWithdrawn(msg.sender, token, amount);
    }

    // ─── View ─────────────────────────────────────────────────────

    function getDeposit(address user, address token) external view returns (uint256) {
        return deposits[user][token];
    }
}
