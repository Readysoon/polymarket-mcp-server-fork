#!/bin/bash
# Market Watcher — single market, single run
# Args: <condition_id> <yes_token_id> <end_datetime> <question>
CONDITION_ID="${1}"
YES_TOKEN="${2}"
END_DATETIME="${3}"
QUESTION="${4}"

WORKSPACE="/home/node/.openclaw/workspace"
SWARM_DIR="$WORKSPACE/swarm"
TRADING_DIR="$WORKSPACE/trading"

python3 << PYEOF
import json, subprocess, sys, os
from datetime import datetime, timezone, timedelta

CONDITION_ID = "$CONDITION_ID"
YES_TOKEN = "$YES_TOKEN"
END_DATETIME = "$END_DATETIME"
QUESTION = "$QUESTION"
WORKSPACE = "$WORKSPACE"
SWARM_DIR = "$SWARM_DIR"
TRADING_DIR = "$TRADING_DIR"
LOG_FILE = f"{TRADING_DIR}/log.json"

now = datetime.now(timezone.utc)

# ── Log helper ──────────────────────────────────────────────────────────────
def write_log(entry):
    try:
        with open(LOG_FILE) as f:
            log = json.load(f)
    except:
        log = []
    log.append(entry)
    with open(LOG_FILE, 'w') as f:
        json.dump(log, f, indent=2)

def mcporter(tool, **kwargs):
    args = ['mcporter', 'call', f'polymarket.{tool}']
    for k, v in kwargs.items():
        args.append(f'{k}={json.dumps(v) if isinstance(v,(dict,list)) else str(v)}')
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(r.stdout)
    except:
        return {'error': r.stdout.strip() + r.stderr.strip()}

# ── Parse end time ───────────────────────────────────────────────────────────
try:
    end_dt = datetime.fromisoformat(END_DATETIME.replace('Z', '+00:00'))
except:
    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "result": "ERROR",
        "reason": f"bad end_datetime: {END_DATETIME}"
    }
    write_log(entry)
    print(f"ERROR: bad end_datetime {END_DATETIME}")
    sys.exit(1)

hours_left = (end_dt - now).total_seconds() / 3600

if hours_left < 0.1:
    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "end_datetime": END_DATETIME,
        "hours_left": round(hours_left, 2),
        "result": "EXPIRED",
        "reason": "Market already closed"
    }
    write_log(entry)
    print(f"EXPIRED: {QUESTION[:50]}")
    sys.exit(0)

# ── Check orderbook ──────────────────────────────────────────────────────────
ob = mcporter('get_orderbook', token_id=YES_TOKEN, depth=3)

