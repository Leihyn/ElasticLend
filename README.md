# ElasticLend

## The Problem

A user deposits $100K in ETH across Ethereum and Arbitrum, plus $100K in stablecoins on Optimism. That's $200K in collateral across three chains. Every lending protocol today gives them roughly the same borrowing power as someone with $200K all in ETH on one chain.

But these two users are not equally risky. The diversified user survives a 50% ETH crash with $150K remaining. The concentrated user is left with $100K and is likely underwater. Current protocols can't tell the difference because they treat each collateral position independently.

## The Insight

Roi Bar-Zur's elastic restaking paper (ACM CCS 2025) proves that elastic allocation, where remaining resources stretch to cover losses after a failure, is strictly more robust than rigid allocation (Corollary 1).

We discovered that a lending protocol's collateral structure is isomorphic to a restaking network:

| Elastic Restaking (Paper) | ElasticLend (Our Application) |
|---|---|
| Restaking network G = (V, S, sigma, w, theta, pi) | Lending protocol L = (U, R, c, e, lambda, d) |
| Validator v | Borrower u |
| Service s | Risk factor (ETH, BTC, STABLE, OTHER) |
| Stake sigma(v) | Total collateral value c(u) |
| Allocation w(v,s) | Collateral exposure e(u,r) to risk factor r |
| Restaking degree: sum(w(v,s)) / sigma(v) | Concentration degree (HHI): sum(share_g^2) |
| Attack threshold theta(s) | Price drop threshold lambda(r) (maxDrop per risk group) |
| Attack prize pi(s) | Bad debt generated d(r) when risk factor crashes |
| Elastic slashing: sigma1 = max(0, sigma0 - sum(w0)) | Stretch effect: after liquidation, remaining collateral contributes more per dollar |
| Corollary 1: elastic strictly more expressive than atomic | Elastic BP > Rigid BP for all diversified portfolios |
| Proposition 3: security condition | Our borrowing power formula |

The paper's theorems apply directly. The security condition (Proposition 3) becomes our borrowing power calculation. The elastic slashing mechanism (Section 3.4) becomes our liquidation stretch effect.

## How It Works

### The Math

**Rigid model (Aave):** Every asset is assessed independently. Losses sum linearly. Assumes all risks are perfectly correlated.

```
BP_rigid = totalCollateral - sum(expectedLoss_g)

where expectedLoss_g = groupValue_g * maxDrop_g
```

**Elastic model (ElasticLend):** Assets are grouped by risk factor. Losses within the same group sum linearly (correlated). Losses across groups combine as the L2 norm (uncorrelated).

```
BP_elastic = totalCollateral - sqrt(sum(expectedLoss_g^2))

where expectedLoss_g = groupValue_g * maxDrop_g
```

The sqrt compresses uncorrelated risk. When assets are spread across groups, the combined expected loss is strictly less than the sum of individual losses. When concentrated in one group, elastic equals rigid.

### Risk Groups and Parameters

| Risk Group | maxDrop | Rationale |
|---|---|---|
| ETH | 50% | ETH has dropped 50%+ in May 2021, May 2022 |
| BTC | 45% | BTC historically drops slightly less than ETH |
| STABLE | 5% | USDC briefly depegged in March 2023 |
| OTHER | 60% | Alt tokens have higher volatility |

Assets within the same group are treated as perfectly correlated. ETH and wstETH are both in the ETH group. USDC and DAI are both in the STABLE group. Cross-group correlation is assumed to be zero. This assumption is conservative: empirical cross-group correlation is positive but low (typically 0.1 to 0.3), so the elastic model still outperforms rigid by 15 to 35% even with some cross-group correlation.

### Worked Example

```
Alice ($200K all ETH):
  Groups: ETH = $200K
  Expected loss: $200K * 50% = $100K
  Elastic loss:  sqrt($100K^2) = $100K  (same as rigid, no diversification)
  Borrowing power: $200K - $100K = $100K

Bob ($50K each in ETH/BTC/USDC/LINK):
  Groups: ETH = $50K, BTC = $50K, STABLE = $50K, OTHER = $50K
  Expected losses: $25K, $22.5K, $2.5K, $30K
  Rigid loss:   $25K + $22.5K + $2.5K + $30K = $80K
  Elastic loss:  sqrt($25K^2 + $22.5K^2 + $2.5K^2 + $30K^2) = $45.1K

  Rigid BP:   $200K - $80K = $120K
  Elastic BP: $200K - $45.1K = $154.9K

Bob gets 54% more elastic borrowing power than Alice.
Both have $200K in collateral. Bob is genuinely safer.
```

### Health Factor and Health Zones

```
Health Factor = Elastic Borrowing Power / Debt (normalized to 18 decimals)
```

The protocol uses graduated health zones instead of a binary liquidation threshold:

