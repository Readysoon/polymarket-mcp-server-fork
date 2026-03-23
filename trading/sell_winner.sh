#!/bin/bash
# sell_winner.sh — Checks all open positions every 5 min
# If price >= 0.95 → sell immediately (take profit)
# If price <= 0.05 → mark as lost (no action needed, position worthless)

TRADING_DIR="/home/node/.openclaw/workspace/trading"

python3 << 'PYEOF'
import json, subprocess, os
from datetime import datetime, timezone

TRADING_DIR = "/home/node/.openclaw/workspace/trading"
LOG_FILE = f"{TRADING_DIR}/log.json"
JOURNAL_FILE = f"{TRADING_DIR}/journal.json"
now = datetime.now(timezone.utc)

def mcporter(tool, **kwargs):
    args = ['mcporter', 'call', f'polymarket.{tool}', '--args', json.dumps(kwargs)]
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(r.stdout)
    except:
        return {'error': r.stdout + r.stderr}

def write_log(entry):
    try:
        with open(LOG_FILE) as f:
            log = json.load(f)
    except:
        log = []
    log.append(entry)
    with open(LOG_FILE, 'w') as f:
        json.dump(log, f, indent=2)

def update_journal(condition_id, outcome, pnl, pnl_pct, sell_price=None):
    try:
        with open(JOURNAL_FILE) as f:
            journal = json.load(f)
    except:
        journal = {'trades': []}
    for trade in journal.get('trades', []):
        if trade.get('condition_id') == condition_id and trade.get('status') == 'open':
            trade['status'] = outcome
            trade['outcome'] = outcome
            trade['pnl'] = round(pnl, 4)
            trade['pnl_pct'] = round(pnl_pct, 1)
            trade['resolved_at'] = now.isoformat()
            if sell_price:
                trade['sell_price'] = sell_price
            break
    with open(JOURNAL_FILE, 'w') as f:
        json.dump(journal, f, indent=2)

# Load open trades from journal
try:
    with open(JOURNAL_FILE) as f:
        journal = json.load(f)
except:
    journal = {'trades': []}

open_trades = [t for t in journal.get('trades', []) if t.get('status') == 'open']

if not open_trades:
    print("No open trades to monitor.")
    exit(0)

print(f"Monitoring {len(open_trades)} open positions...")

sold = []
lost = []

for trade in open_trades:
    condition_id = trade.get('condition_id', '')
    question = trade.get('question', '')[:50]
    yes_token = trade.get('yes_token', '')
    shares = float(trade.get('shares', 0))
    entry_price = float(trade.get('entry_price', trade.get('price', 0.5)))
    size_usd = float(trade.get('size_usd', 0))

    if not yes_token or shares <= 0:
        continue

    # Get current price
    price_data = mcporter('get_current_price', token_id=yes_token, side='BOTH')
    if 'error' in price_data:
        print(f"  SKIP (price error): {question}")
        continue

    bid = float(price_data.get('bid') or 0)
    ask = float(price_data.get('ask') or bid)
    # normalize
    if bid > ask:
        bid, ask = ask, bid
    current_price = (bid + ask) / 2

    print(f"  {question[:45]} | current={current_price:.3f} | entry={entry_price:.3f}")

    # TAKE PROFIT: price >= 0.95 → sell now
    if current_price >= 0.95:
        print(f"  → SELLING (price {current_price:.3f} >= 0.95)")
        result = mcporter('create_market_order',
            market_id=condition_id,
            side='SELL',
            size=float(shares)
        )
        if result.get('success') or result.get('order_id'):
            sell_value = shares * bid  # approximate
            pnl = sell_value - size_usd
            pnl_pct = (pnl / size_usd * 100) if size_usd > 0 else 0
            update_journal(condition_id, 'won', pnl, pnl_pct, sell_price=current_price)
            write_log({
                'timestamp': now.isoformat(),
                'question': question,
                'condition_id': condition_id,
                'result': 'SOLD',
                'sell_price': round(current_price, 4),
                'entry_price': entry_price,
                'shares': shares,
                'pnl': round(pnl, 4),
                'pnl_pct': round(pnl_pct, 1),
                'action': f'Take-profit sell @ {current_price:.3f}'
            })
            sold.append({'question': question, 'pnl': pnl, 'pnl_pct': pnl_pct, 'sell_price': current_price})
            print(f"  ✅ SOLD: {question} | P&L: +${pnl:.2f} (+{pnl_pct:.1f}%)")
        else:
            print(f"  ❌ SELL FAILED: {result}")

    # LOST: price <= 0.05
    elif current_price <= 0.05:
        pnl = -size_usd
        pnl_pct = -100.0
        update_journal(condition_id, 'lost', pnl, pnl_pct)
        write_log({
            'timestamp': now.isoformat(),
            'question': question,
            'condition_id': condition_id,
            'result': 'LOST',
            'sell_price': round(current_price, 4),
            'pnl': round(pnl, 4),
            'pnl_pct': -100.0,
            'action': 'Market resolved as lost'
        })
        lost.append({'question': question, 'pnl': pnl})
        print(f"  ❌ LOST: {question}")

# Output results for notification
if sold or lost:
    print("NOTIFY_NEEDED")
    for s in sold:
        print(f"SOLD|{s['question']}|{s['pnl']:.2f}|{s['pnl_pct']:.1f}|{s['sell_price']:.3f}")
    for l in lost:
        print(f"LOST|{l['question']}|{l['pnl']:.2f}")
else:
    print("NO_ACTION")

PYEOF