if 'error' in ob or not ob.get('bids') or not ob.get('asks'):
    error_detail = ob.get('error', 'no bids/asks in orderbook')
    if hours_left > 1:
        fire_at = (now + timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
        job = {
            "name": f"watch:{CONDITION_ID[:16]}",
            "schedule": {"kind": "at", "at": fire_at},
            "payload": {
                "kind": "agentTurn",
                "message": f"Run market watcher for: {QUESTION[:60]}\n\nbash /home/node/.openclaw/workspace/trading/market_watcher.sh '{CONDITION_ID}' '{YES_TOKEN}' '{END_DATETIME}' '{QUESTION[:60]}'\n\nFor each line starting with TRADED: or ALERT: -> notify Philipp on Telegram\nFor everything else -> stay silent. Always send a full summary at the end.",
                "timeoutSeconds": 120
            },
            "sessionTarget": "isolated",
            "delivery": {"mode": "announce"}
        }
        subprocess.run(['openclaw', 'cron', 'add', '--json', json.dumps(job)], capture_output=True)
        entry = {
            "timestamp": now.isoformat(),
            "question": QUESTION,
            "condition_id": CONDITION_ID,
            "end_datetime": END_DATETIME,
            "hours_left": round(hours_left, 2),
            "result": "NOT_READY",
            "reason": f"No orderbook available: {error_detail}",
            "action": "Rescheduled retry in 30min"
        }
    else:
        entry = {
            "timestamp": now.isoformat(),
            "question": QUESTION,
            "condition_id": CONDITION_ID,
            "end_datetime": END_DATETIME,
            "hours_left": round(hours_left, 2),
            "result": "TIMEOUT",
            "reason": f"No orderbook and <1h left: {error_detail}",
            "action": "Abandoned"
        }
    write_log(entry)
    print(json.dumps(entry))
    sys.exit(0)

def price(e):
    return float(e['price']) if isinstance(e, dict) else float(getattr(e,'price',0))

best_bid = price(ob['bids'][0])
best_ask = price(ob['asks'][0])
spread = best_ask - best_bid
mid = (best_bid + best_ask) / 2

MAX_SPREAD = 0.05
if spread > MAX_SPREAD:
    if hours_left > 0.5:
        retry_mins = 30 if hours_left > 2 else 15
        fire_at = (now + timedelta(minutes=retry_mins)).strftime('%Y-%m-%dT%H:%M:%SZ')
        job = {
            "name": f"watch:{CONDITION_ID[:16]}",
            "schedule": {"kind": "at", "at": fire_at},
            "payload": {
                "kind": "agentTurn",
                "message": f"Run market watcher for: {QUESTION[:60]}\n\nbash /home/node/.openclaw/workspace/trading/market_watcher.sh '{CONDITION_ID}' '{YES_TOKEN}' '{END_DATETIME}' '{QUESTION[:60]}'\n\nFor each line starting with TRADED: or ALERT: -> notify Philipp on Telegram\nFor everything else -> stay silent. Always send a full summary at the end.",
                "timeoutSeconds": 120
            },
            "sessionTarget": "isolated",
            "delivery": {"mode": "announce"}
        }
        subprocess.run(['openclaw', 'cron', 'add', '--json', json.dumps(job)], capture_output=True)
        entry = {
            "timestamp": now.isoformat(),
            "question": QUESTION,
            "condition_id": CONDITION_ID,
            "end_datetime": END_DATETIME,
            "hours_left": round(hours_left, 2),
            "best_bid": best_bid,
            "best_ask": best_ask,
            "spread": round(spread, 4),
            "mid": round(mid, 4),
            "max_spread_allowed": MAX_SPREAD,
            "result": "NOT_READY",
            "reason": f"Spread {spread:.4f} > max {MAX_SPREAD}",
            "action": f"Rescheduled retry in {retry_mins}min"
        }
    else:
        entry = {
            "timestamp": now.isoformat(),
            "question": QUESTION,
            "condition_id": CONDITION_ID,
            "end_datetime": END_DATETIME,
            "hours_left": round(hours_left, 2),
            "best_bid": best_bid,
            "best_ask": best_ask,
            "spread": round(spread, 4),
            "mid": round(mid, 4),
            "result": "TIMEOUT",
            "reason": f"Spread {spread:.4f} still too wide and <30min left",
            "action": "Abandoned"
        }
    write_log(entry)
    print(json.dumps(entry))
    sys.exit(0)

# ── Spread OK — attempt trade ────────────────────────────────────────────────
# Load config
with open(f'{TRADING_DIR}/config.json') as f:
    prod_config = json.load(f)

min_p = prod_config.get('min_yes_price', 0.55)
max_p = prod_config.get('max_yes_price', 0.80)
max_s = prod_config.get('max_spread', 0.03)
balance_threshold = prod_config.get('balance_threshold', 50)
bet_pct_small = prod_config.get('bet_pct_small', 0.50)
bet_pct_normal = prod_config.get('bet_pct_normal', 0.20)
min_bet = prod_config.get('min_bet_usd', 0.50)
max_bet = prod_config.get('max_bet_usd', 25)

# Price range check
if not (min_p <= mid <= max_p):
    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "end_datetime": END_DATETIME,
        "hours_left": round(hours_left, 2),
        "best_bid": best_bid,
        "best_ask": best_ask,
        "spread": round(spread, 4),
        "mid": round(mid, 4),
        "price_range_allowed": f"{min_p} - {max_p}",
        "result": "NO_TRADE",
        "reason": f"Mid price {mid:.3f} outside allowed range {min_p}-{max_p}",
        "action": "Skipped"
    }
    write_log(entry)
    print(json.dumps(entry))
    sys.exit(0)

# Spread config check
if spread > max_s:
    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "end_datetime": END_DATETIME,
        "hours_left": round(hours_left, 2),
        "best_bid": best_bid,
        "best_ask": best_ask,
        "spread": round(spread, 4),
        "mid": round(mid, 4),
        "max_spread_config": max_s,
        "result": "NO_TRADE",
        "reason": f"Spread {spread:.4f} > config max {max_s}",
        "action": "Skipped"
    }
    write_log(entry)
    print(json.dumps(entry))
    sys.exit(0)

