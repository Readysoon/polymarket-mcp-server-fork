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
min_vol = 100000  # min 24h volume — real activity signal

now = datetime.now(timezone.utc)
cutoff = datetime.fromtimestamp(now.timestamp() + 28*3600, tz=timezone.utc)

BASE = "https://gamma-api.polymarket.com/markets"

candidates = []
with httpx.Client(timeout=15) as client:
    # Fetch top markets by 24h volume — these have real CLOB activity
    offset = 0
    while offset < 500:
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
            if yes < 0.50 or yes > 0.80:  # hard filter: no underdogs, no near-certain
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
    r = subprocess.run(args, capture_output=True, text=True, timeout=10)
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
candidates = candidates[:30]  # max 30 for orderbook check
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

max_window = max([b.get('window_hours', 4) for b in pop.get('bots', [])] + [4])

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
            "message": f"""BEFORE running the market watcher script, research the following:

MARKET: {c['question'][:80].replace(chr(39), '')}

STEP 1 — RESEARCH using web_search on these specific sources:

Search 1: site:forebet.com "{c['question'][:50].replace(chr(39), '')}"
→ Get mathematical win probability and prediction

Search 2: "{c['question'][:50].replace(chr(39), '')} prediction site:sofascore.com OR site:flashscore.com"
→ Get ratings, form, H2H

Search 3: "{c['question'][:50].replace(chr(39), '')} prediction site:reddit.com"
→ Get community sentiment (r/soccer, r/nba, r/sportsbook etc.)

Search 4: "{c['question'][:50].replace(chr(39), '')} preview espn OR sportsline OR covers.com"
→ Get expert picks and reasoning

Search 5: "{c['question'][:50].replace(chr(39), '')} lineup injury news today"
→ Last-minute team news, missing players

Collect from all searches:
- Predicted winner and confidence %
- Key reasons (form, injuries, home advantage)
- Any red flags (star player missing, bad form, nothing to play for)

STEP 2 — CONFIDENCE SCORE:
Based on all research, calculate a confidence score (0-100%):
- 80-100%: Strong consensus across sources, clear favorite, no red flags
- 60-79%: Most sources agree, minor concerns
- 40-59%: Mixed signals, split opinions
- 0-39%: Unclear, major red flags, skip

STEP 3 — DECISION:
- confidence >= 65% AND Polymarket price ({c.get('amm_mid', c.get('yes_price', '?'))}) on winning side → TRADE
- confidence < 65% → SKIP
- Any red flag (key injury, rotation, derby) → SKIP regardless of confidence
- When in doubt → SKIP

STEP 4 — LOG THE RESEARCH:
Before running the script, append a research entry to /home/node/.openclaw/workspace/trading/log.json:
{{
  "timestamp": "<now ISO>",
  "question": "{c['question'][:60].replace(chr(39), '')}",
  "condition_id": "{c['condition_id']}",
  "result": "RESEARCH",
  "confidence_pct": <0-100>,
  "sources_summary": "<1-2 sentence summary of what sources say>",
  "red_flags": "<any concerns or 'none'>",
  "decision": "TRADE" or "SKIP",
  "reason": "<why>"
}}

STEP 3 — IF TRADING:
Run: bash /home/node/.openclaw/workspace/trading/market_watcher.sh '{c['condition_id']}' '{yes_token}' '{c['end_datetime']}' '{c['question'][:60].replace(chr(39), '')}'

Only notify Philipp on Telegram if a trade was placed (TRADED) or a technical error occurred. Do NOT notify for NO_TRADE.\n\nIf a trade WAS placed: use the cron tool to register an outcome-checker job with these parameters:\n- name: 'outcome:{c['condition_id'][:20]}'\n- schedule: at '{(datetime.fromisoformat(c[\"end_datetime\"].replace(\"Z\",\"+00:00\")) + timedelta(hours=3)).strftime(\"%Y-%m-%dT%H:%M:%SZ\")}'\n- sessionTarget: isolated\n- timeoutSeconds: 120\n- delivery: announce to Philipp 866661912 on telegram\n- message: 'Check outcome for market: {c['question'][:60].replace(chr(39), '')} (condition_id: {c['condition_id']}, yes_token: {yes_token}, end: {c['end_datetime']})\\n\\nIMPORTANT: Markets take 2-4h to resolve after end time.\\n1. Run bash /home/node/.openclaw/workspace/trading/redeem.sh\\n2. If REDEEMED with amount > 0 → WON, notify Philipp\\n3. If REDEEM_ZERO → not resolved yet, schedule retry in 2h silently\\n4. If SKIP value $0 → LOST, notify Philipp\\n5. Notification: WON or LOST — {c['question'][:50].replace(chr(39), '')} | P&L: +/- $X.XX | Portfolio: $XX.XX'\n\nOn technical error: debug, fix, git push, notify Philipp.",
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
