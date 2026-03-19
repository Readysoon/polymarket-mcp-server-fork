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

export MW_CONDITION_ID="$CONDITION_ID"
export MW_YES_TOKEN="$YES_TOKEN"
export MW_END_DATETIME="$END_DATETIME"
export MW_QUESTION="$QUESTION"
export MW_WORKSPACE="$WORKSPACE"
export MW_SWARM_DIR="$SWARM_DIR"
export MW_TRADING_DIR="$TRADING_DIR"

python3 << 'PYEOF'
import json, subprocess, sys, os
from datetime import datetime, timezone, timedelta

CONDITION_ID = os.environ['MW_CONDITION_ID']
YES_TOKEN = os.environ['MW_YES_TOKEN']
END_DATETIME = os.environ['MW_END_DATETIME']
QUESTION = os.environ['MW_QUESTION']
WORKSPACE = os.environ['MW_WORKSPACE']
SWARM_DIR = os.environ['MW_SWARM_DIR']
TRADING_DIR = os.environ['MW_TRADING_DIR']
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

# ── Check AMM price ──────────────────────────────────────────────────────────
price_data = mcporter('get_current_price', token_id=YES_TOKEN, side='BOTH')

if 'error' in price_data or price_data.get('bid') is None or price_data.get('ask') is None:
    error_detail = price_data.get('error', 'no price available')
    if hours_left > 1:
        fire_at = (now + timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
        job = {
            "name": f"watch:{CONDITION_ID[:16]}",
            "schedule": {"kind": "at", "at": fire_at},
            "payload": {
                "kind": "agentTurn",
                "message": f"Run market watcher for: {QUESTION[:60]}\n\nbash /home/node/.openclaw/workspace/trading/market_watcher.sh '{CONDITION_ID}' '{YES_TOKEN}' '{END_DATETIME}' '{QUESTION[:60]}'\n\nOnly notify Philipp on Telegram if a trade was EXECUTED or FINALLY REJECTED (no retry). Stay completely silent otherwise.",
                "timeoutSeconds": 120
            },
            "sessionTarget": "isolated",
            "delivery": {"mode": "none"}
        }
        cron_queue_path = f"{TRADING_DIR}/cron_queue.json"
        try:
            with open(cron_queue_path) as f:
                queue = json.load(f)
        except:
            queue = []
        queue.append(job)
        with open(cron_queue_path, 'w') as f:
            json.dump(queue, f, indent=2)
        entry = {
            "timestamp": now.isoformat(),
            "question": QUESTION,
            "condition_id": CONDITION_ID,
            "end_datetime": END_DATETIME,
            "hours_left": round(hours_left, 2),
            "result": "NOT_READY",
            "reason": f"No AMM price available: {error_detail}",
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
            "reason": f"No AMM price and <1h left: {error_detail}",
            "action": "Abandoned"
        }
    write_log(entry)
    print(json.dumps(entry))
    sys.exit(0)

best_bid = float(price_data['bid'])
best_ask = float(price_data['ask'])
# AMM can return bid > ask — normalize
if best_bid > best_ask:
    best_bid, best_ask = best_ask, best_bid
spread = best_ask - best_bid
mid = (best_bid + best_ask) / 2

MAX_SPREAD = 0.10  # AMM spreads are naturally wider than CLOB
if spread > MAX_SPREAD:
    if hours_left > 0.5:
        retry_mins = 15
        fire_at = (now + timedelta(minutes=retry_mins)).strftime('%Y-%m-%dT%H:%M:%SZ')
        job = {
            "name": f"watch:{CONDITION_ID[:16]}",
            "schedule": {"kind": "at", "at": fire_at},
            "payload": {
                "kind": "agentTurn",
                "message": f"Run market watcher for: {QUESTION[:60]}\n\nbash /home/node/.openclaw/workspace/trading/market_watcher.sh '{CONDITION_ID}' '{YES_TOKEN}' '{END_DATETIME}' '{QUESTION[:60]}'\n\nOnly notify Philipp on Telegram if a trade was EXECUTED or FINALLY REJECTED (no retry). Stay completely silent otherwise.",
                "timeoutSeconds": 120
            },
            "sessionTarget": "isolated",
            "delivery": {"mode": "none"}
        }
        cron_queue_path = f"{TRADING_DIR}/cron_queue.json"
        try:
            with open(cron_queue_path) as f:
                queue = json.load(f)
        except:
            queue = []
        queue.append(job)
        with open(cron_queue_path, 'w') as f:
            json.dump(queue, f, indent=2)
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
max_s = prod_config.get('max_spread', 0.10)  # AMM: wider spread acceptable
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

# Auto-redeem any winning positions before checking balance
try:
    import httpx as _httpx
    from eth_account import Account as _Account
    from web3 import Web3 as _Web3

    _PRIVATE_KEY = os.environ.get('POLYGON_PRIVATE_KEY', '')
    _ADDRESS = os.environ.get('POLYGON_ADDRESS', '')
    _USDC = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
    _CTF  = "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045"
    _RPC  = "https://polygon-bor-rpc.publicnode.com"
    _CTF_ABI = [{"name":"redeemPositions","type":"function","inputs":[
        {"name":"collateralToken","type":"address"},
        {"name":"parentCollectionId","type":"bytes32"},
        {"name":"conditionId","type":"bytes32"},
        {"name":"indexSets","type":"uint256[]"}
    ],"outputs":[]}]

    _r = _httpx.get(f"https://data-api.polymarket.com/positions?user={_ADDRESS}&sizeThreshold=0.01", timeout=15)
    _positions = _r.json() if _r.status_code == 200 else []
    _redeemable = [p for p in _positions if p.get('redeemable')]

    if _redeemable and _PRIVATE_KEY:
        _w3 = _Web3(_Web3.HTTPProvider(_RPC))
        _ctf = _w3.eth.contract(address=_w3.to_checksum_address(_CTF), abi=_CTF_ABI)
        _acct = _Account.from_key(_PRIVATE_KEY)
        _redeemed_value = 0.0
        for _p in _redeemable:
            try:
                _index_set = 1 << _p.get('outcomeIndex', 0)
                _tx = _ctf.functions.redeemPositions(
                    _w3.to_checksum_address(_USDC),
                    b'\x00' * 32,
                    bytes.fromhex(_p['conditionId'][2:]),
                    [_index_set]
                ).build_transaction({
                    'from': _acct.address,
                    'nonce': _w3.eth.get_transaction_count(_acct.address),
                    'gas': 200000,
                    'gasPrice': _w3.eth.gas_price,
                    'chainId': 137
                })
                _signed = _acct.sign_transaction(_tx)
                _w3.eth.send_raw_transaction(_signed.raw_transaction)
                _redeemed_value += float(_p.get('currentValue', 0))
                print(f"REDEEMED: {_p.get('title','?')[:40]} ${_p.get('currentValue',0):.2f}")
            except Exception as _e:
                print(f"REDEEM_ERROR: {_e}")
        if _redeemed_value > 0:
            import time as _time
            _time.sleep(8)  # wait for tx to settle
except Exception as _redeem_err:
    print(f"REDEEM_ATTEMPT_ERROR: {_redeem_err}")

# Skip balance check — Polymarket's new system doesn't expose balance via API
# The trade will fail naturally if there are insufficient funds
# Use config min_bet as proxy for "do we have enough"
total_balance = 999.0  # Assume funded; real check happens at order placement
print("Balance check bypassed — relying on Polymarket order validation")



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
        "result": "NO_TRADE",
        "reason": f"Portfolio balance ${total_balance:.2f} < $1.00 minimum — no redeemable positions",
        "action": "Skipped — deposit more USDC"
    }
    write_log(entry)
    print(json.dumps(entry))
    print(f"ALERT: Bankroll too low (${total_balance:.2f}) — deposit more to trade!")
    sys.exit(0)

# Bet sizing: use min_bet as default since we can't read Polymarket balance via API
# TODO: update when Polymarket exposes balance API
bet_size = min_bet
print(f"Bet size: ${bet_size:.2f} (fixed min_bet — balance API unavailable)")

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

# Place order via AMM (market order — executes at current AMM price)
result = mcporter('create_market_order',
    market_id=CONDITION_ID,
    side='BUY',
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