| Zone | Health Factor | Protocol Response |
|---|---|---|
| GREEN | >= 1.3 | Full access: borrow, withdraw |
| YELLOW | 1.1 to 1.3 | No new borrows allowed |
| ORANGE | 1.0 to 1.1 | Partial liquidation enabled |
| RED | < 1.0 | Full liquidation |

This gives borrowers time to add collateral before full liquidation, reducing bad debt events.

### Concentration Degree (HHI)

The Herfindahl-Hirschman Index measures portfolio concentration. It maps directly to the paper's restaking degree.

```
HHI = sum((groupValue_g / totalValue * 100)^2)

HHI = 10,000: everything in one group (maximum concentration)
HHI = 5,000:  split between two groups
HHI = 2,500:  equal split across four groups (maximum diversification)
```

HHI drives two mechanisms:
1. **Borrowing power**: lower HHI (diversified) = more elastic advantage
2. **Liquidation bonus**: lower HHI = lower bonus (5%), higher HHI = higher bonus (10%)

Both incentivize diversification.

## Cross-Chain Awareness

ElasticLend is deployed on one chain (hub) but knows about collateral on all chains. The elastic model treats all collateral, local and cross-chain, as one portfolio.

### How Cross-Chain Positions Enter the System

```
1. User deposits aETH into ElasticLendEscrow on Ethereum
   (tokens keep earning yield in escrow)

2. Oracle reads escrow balance on Ethereum

3. Oracle calls attestCrossChainPosition() on hub:
   - chainId: 1 (Ethereum)
   - token: aETH
   - balance: 25e18
   - riskGroup: ETH
   - valueUSD: $50,000

4. CollateralManager includes this in the elastic calculation
   alongside local deposits

5. Same sqrt-of-sum-of-squares math applies
   regardless of which chain the collateral lives on
```

### Trust Model

The oracle that attests cross-chain balances is the same entity trusted for cross-chain seizure during liquidation. Same trust assumption, both directions. If the protocol trusts the oracle enough to grant borrowing power based on its attestation, it trusts the oracle enough to execute seizure when the position is underwater.

Cross-chain positions have a staleness TTL (default 1 hour). Stale attestations are excluded from borrowing power calculations. This prevents borrowing against outdated cross-chain data.

In production, the oracle role is replaced by a bridge protocol (CCIP, LayerZero, Hyperbridge). The elastic math and liquidation logic don't change. Only the `ICrossChainVerifier` implementation changes.

## Architecture

```
                    CROSS-CHAIN FLOW

Source Chain                          Hub Chain (Base)
(Ethereum, Arbitrum, ...)

+---------------------------+         +----------------------------------------+
|    ElasticLendEscrow      |         |    ElasticCollateralManager            |
|                           |         |                                        |
|  User deposits            |         |  Local deposits:                       |
|  yield-bearing tokens     |  oracle |    user => token => amount             |
|  (aETH, vault shares)    |  attest |                                        |
|                           |-------->|  Cross-chain positions:                |
|  Tokens keep earning      |         |    user => [chainId, token, value,     |
|  yield in escrow          |         |             riskGroup, lastVerified]   |
|                           |         |                                        |
|  seize() called by        |<--------|  Elastic math:                         |
|  oracle during            | seizure |    1. Group all collateral by risk     |
|  liquidation              | request |    2. expectedLoss_g = value * maxDrop |
|                           |         |    3. elasticLoss = sqrt(sum(EL_g^2))  |
|  7-day emergency          |         |    4. BP = totalCollateral - elasticLoss|
|  withdrawal if oracle     |         |    5. HHI = sum(share_g^2)            |
|  disappears               |         |                                        |
+---------------------------+         +----+-----------------------------------+
                                           |
                                           | getBorrowingPower()
                                           | getHealthFactor()
                                           v
                                      +----------------------------------------+
                                      |    ElasticLendingPool (ERC-4626)       |
                                      |                                        |
                                      |  LPs deposit USDC --> vault shares     |
                                      |  Borrowers:                            |
                                      |    borrow() - check GREEN zone         |
                                      |    repay()  - reduce debt              |
                                      |                                        |
                                      |  Health zones: GREEN > YELLOW >        |
                                      |    ORANGE > RED                        |
                                      |                                        |
                                      |  Interest accrual:                     |
                                      |    Kink model (2% base, 20% slope1,   |
                                      |    100% slope2, 80% optimal util)     |
                                      |                                        |
                                      +----+-----------------------------------+
                                           |
                                           | liquidate()
                                           v
                                      +----------------------------------------+
                                      |    ElasticLiquidationEngine            |
                                      |                                        |
                                      |  TIER 1: Local (trustless, instant)    |
                                      |    liquidateLocal()                    |
                                      |    - seize local collateral tokens     |
                                      |    - transfer to liquidator            |
                                      |    - bonus from seized collateral      |
                                      |                                        |
                                      |  TIER 2: Cross-chain (oracle-mediated) |
                                      |    liquidateCrossChain()               |
                                      |    - liquidator repays debt on hub     |
                                      |    - backstop pays liquidator instantly|
                                      |    - emit CrossChainSeizureRequested   |
                                      |    - oracle executes on source chain   |
                                      |    - backstop replenished later        |
                                      |                                        |
                                      |  Bonus: 5% (diversified) to 10%       |
                                      |    (concentrated), scales with HHI    |
                                      |                                        |
                                      +----+-----------------------------------+
                                           |
                                           | payLiquidator()
                                           v
                                      +----------------------------------------+
                                      |    BackstopPool                        |
                                      |                                        |
                                      |  USDC reserve for cross-chain          |
                                      |  liquidation payouts                   |
                                      |                                        |
                                      |  Dynamic premium:                      |
                                      |    5% at 0% utilization                |
                                      |    10% at 50% utilization              |
                                      |    15% at 100% utilization             |
                                      |                                        |
                                      |  Emergency mode:                       |
                                      |    if balance < threshold,             |
                                      |    cross-chain liquidation blocked     |
                                      |                                        |
                                      +----------------------------------------+
```

