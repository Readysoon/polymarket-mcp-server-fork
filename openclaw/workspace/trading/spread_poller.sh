#!/bin/bash
# Event Sniper - Dynamic Spread Poller
# Runs every 30min, checks markets closing in next 6h
# Runs production bot first, then all swarm bots from population.json

cd /polymarket

SWARM_DIR="/home/node/.openclaw/workspace/swarm"
POP_FILE="$SWARM_DIR/population.json"
GENESIS_FILE="$SWARM_DIR/genesis.json"

# Run swarm bots if population exists
if [ -f "$POP_FILE" ] || [ -f "$GENESIS_FILE" ]; then
    SOURCE="${POP_FILE:-$GENESIS_FILE}"
    BOT_IDS=$(python3 -c "import json; d=json.load(open('$SOURCE')); [print(b['id']) for b in d['bots']]" 2>/dev/null)
    for BOT_ID in $BOT_IDS; do
        bash "$SWARM_DIR/bot_runner.sh" "$BOT_ID" 2>&1
    done
fi

# Then run production bot (uses trading/config.json)

python3 << 'PYEOF'
import json, subprocess, sys
from datetime import datetime, timezone, timedelta

WORKSPACE = '/home/node/.openclaw/workspace/trading'

with open(f'{WORKSPACE}/config.json') as f:
    config = json.load(f)

with open(f'{WORKSPACE}/watchlist.json') as f:
    watchlist = json.load(f)

with open(f'{WORKSPACE}/journal.json') as f:
    journal = json.load(f)

now = datetime.now(timezone.utc)
window_end = now + timedelta(hours=6)

max_spread = config['max_spread']
min_price = config['min_yes_price']
max_price = config['max_yes_price']
bet_pct = config.get('bet_pct_of_balance', 0.12)
min_bet = config.get('min_bet_usd', 0.50)
max_bet_cap = config.get('max_bet_usd', 25)
stop_drawdown_24h = config.get('stop_drawdown_24h_pct', 0.30)

def mcporter(tool, **kwargs):
    args = ['mcporter', 'call', f'polymarket.{tool}']
    for k, v in kwargs.items():
        args.append(f'{k}={json.dumps(v) if isinstance(v, (dict,list)) else str(v)}')
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(r.stdout)
    except:
        return {'error': r.stdout + r.stderr}

# Get total portfolio value (cash + open positions)
portfolio = mcporter('get_portfolio_value', include_breakdown=False)
balance = 0.0
if isinstance(portfolio, dict):
    raw = str(portfolio)
    # Try total portfolio value first, then fall back to cash
    for key in ('TOTAL PORTFOLIO VALUE', 'total_portfolio_value', 'total_value',
                'Cash Balance (USDC)', 'cash_balance', 'usdc', 'balance'):
        val = portfolio.get(key)
        if val is not None:
            try:
                balance = float(str(val).replace('$','').replace(',',''))
                break
            except:
                pass
    # If still 0, try parsing the raw string for a dollar amount
    if balance == 0:
        import re
        matches = re.findall(r'\$(\d+\.?\d*)', raw)
        if matches:
            balance = max(float(m) for m in matches)

if balance < min_bet:
    print(f"STOP: balance ${balance:.2f} too low to place minimum bet ${min_bet}")
    sys.exit(0)

# Dynamic bet size = 12% of balance, capped
bet_size = round(min(max(balance * bet_pct, min_bet), max_bet_cap), 2)
print(f"Balance: ${balance:.2f} → bet size: ${bet_size:.2f} ({bet_pct*100:.0f}%)")

# 24h drawdown check
now_ts = now.timestamp()
cutoff_24h = now_ts - 86400
recent_trades = [t for t in journal.get('trades', [])
    if t.get('status') == 'open' or t.get('pnl') is not None]
