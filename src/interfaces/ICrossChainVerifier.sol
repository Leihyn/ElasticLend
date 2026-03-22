// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICrossChainVerifier
/// @notice Interface for cross-chain balance verification
/// @dev Implement with Hyperbridge, CCIP, LayerZero, or admin attestation
interface ICrossChainVerifier {
    function getVerifiedBalance(
        address user,
        uint256 chainId,
        address token
    ) external view returns (uint256 balance, uint256 valueUSD, uint256 lastVerified);
}
