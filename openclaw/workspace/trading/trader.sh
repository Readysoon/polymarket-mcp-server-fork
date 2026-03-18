#!/bin/bash
# Event Sniper - Pre-Event Trader
# Checks watchlist, verifies CLOB spread, places bets

WORKSPACE="/home/node/.openclaw/workspace/trading"

python3 << 'PYEOF'
import json, subprocess, sys
from datetime import datetime, timezone, timedelta

with open('/home/node/.openclaw/workspace/trading/config.json') as f:
    config = json.load(f)

with open('/home/node/.openclaw/workspace/trading/watchlist.json') as f:
    watchlist = json.load(f)

with open('/home/node/.openclaw/workspace/trading/journal.json') as f:
    journal = json.load(f)

now = datetime.now(timezone.utc)
max_bet = config['max_bet_usd']
max_spread = config['max_spread']
min_price = config['min_yes_price']
max_price = config['max_yes_price']

def mcporter(tool, **kwargs):
    args = ['mcporter', 'call', f'polymarket.{tool}']
    for k, v in kwargs.items():
        args.append(f'{k}={v}')
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(result.stdout)
    except:
        return {'error': result.stdout + result.stderr}

placed = []
skipped = []

for market in watchlist.get('markets', []):
    if market.get('status') in ('traded', 'skipped_permanent'):
        continue

    try:
        end_dt = datetime.fromisoformat(market['end_datetime'].replace('Z', '+00:00'))
    except:
        continue

    hours_left = (end_dt - now).total_seconds() / 3600

    # Only act when within 6 hours of closing
    if hours_left > 6:
        continue

    if hours_left < 0.25:
        market['status'] = 'skipped_permanent'
        skipped.append(f"Too late: {market['question'][:50]}")
        continue

    # Check live orderbook spread
    token_ids = market.get('clob_token_ids', [])
    if not token_ids:
        continue

    yes_token = token_ids[0]
    ob = mcporter('get_orderbook', token_id=yes_token, depth=3)
    
    if 'error' in ob or not ob.get('bids') or not ob.get('asks'):
        skipped.append(f"No orderbook: {market['question'][:50]}")
        continue

    best_bid = float(ob['bids'][0]['price'])
    best_ask = float(ob['asks'][0]['price'])
    spread = best_ask - best_bid
    mid = (best_bid + best_ask) / 2

    if spread > max_spread:
        skipped.append(f"Wide spread ({spread:.3f}): {market['question'][:50]}")
        continue

    if not (min_price <= mid <= max_price):
        skipped.append(f"Price out of range ({mid:.2f}): {market['question'][:50]}")
        continue

    # Place the bet
    result = mcporter('create_limit_order',
        market_id=market['condition_id'],
        side='BUY',
        price=round(best_ask, 2),
        size=max_bet
    )

    if result.get('success'):
        market['status'] = 'traded'
        trade = {
            'timestamp': now.isoformat(),
            'question': market['question'],
            'condition_id': market['condition_id'],
            'side': 'BUY YES',
            'price': best_ask,
            'size_usd': max_bet,
            'shares': round(max_bet / best_ask, 2),
            'end_date': market['end_date'],
            'order_id': result.get('order_id'),
            'status': 'open'
        }
        journal['trades'].append(trade)
        journal['summary']['total_invested'] += max_bet
        placed.append(f"✅ BET PLACED: {market['question'][:50]} @ {best_ask:.2f} (${max_bet})")
    else:
        skipped.append(f"Order failed ({result.get('error','?')[:40]}): {market['question'][:40]}")

# Save updated files
with open('/home/node/.openclaw/workspace/trading/watchlist.json', 'w') as f:
    json.dump(watchlist, f, indent=2)

with open('/home/node/.openclaw/workspace/trading/journal.json', 'w') as f:
    json.dump(journal, f, indent=2)

# Output summary
if placed:
    for p in placed:
        print(p)
else:
    print("No trades placed this run.")

if skipped:
    print("\nSkipped:")
    for s in skipped:
        print(f"  - {s}")

PYEOF
