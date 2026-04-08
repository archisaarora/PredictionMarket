# PredictionMarket

Base smart contract for a prediction market on **BNB Chain (EVM)** using native coin collateral (BNB/ETH style).

## Roles in this base

- 👷‍♂️ **Market Owner / Liquidity Provider**: deploys the market, seeds initial collateral + shares, can add/remove liquidity.
- 🧙 **Oracle**: resolves final outcome (`Yes` or `No`) after trading closes.
- 🙋‍♂️ **User**: buys/sells outcome tokens and redeems winning tokens after resolution.

## Core flow implemented

1. Deploy market with:
   - question,
   - oracle address,
   - trading end timestamp,
   - initial collateral (native coin via `msg.value`),
   - initial YES and NO share inventory.
2. Contract creates two ERC20 tokens:
   - `pYES`
   - `pNO`
3. Contract seeds AMM reserves with owner-provided collateral and initial YES/NO token inventory.
4. Owner can add/remove liquidity while market is open.
5. Users can buy/sell YES or NO tokens against the pool.
6. Oracle resolves the market after close.
7. Winning token holders redeem pro-rata collateral.

## Contract

- `contracts/PredictionMarket.sol`

## Notes

- This is a foundation contract intended for iterative expansion in later checkpoints.
- Before production, add oracle dispute flow, stronger LP constraints, comprehensive tests, and audits.