# Get portfolio value
portfolio = mcporter('get_portfolio_value', include_breakdown=False)
total_balance = 0.0
if isinstance(portfolio, dict):
    import re
    raw = str(portfolio)
    for key in ('TOTAL PORTFOLIO VALUE', 'total_portfolio_value', 'total_value', 'Cash Balance (USDC)'):
        val = portfolio.get(key)
        if val is not None:
            try:
                total_balance = float(str(val).replace('$','').replace(',',''))
                break
            except: pass
    if total_balance == 0:
        matches = re.findall(r'\$(\d+\.?\d*)', raw)
        if matches:
            total_balance = max(float(m) for m in matches)

if total_balance < 1.0:
    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "end_datetime": END_DATETIME,
        "hours_left": round(hours_left, 2),
        "best_bid": best_bid,
        "best_ask": best_ask,
        "spread": round(spread, 4),
        "mid": round(mid, 4),
        "portfolio_value": total_balance,
        "portfolio_raw": str(portfolio),
        "result": "NO_TRADE",
        "reason": f"Portfolio balance ${total_balance:.2f} < $1.00 minimum",
        "action": "Skipped — tell Philipp to deposit more"
    }
    write_log(entry)
    print(json.dumps(entry))
    print(f"ALERT: Bankroll too low (${total_balance:.2f}) — deposit more to trade!")
    sys.exit(0)

bet_pct = bet_pct_small if total_balance < balance_threshold else bet_pct_normal
bet_size = round(min(max(total_balance * bet_pct, min_bet), max_bet), 2)

# Already traded this market?
try:
    with open(f'{TRADING_DIR}/journal.json') as f:
        prod_journal = json.load(f)
except:
    prod_journal = {'trades': []}

already = any(t['condition_id'] == CONDITION_ID for t in prod_journal.get('trades', []))
if already:
    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "result": "NO_TRADE",
        "reason": "Already traded this market",
        "action": "Skipped"
    }
    write_log(entry)
    print(json.dumps(entry))
    sys.exit(0)

# Place order
result = mcporter('create_limit_order',
    market_id=CONDITION_ID,
    side='BUY',
    price=round(best_ask, 2),
    size=bet_size
)

if result.get('success') or result.get('order_id'):
    trade = {
        'bot_id': 'prod',
        'timestamp': now.isoformat(),
        'question': QUESTION,
        'condition_id': CONDITION_ID,
        'price': best_ask,
        'spread_at_entry': round(spread, 4),
        'hours_before_close': round(hours_left, 2),
        'size_usd': bet_size,
        'shares': round(bet_size / best_ask, 2),
        'end_datetime': END_DATETIME,
        'order_id': result.get('order_id'),
        'status': 'open',
        'pnl': None
    }
    prod_journal.setdefault('trades', []).append(trade)
    with open(f'{TRADING_DIR}/journal.json', 'w') as f:
        json.dump(prod_journal, f, indent=2)

    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "end_datetime": END_DATETIME,
        "hours_left": round(hours_left, 2),
        "best_bid": best_bid,
        "best_ask": best_ask,
        "spread": round(spread, 4),
        "mid": round(mid, 4),
        "portfolio_value": total_balance,
        "bet_size_usd": bet_size,
        "shares": round(bet_size / best_ask, 2),
        "order_id": result.get('order_id'),
        "result": "TRADED",
        "reason": "All conditions met — order placed",
        "action": f"BUY {round(bet_size/best_ask,2)} shares @ {best_ask:.2f} = ${bet_size:.2f}"
    }
    write_log(entry)
    print(json.dumps(entry))
    print(f"TRADED: {QUESTION[:50]} @ {best_ask:.2f} ${bet_size:.2f} ({round(bet_size/best_ask,2)} shares)")
else:
    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "end_datetime": END_DATETIME,
        "hours_left": round(hours_left, 2),
        "best_bid": best_bid,
        "best_ask": best_ask,
        "spread": round(spread, 4),
        "mid": round(mid, 4),
        "portfolio_value": total_balance,
        "bet_size_usd": bet_size,
        "result": "ERROR",
        "reason": f"Order failed: {result}",
        "action": "Trade attempt failed"
    }
    write_log(entry)
    print(json.dumps(entry))
    print(f"ALERT: Order failed for {QUESTION[:50]} — {result}")

PYEOF
