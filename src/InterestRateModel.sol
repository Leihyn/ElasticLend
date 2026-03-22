// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title InterestRateModel
/// @notice Utilization-based interest rate model with kink
/// @dev Uniform rate for all borrowers. Risk awareness manifests in collateral factors, not rates.
contract InterestRateModel {
    using Math for uint256;

    uint256 public constant BASE_RATE = 0.02e18;
    uint256 public constant SLOPE_1 = 0.20e18;
    uint256 public constant SLOPE_2 = 1.0e18;
    uint256 public constant OPTIMAL_UTILIZATION = 0.80e18;

    function getRate(uint256 totalBorrowed, uint256 totalDeposited) external pure returns (uint256 rate) {
        if (totalDeposited == 0) return BASE_RATE;

        uint256 utilization = Math.mulDiv(totalBorrowed, 1e18, totalDeposited);

        if (utilization <= OPTIMAL_UTILIZATION) {
            rate = BASE_RATE + Math.mulDiv(utilization, SLOPE_1, OPTIMAL_UTILIZATION);
        } else {
            rate = BASE_RATE + SLOPE_1
                + Math.mulDiv(utilization - OPTIMAL_UTILIZATION, SLOPE_2, 1e18 - OPTIMAL_UTILIZATION);
        }
    }
}