recent_pnl = sum(
    t.get('pnl', 0) or 0
    for t in recent_trades
    if t.get('timestamp') and
    datetime.fromisoformat(t['timestamp'].replace('Z','+00:00')).timestamp() > cutoff_24h
)
recent_invested = sum(
    t.get('size_usd', 0)
    for t in recent_trades
    if t.get('timestamp') and
    datetime.fromisoformat(t['timestamp'].replace('Z','+00:00')).timestamp() > cutoff_24h
)
if recent_invested > 0:
    drawdown_24h = -recent_pnl / recent_invested
    if drawdown_24h > stop_drawdown_24h:
        print(f"STOP: 24h drawdown {drawdown_24h:.1%} exceeds limit {stop_drawdown_24h:.1%} — pausing trading")
        print(f"ALERT: notify Philipp")
        sys.exit(0)

traded = []
skipped = []
not_ready = []

for market in watchlist.get('markets', []):
    if market.get('status') in ('traded', 'skipped_permanent'):
        continue

    try:
        end_dt = datetime.fromisoformat(market['end_datetime'].replace('Z', '+00:00'))
    except:
        continue

    # Only check markets closing within 6h window
    if end_dt > window_end or end_dt < now:
        continue

    hours_left = (end_dt - now).total_seconds() / 3600

    # Too close — skip permanently
    if hours_left < 0.1:
        market['status'] = 'skipped_permanent'
        continue

    token_ids = market.get('clob_token_ids', [])
    if not token_ids:
        continue

    yes_token = token_ids[0]

    # Check live spread
    ob = mcporter('get_orderbook', token_id=yes_token, depth=3)

    if 'error' in ob or not ob.get('bids') or not ob.get('asks'):
        not_ready.append(f"{market['question'][:45]} ({hours_left:.1f}h left) — no orderbook")
        continue

    bids = ob['bids']
    asks = ob['asks']

    def price(e):
        return float(e['price']) if isinstance(e, dict) else float(getattr(e, 'price', 0))

    best_bid = price(bids[0])
    best_ask = price(asks[0])
    spread = best_ask - best_bid
    mid = (best_bid + best_ask) / 2

    # Spread still too wide — market not ready yet
    if spread > max_spread:
        not_ready.append(f"{market['question'][:45]} ({hours_left:.1f}h left) — spread {spread:.3f}")
        continue

    # Price out of range
    if not (min_price <= mid <= max_price):
        market['status'] = 'skipped_permanent'
        skipped.append(f"Price {mid:.2f} out of range: {market['question'][:45]}")
        continue

    # ✅ Spread is tight — place the bet
    result = mcporter('create_limit_order',
        market_id=market['condition_id'],
        side='BUY',
        price=round(best_ask, 2),
        size=bet_size
    )

    if result.get('success'):
        market['status'] = 'traded'
        trade = {
            'timestamp': now.isoformat(),
            'question': market['question'],
            'condition_id': market['condition_id'],
            'side': 'BUY YES',
            'price': best_ask,
            'spread_at_entry': spread,
            'hours_before_close': round(hours_left, 2),
            'size_usd': bet_size,
            'shares': round(bet_size / best_ask, 2),
            'end_date': market['end_date'],
            'order_id': result.get('order_id'),
            'status': 'open',
            'pnl': None
        }
        journal['trades'].append(trade)
        journal['summary']['total_invested'] = round(
            journal['summary']['total_invested'] + bet_size, 2)
        traded.append(f"✅ {market['question'][:50]} @ {best_ask:.2f} — ${bet_size:.2f} (bal ${balance:.2f}, {hours_left:.1f}h left)")
    else:
        err = result.get('error', '?')[:50]
        skipped.append(f"Order failed ({err}): {market['question'][:35]}")

# Save
with open(f'{WORKSPACE}/watchlist.json', 'w') as f:
    json.dump(watchlist, f, indent=2)

with open(f'{WORKSPACE}/journal.json', 'w') as f:
    json.dump(journal, f, indent=2)

# Output
if traded:
    for t in traded:
        print(f"TRADED:{t}")

if not_ready:
    print(f"NOT_READY:{len(not_ready)} markets in window, spread still wide")
    for n in not_ready:
        print(f"  - {n}")

if skipped:
    for s in skipped:
        print(f"SKIPPED:{s}")

if not traded and not not_ready:
    print("IDLE: no markets in 6h window")

PYEOF
