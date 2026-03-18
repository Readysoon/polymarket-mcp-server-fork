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
min_liq = config['min_liquidity_usd']

now = datetime.now(timezone.utc)
cutoff = datetime.fromtimestamp(now.timestamp() + 7*86400, tz=timezone.utc)

BASE = "https://gamma-api.polymarket.com/markets"
PARAMS = "active=true&closed=false&order=endDate&ascending=true"

# Binary search for start offset
lo, hi = 0, 30000
start_offset = 0
with httpx.Client(timeout=15) as client:
    while lo <= hi:
        mid = (lo + hi) // 2
        r = client.get(f"{BASE}?{PARAMS}&limit=1&offset={mid}")
        data = r.json()
        if not data:
            hi = mid - 1
            continue
        try:
            ed = datetime.fromisoformat(data[0]['endDate'].replace('Z', '+00:00'))
            if ed < now:
                lo = mid + 1
            else:
                start_offset = mid
                hi = mid - 1
        except:
            hi = mid - 1

    candidates = []
    offset = max(0, start_offset - 20)
    while offset < start_offset + 5000:
        r = client.get(f"{BASE}?{PARAMS}&limit=200&offset={offset}")
        batch = r.json()
        if not batch:
            break
        done = False
        for m in batch:
            try:
                ed = datetime.fromisoformat(m['endDate'].replace('Z', '+00:00'))
            except:
                continue
            if ed > cutoff:
                done = True
                break
            if ed < now:
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
            liq = float(m.get('liquidityClob') or m.get('liquidityNum') or m.get('liquidity') or 0)
            if liq < min_liq:
                continue
            token_ids = json.loads(m['clobTokenIds']) if isinstance(m.get('clobTokenIds'), str) else m.get('clobTokenIds', [])
            candidates.append({
                'question': q,
                'condition_id': m['conditionId'],
                'slug': slug,
                'yes_price': yes,
                'liquidity': liq,
                'end_date': m['endDate'][:10],
                'end_datetime': m['endDate'],
                'clob_token_ids': token_ids,
                'volume_24h': m.get('volume24hr', 0),
                'status': 'watching'
            })
        offset += 200
        if done:
            break

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
            "message": f"Run market watcher:\nbash /home/node/.openclaw/workspace/trading/market_watcher.sh '{c['condition_id']}' '{yes_token}' '{c['end_datetime']}' '{c['question'][:60].replace(chr(39), '')}'\n\nIf output contains TRADED: -> notify Philipp on Telegram with what was bet\nIf output contains ALERT: -> notify Philipp on Telegram\nEverything else -> stay silent.",
            "timeoutSeconds": 120
        },
        "sessionTarget": "isolated",
        "delivery": {"mode": "announce"}
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