### Contract Dependencies

```
ElasticCollateralManager
  --> InterestRateModel (yield-adjusted factors)
  --> Chainlink Price Feeds (token prices)
  --> IHealthCheck (LendingPool, for withdrawal safety)

ElasticLendingPool (ERC-4626)
  --> ElasticCollateralManager (borrowing power, health factor)
  --> InterestRateModel (borrow rates)

ElasticLiquidationEngine
  --> ElasticLendingPool (health factor check, debt repayment)
  --> ElasticCollateralManager (seize collateral, reduce cross-chain positions)
  --> BackstopPool (pay liquidator for cross-chain liquidation)

BackstopPool
  --> USDC (payout token)

ElasticLendEscrow (source chain)
  --> ORACLE_ROLE (attest balances, execute seizures)
```

## Tiered Liquidation (Deep Dive)

### Why Tiered?

Cross-chain collateral cannot be seized instantly. A message must travel from hub to source chain. During that time, prices can move further. Tiered liquidation minimizes cross-chain dependency:

1. **Exhaust local collateral first** (instant, trustless, no bridge needed)
2. **Only then request cross-chain seizure** (slower, oracle-mediated, backstop covers the gap)

### The Backstop Gap

When a cross-chain liquidation triggers, there's a time gap between paying the liquidator (instant, from backstop) and seizing the actual collateral (delayed, via oracle on source chain). During this gap:

- Backstop pool balance decreases
- Dynamic premium increases (incentivizing more liquidators)
- If backstop drops below emergency threshold, cross-chain liquidation is blocked
- Protocol falls back to local-only liquidation

### The Stretch Effect

After partial liquidation removes the most impaired collateral:

```
BEFORE: 50% ETH, 50% USDC
  HHI = 5,000
  BP per dollar = 72%

Liquidate 50% of ETH (the impaired asset):

AFTER: 33% ETH, 67% USDC
  HHI = 5,553 (more concentrated in stables, but stables are safe)
  BP per dollar = 83%  (+11 percentage points)
```

BP per dollar INCREASES because the portfolio rebalanced toward the safer asset class. The elastic model recognizes this improved risk profile. This is Section 3.4 of the paper: when a Byzantine service is removed, remaining allocations stretch to cover surviving obligations.

## Test Results

```
27 tests passed, 0 failed

Core thesis:
- Diversified gets 54% more borrowing power than concentrated (same collateral value)
- Cross-chain positions included in elastic calculation
- After 40% ETH crash: elastic HF=1.00, rigid HF=0.78 (rigid liquidated, elastic survives)
- Stretch effect: after partial liquidation, BP per dollar increases from 72% to 83%

Liquidation:
- Tiered: local first, then cross-chain
- Backstop pays liquidator $15,750 (verified USDC transfer)
- Emergency mode blocks cross-chain when backstop depleted
- Concentration-scaled bonus: 10% concentrated, 6.66% diversified
- Healthy positions cannot be liquidated

Safety:
- Unsafe withdrawal blocked (health factor check)
- Borrow blocked in non-GREEN zone
- Stale cross-chain attestations excluded from borrowing power
- Interest accrual: $30K grows to $31,053 after 1 year (3.5%)

Integration:
- Full end-to-end: escrow deposit -> attest -> borrow -> crash -> tiered liquidation -> stretch
- Multiple users: concentrated user liquidated, diversified user survives, others unaffected
```

## Deployed Contracts

### Base Sepolia (Hub Chain 84532)

