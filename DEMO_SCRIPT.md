# ElasticLend Demo Script

## Setup (before recording)

1. Open **http://localhost:3002**
2. Scroll to top
3. Figure 1: **5 ETH, 5000 USDC, 0.2 wBTC, 300 LINK** (all on Ethereum)
4. Figure 2: **all sliders at 0%**, debt at **$19,000**
5. Figure 3: not yet liquidated

## Verified Numbers

Portfolio: 5 ETH ($10,575) + 5000 USDC ($5,000) + 0.2 wBTC ($13,859) + 300 LINK ($2,679) = $32,113 total

Rigid BP: $18,732 | Elastic BP: $23,777 | Advantage: +26.9% | HHI: 3,259

| Debt | No Crash Rigid HF | No Crash Elastic HF | 40% ETH Crash Rigid HF | 40% ETH Crash Elastic HF |
|---|---|---|---|---|
| $18,000 | 1.04 SURVIVES | 1.32 SURVIVES | 0.92 LIQUIDATED | 1.15 SURVIVES |
| $19,000 | 0.99 LIQUIDATED | 1.25 SURVIVES | 0.87 LIQUIDATED | 1.09 SURVIVES |
| $20,000 | 0.94 LIQUIDATED | 1.19 SURVIVES | 0.83 LIQUIDATED | 1.03 SURVIVES |

## Two Demo Paths

### Path A: No Crash Needed (simplest, most dramatic)

Use debt **$19,000**. Both sliders at 0%. Rigid is already LIQUIDATED. Elastic SURVIVES. No crash required.

### Path B: Crash Demo (shows the divergence happening)

Use debt **$18,000**. Both SURVIVE initially. Drag ETH crash to 40%. Rigid drops to LIQUIDATED. Elastic stays SURVIVES.

Pick whichever feels better when you record. Both work.

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

> "300 LINK. Four risk groups. Elastic borrowing power: $23,777. Rigid: $18,732. That's a 27% advantage for the same collateral value. HHI concentration at 3,259, well diversified."

### [1:30 - 2:30] Figure 2: Crash Simulator

**If using Path A (no crash, debt $19,000):**

*Scroll to Figure 2. All sliders at 0%. Debt at $19,000.*

> "Now I borrow $19,000. Under the rigid model, this is more than the $18,732 borrowing power allows."

*Point at the gauges. Rigid: 0.99 LIQUIDATED. Elastic: 1.25 SURVIVES.*

> "No crash. No market event. The rigid model says this position is already liquidatable. The elastic model says it's healthy with a 1.25 health factor. Same collateral, same debt. The only difference is how the protocol measures diversified risk."

*Now drag ETH crash to 40%.*

> "And when ETH crashes 40%, the gap widens further. Rigid drops to 0.87. Elastic holds at 1.09. The diversification across BTC, USDC, and LINK absorbs the ETH shock."

**If using Path B (crash from safe, debt $18,000):**

*Scroll to Figure 2. All sliders at 0%. Debt at $18,000.*

> "I borrow $18,000. Both models say the position is safe. Rigid: 1.04. Elastic: 1.32. But look at how different the safety margins are."

*Slowly drag ETH crash slider to 40%.*

> "ETH crashes 40%. Watch the gauges."

*Point at rigid dropping below 1.0.*

> "Rigid: 0.92. Liquidated. Elastic: 1.15. Survives. Same portfolio, same crash, same debt. Rigid treats every asset independently and panics. Elastic sees the diversification and holds."

*Scroll down to the chart and summary cards.*

> "The chart shows it clearly. The rigid line crosses below the debt threshold. Elastic stays above."

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
| **1:30** | Debt $19K, no crash, rigid 0.99 LIQUIDATED, elastic 1.25 SURVIVES | "No crash. Rigid says liquidated. Elastic says healthy." |
| **2:00** | Drag ETH crash to 40%, rigid drops to 0.87, elastic holds at 1.09 | "Same crash. Rigid is liquidated. Elastic survives." |
| **2:45** | Click Liquidate Most Impaired, BP per dollar increases | "The collateral stretched. BP per dollar went up." |
