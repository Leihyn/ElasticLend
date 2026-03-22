# ElasticLend Demo Script

## Setup (before recording)

1. Open **http://localhost:3002**
2. Scroll to top
3. Figure 1: **5 ETH, 5000 USDC, 0.2 wBTC, 300 LINK** (all on Ethereum)
4. Figure 2: **all sliders at 0%**, debt at **$20,000**
5. Figure 3: not yet liquidated

## Recording + Voiceover

### [0:00 - 0:15] Hero

*Show the ElasticLend logo and title. Pause 2 seconds. Start scrolling.*

> "ElasticLend is a cross-chain lending protocol that applies elastic restaking theory to collateral management. Diversified portfolios get more borrowing power. Concentrated portfolios get less. No lending protocol does this today."

### [0:15 - 0:35] Abstract + Equations

*Scroll through the abstract. Pause briefly on the pull quote. Scroll past equations.*

> "The elastic restaking paper by Bar-Zur and Eyal proves that elastic allocation is strictly more robust than rigid. We discovered that lending collateral portfolios are structurally identical to restaking networks. The paper's theorems apply directly. Rigid models sum losses linearly. Elastic models take the square root of the sum of squares, compressing uncorrelated risk."

### [0:35 - 1:30] Figure 1: Portfolio Simulator

*Start with only ETH. Add tokens one by one.*

> "Here's how it works. I deposit 5 ETH, about $10,500."

*Point at rigid and elastic BP. They're equal.*

> "Single asset. Elastic and rigid borrowing power are the same. No diversification, no benefit."

*Click USDC. Type 5000.*

> "I add 5,000 USDC. Different risk group. Watch elastic jump while rigid grows proportionally."

*Click wBTC. Type 0.2.*

> "0.2 wBTC. Third risk group. The elastic advantage keeps growing."

*Click LINK. Type 300.*

> "300 LINK. Four risk groups. Elastic borrowing power: $23,777. Rigid: $18,732. That's a 27% advantage for the same collateral. HHI concentration at 3,259, well diversified."

### [1:30 - 2:30] Figure 2: Crash Simulator

*Scroll to Figure 2. All sliders at 0%. Debt at $20,000.*

> "Now I borrow $20,000. This is above rigid borrowing power but below elastic. Under the rigid model, this position is already over-leveraged."

*Point at the gauges: rigid LIQUIDATED, elastic SURVIVES.*

> "Before any crash happens, the models already disagree. Rigid says liquidated. Elastic says safe. The diversification is doing real work."

*Slowly drag ETH crash slider to 40%.*

> "Now ETH crashes 40%."

*Point at gauges diverging.*

> "Rigid drops further. Elastic holds. Same portfolio, same crash, same debt. Rigid is liquidated. Elastic survives."

*Scroll down to the chart and summary cards.*

> "The chart shows it clearly. The rigid line crosses below the debt threshold. Elastic stays above. Capital saved by the elastic model: $3,700."

### [2:30 - 3:10] Figure 3: Stretch Effect

*Scroll to Figure 3. Show the portfolio bars.*

> "One more thing. After partial liquidation, the elastic model does something no other protocol does."

*Point at BTC bar (43.2%, the most concentrated).*

> "BTC is the most concentrated position at 43%. Watch what happens when we liquidate it."

*Click "LIQUIDATE MOST IMPAIRED".*

> "50% of the BTC position is seized. But look at the BP per dollar metric. It went up. The remaining portfolio is now more diversified. The elastic model recognizes this improved risk profile. The collateral stretched. This is Section 3.4 of the paper: when a service fails, remaining allocations expand to cover surviving obligations."

### [3:10 - 3:25] Close

*Scroll past Table 1 briefly. Scroll back to hero.*

> "The contracts are deployed on Base Sepolia and Sepolia. Six smart contracts, 27 tests passing, tiered cross-chain liquidation with a backstop pool. $200 billion in DeFi lending uses rigid collateral factors. ElasticLend is the first protocol to apply elastic restaking theory to fix that."

## Three Money Shots

| Timestamp | What Happens | What to Say |
|---|---|---|
| **1:30** | Debt $20K, no crash, rigid LIQUIDATED, elastic SURVIVES | "Before any crash, the models already disagree" |
| **2:00** | ETH crash 40%, rigid drops further, elastic holds | "Same portfolio, same crash. Rigid is liquidated. Elastic survives." |
| **2:45** | Click Liquidate Most Impaired, BP per dollar increases | "The collateral stretched. BP per dollar went up." |
