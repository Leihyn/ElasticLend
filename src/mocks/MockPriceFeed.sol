// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mock Chainlink price feed for testing
contract MockPriceFeed {
    int256 private _price;
    uint8 public decimals = 8;

    constructor(int256 initialPrice) {
        _price = initialPrice;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }
}
