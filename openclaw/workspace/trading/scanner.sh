#!/bin/bash
# Event Sniper - Smart Scanner
# Outputs JSON list of candidates for cron scheduling

WORKSPACE="/home/node/.openclaw/workspace"

python3 << PYEOF
import json, httpx, subprocess
from datetime import datetime, timezone, timedelta

WORKSPACE = "$WORKSPACE"

with open(f'{WORKSPACE}/trading/config.json') as f:
    config = json.load(f)

min_price = config['min_yes_price']
max_price = config['max_yes_price']
min_vol = 50000  # min 24h volume — real activity signal

now = datetime.now(timezone.utc)
cutoff = datetime.fromtimestamp(now.timestamp() + 7*86400, tz=timezone.utc)

BASE = "https://gamma-api.polymarket.com/markets"

candidates = []
with httpx.Client(timeout=15) as client:
    # Fetch top markets by 24h volume — these have real CLOB activity
    offset = 0
    while offset < 2000:
        r = client.get(f"{BASE}?active=true&closed=false&order=volume24hr&ascending=false&limit=200&offset={offset}")
        batch = r.json()
        if not batch:
            break
        for m in batch:
            vol = float(m.get('volume24hr') or 0)
            if vol < min_vol:
                break  # sorted descending, can stop early
            try:
                ed = datetime.fromisoformat(m['endDate'].replace('Z', '+00:00'))
            except:
                continue
            if ed < now or ed > cutoff:
                continue
            q = m.get('question', '')
            slug = m.get('slug', '')
            if 'Up or Down' in q or 'updown' in slug.lower():
                continue
            prices = m.get('outcomePrices', '[0,0]')
            if isinstance(prices, str):
                prices = json.loads(prices)
            try:
                yes = float(prices[0])
            except:
                continue
            if not (min_price <= yes <= max_price):
                continue
            token_ids = json.loads(m['clobTokenIds']) if isinstance(m.get('clobTokenIds'), str) else m.get('clobTokenIds', [])
            liq = float(m.get('liquidityClob') or m.get('liquidityNum') or m.get('liquidity') or 0)
            candidates.append({
                'question': q,
                'condition_id': m['conditionId'],
                'slug': slug,
                'yes_price': yes,
                'liquidity': liq,
                'end_date': m['endDate'][:10],
                'end_datetime': m['endDate'],
                'clob_token_ids': token_ids,
                'volume_24h': vol,
                'status': 'watching'
            })
        offset += 200

# ── Orderbook pre-filter ─────────────────────────────────────────────────────
# Check real orderbook for each candidate — drop markets with only placeholder orders
def mcporter(tool, **kwargs):
    args = ['mcporter', 'call', f'polymarket.{tool}']
    for k, v in kwargs.items():
        args.append(f'{k}={json.dumps(v) if isinstance(v,(dict,list)) else str(v)}')
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(r.stdout)
    except:
        return {'error': r.stdout.strip() + r.stderr.strip()}

MIN_REAL_BID = 0.05   # ignore bids below this (placeholders)
MAX_REAL_ASK = 0.95   # ignore asks above this (placeholders)
MAX_SPREAD   = 0.10   # max allowed spread on real orders
MIN_MID      = 0.15   # drop if market is already near-certain (YES < 15%)
MAX_MID      = 0.85   # drop if market is already near-certain (YES > 85%)

real_candidates = []
for c in candidates:
    yes_token = c['clob_token_ids'][0] if c['clob_token_ids'] else ''
    if not yes_token:
        print(f"SKIP (no token): {c['question'][:55]}")
        continue

    # Use AMM price (get_current_price) — more reliable than CLOB orderbook for sports markets
    price_data = mcporter('get_current_price', token_id=yes_token, side='BOTH')
    if 'error' in price_data:
        print(f"SKIP (price error): {c['question'][:55]}")
        continue

    bid = price_data.get('bid')
    ask = price_data.get('ask')
    if bid is None or ask is None:
        print(f"SKIP (no price): {c['question'][:55]}")
        continue

    bid = float(bid)
    ask = float(ask)
    # AMM can return bid > ask — normalize
    if bid > ask:
        bid, ask = ask, bid
    spread = ask - bid
    mid = (bid + ask) / 2

    if spread > MAX_SPREAD:
        print(f"SKIP (spread {spread:.2f}): {c['question'][:55]}")
        continue

    if not (MIN_MID <= mid <= MAX_MID):
        print(f"SKIP (mid {mid:.2f} out of range): {c['question'][:55]}")
        continue

    c['amm_bid'] = round(bid, 4)
    c['amm_ask'] = round(ask, 4)
    c['amm_spread'] = round(spread, 4)
    c['amm_mid'] = round(mid, 4)
    real_candidates.append(c)
    print(f"CANDIDATE: {c['question'][:55]} | mid={mid:.2f} spread={spread:.3f}")

candidates = real_candidates

# Save watchlist
watchlist = {'markets': candidates, 'last_scanned': now.isoformat()}
with open(f'{WORKSPACE}/trading/watchlist.json', 'w') as f:
    json.dump(watchlist, f, indent=2)

print(f"SCANNER_DONE:{len(candidates)}")

# Load swarm population to find max window
swarm_dir = f'{WORKSPACE}/swarm'
try:
    with open(f'{swarm_dir}/population.json') as f:
        pop = json.load(f)
except:
    try:
        with open(f'{swarm_dir}/genesis.json') as f:
            pop = json.load(f)
    except:
        pop = {'bots': []}

max_window = max([b.get('window_hours', 2) for b in pop.get('bots', [])] + [2])

for c in candidates:
    end_dt = datetime.fromisoformat(c['end_datetime'].replace('Z', '+00:00'))
    fire_at = end_dt - timedelta(hours=max_window)

    # Don't schedule if fire time is in the past or too soon
    if fire_at <= now + timedelta(minutes=5):
        fire_at = now + timedelta(minutes=2)

    fire_iso = fire_at.strftime('%Y-%m-%dT%H:%M:%SZ')
    yes_token = c['clob_token_ids'][0] if c['clob_token_ids'] else ''

    job = {
        "name": f"watch:{c['condition_id'][:20]}",
        "schedule": {"kind": "at", "at": fire_iso},
        "payload": {
            "kind": "agentTurn",
            "message": f"Run market watcher:\nbash /home/node/.openclaw/workspace/trading/market_watcher.sh '{c['condition_id']}' '{yes_token}' '{c['end_datetime']}' '{c['question'][:60].replace(chr(39), '')}'\n\nOnly notify Philipp on Telegram if a trade was EXECUTED or FINALLY REJECTED (no retry). Stay completely silent otherwise.",
            "timeoutSeconds": 120
        },
        "sessionTarget": "isolated",
        "delivery": {"mode": "none"}
    }

    # Write to cron queue for agent to pick up (openclaw CLI hangs without TTY)
    cron_queue_path = f"{WORKSPACE}/trading/cron_queue.json"
    try:
        with open(cron_queue_path) as f:
            queue = json.load(f)
    except:
        queue = []
    queue.append(job)
    with open(cron_queue_path, 'w') as f:
        json.dump(queue, f, indent=2)
    print(f"QUEUED [{fire_iso}]: {c['question'][:55]}")

PYEOF