| Contract | Address |
|---|---|
| CollateralManager | `0x15880a9E1719AAd5a37C99203c51C2E445651c94` |
| LendingPool | `0x412F577B7E4F8ac392BA9D8876d7A17e4891F6AB` |
| LiquidationEngine | `0x824d335886E8c516a121E2df59104F04cABAe30b` |
| BackstopPool | `0x2716c3E427B33c78d01e06a5Ba19A673EB5d898b` |
| InterestRateModel | `0x56B3D1AD2E803c893CC8ecfdA638d5979BA45291` |
| USDC (Mock) | `0x2C5Bedd15f3d40Da729A68D852E4f436dA14ef79` |
| WETH (Mock) | `0x83388045cab4caDc82ACfa99a63b17E6d4E5Cc87` |
| WBTC (Mock) | `0xb4A47F5D656C177be6cF4839551217f44cbb2Cb5` |
| LINK (Mock) | `0xcC86944f5E7385cA6Df8EEC5d40957840cfdfbb2` |

### Sepolia (Source Chain 11155111)

| Contract | Address |
|---|---|
| ElasticLendEscrow | `0x30dbD06059D2b339f1412f7CB368F3C7De68b3C7` |
| aETH (Mock) | `0x14b86EeE20bfC176B97657b492D56698F10C7964` |

## Frontend

Interactive research paper format with working elastic math. All calculations run client-side using the same sqrt-of-sum-of-squares formula as the smart contracts.

**Figure 1: Portfolio Simulator** Add/remove tokens, set amounts, select chains. See elastic vs rigid borrowing power, elastic advantage %, and HHI concentration update in real time.

**Figure 2: Crash Simulator** Four per-risk-group sliders (ETH, BTC, STABLE, OTHER). Dual health factor gauges showing rigid vs elastic diverging as you drag. Canvas chart with BP trajectories and debt threshold line.

**Figure 3: Stretch Effect** Horizontal bars per risk group. "Liquidate Most Impaired" button seizes 50% of the most concentrated group. Shows BP per dollar increasing after liquidation.

```bash
cd frontend/public
python3 -m http.server 3002
# Open http://localhost:3002
```

## Quick Start

```bash
# Install
forge install

# Test
forge test -vv

# Deploy hub (Base Sepolia)
PRIVATE_KEY=0x... forge script script/Deploy.s.sol \
  --rpc-url https://base-sepolia.gateway.tenderly.co \
  --broadcast --legacy

# Deploy escrow (Sepolia)
PRIVATE_KEY=0x... forge script script/DeployEscrow.s.sol \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --broadcast --legacy
```

## Project Structure

```
elastic-lend/
├── src/
│   ├── ElasticCollateralManager.sol   # Core: elastic math, risk groups, cross-chain positions
│   ├── ElasticLendingPool.sol         # ERC-4626 vault, borrow/repay, health zones
│   ├── ElasticLiquidationEngine.sol   # Tiered liquidation, concentration-scaled bonus
│   ├── BackstopPool.sol               # Cross-chain liquidation payout reserve
│   ├── InterestRateModel.sol          # Utilization-based kink model
│   ├── escrow/
│   │   └── ElasticLendEscrow.sol      # Source chain escrow, deposit/seize/emergency
│   ├── interfaces/
│   │   └── ICrossChainVerifier.sol    # Bridge-agnostic verification interface
│   └── mocks/
│       ├── MockERC20.sol
│       └── MockPriceFeed.sol
├── test/
│   ├── ElasticVsRigid.t.sol           # Core thesis: elastic > rigid
│   ├── IntegrationTest.t.sol          # Full cross-chain flow end-to-end
│   └── EdgeCases.t.sol                # Backstop, repay, multi-user, staleness, safety
├── script/
│   ├── Deploy.s.sol                   # Hub deployment (Base Sepolia)
│   └── DeployEscrow.s.sol             # Escrow deployment (Sepolia)
├── frontend/
│   └── public/
│       └── index.html                 # Interactive research paper frontend
├── slides/
│   └── deck.html                      # 10-slide presentation deck
└── README.md
```

## Paper Reference

Bar-Zur, R. and Eyal, I. "Elastic Restaking Networks: United we fall, (partially) divided we stand." ACM CCS 2025. [arXiv:2503.00170](https://arxiv.org/abs/2503.00170)

Code: [github.com/roibarzur/elastic-restaking-networks-code](https://github.com/roibarzur/elastic-restaking-networks-code)

## Built For

[Shape Rotator Virtual Hackathon](https://www.encodeclub.com/programmes/shape-rotator-virtual-hackathon) | IC3 / FlashbotsX / Encode Club

Track: DeFi, Security & Mechanism Design | Elastic Restaking (Roi Bar-Zur, Technion)
