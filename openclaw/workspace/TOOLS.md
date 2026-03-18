# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.

### Polymarket Trading

A Polymarket MCP server is configured in mcporter as "polymarket". Use it to trade prediction markets and check portfolio.

**Common commands:**
- `mcporter call polymarket.get_all_positions` — Show all active positions
- `mcporter call polymarket.get_portfolio_value` — Get total portfolio value
- `mcporter call polymarket.get_pnl_summary` — Get P&L summary
- `mcporter call polymarket.search_markets query="search term"` — Search markets
- `mcporter call polymarket.get_trending_markets` — Get trending markets
- `mcporter call polymarket.create_limit_order market_id="..." side="BUY" price=0.50 size=5` — Place a trade
- `mcporter call polymarket.get_open_orders` — Check open orders
- `mcporter call polymarket.get_trade_history` — Get trade history

**Important:** Always use mcporter to call polymarket tools. The server runs locally via stdio from `/Users/philipp/polymarket-mcp-server`.

### Bankroll Management Rules (MANDATORY)

Before EVERY trade, you MUST follow these rules. No exceptions.

**Step 1: Check available bankroll**
Run `mcporter call polymarket.get_all_positions` and check USDC balance.
Available bankroll = USDC balance (not locked in positions).

**Step 2: Calculate position size**
- **Max per trade: 20% of available bankroll** (never more)
- **Reserve: always keep $0.50 minimum** for gas/fees
- **Max concurrent open positions: 3** at any time
- **If bankroll < $1.00: DO NOT TRADE** — tell Philipp to deposit more

**Step 3: Fractional Kelly sizing (optional refinement)**
```
edge = (estimated_win_prob × payout_odds) - 1
kelly_fraction = edge / (payout_odds - 1)
bet_size = bankroll × kelly_fraction × 0.5  (half-Kelly for safety)
bet_size = min(bet_size, bankroll × 0.20)   (cap at 20%)
```

**Step 4: Pre-trade checklist**
Before placing any order, verify ALL of these:
- [ ] Available bankroll checked (not stale — check right before trading)
- [ ] Bet size ≤ 20% of bankroll
- [ ] At least $0.50 remains after this trade
- [ ] Max 3 open positions not exceeded
- [ ] CLOB spread < 5%
- [ ] CLOB liquidity > $5K (real orders, not placeholders like 0.01/0.99)
- [ ] Market resolves within target timeframe

**Example with $5 bankroll:**
| Trade | Available | Max Bet (20%) | After Trade |
|-------|-----------|---------------|-------------|
| #1    | $5.00     | $1.00         | $4.00       |
| #2    | $4.00     | $0.80         | $3.20       |
| #3    | $3.20     | $0.64         | $2.56       |
| #4    | BLOCKED — 3 open positions, wait for resolution |

**After a win:** bankroll grows → bet sizes grow automatically.
**After a loss:** bankroll shrinks → bet sizes shrink automatically.
This prevents blowing up the account.

**ALWAYS tell Philipp on Telegram:**
- Before trade: "Planning: [market] [side] [shares] @ $[price] = $[total]. Bankroll: $[amount]. Confirm?"
- After trade: "Placed: [market] [side] [shares] @ $[price]. Remaining bankroll: $[amount]"
- On failure: "Skipped [market]: [reason — e.g. spread too wide, low liquidity, insufficient bankroll]"
