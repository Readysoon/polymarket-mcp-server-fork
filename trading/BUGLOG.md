
## 2026-03-25 — Polymarket CLOB Decimal Precision Bug

**Error:** `invalid amounts, the market buy orders maker amount supports a max accuracy of 2 decimals, taker amount a max of 4 decimals`

**Root Cause:** mcporter's `create_market_order` and `create_limit_order` both treat `size` as USDC amount. When size/price yields >4 decimal places for taker_amount, the CLOB API rejects the order.

**Example:** $10 at price 0.52 → taker = 10/0.52 = 19.2307692... → >4dp → REJECTED

**Fix:** Size must be a multiple of the ask price so that size/price yields ≤4 decimal places.
- For price=0.53: use multiples of 5.30 (→ 10.0 shares each)
- Formula: `size = N * price` where N is a positive integer

**Workaround applied:** Two FOK orders of $5.30 @ 0.53 instead of one $10.60 order.

**Also found:** mcporter `create_market_order` uses BID price (0.52) for BUY orders instead of ASK price (0.53), causing FOK failures when book only has asks. Use `create_limit_order` with explicit ask price instead.
