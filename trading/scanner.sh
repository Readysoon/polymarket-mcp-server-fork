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
            # Skip social media / tweet count markets
            if any(x in q.lower() for x in ['tweet', 'post ', 'elon musk', 'twitter', 'x.com']):
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

    # Pre-compute values that would require backslashes inside f-string expressions (not allowed in Python < 3.12)
    q_80   = c['question'][:80].replace("'", "")
    q_60   = c['question'][:60].replace("'", "")
    q_50   = c['question'][:50].replace("'", "")
    cond   = c['condition_id']
    cond20 = c['condition_id'][:20]
    end_dt_str = c['end_datetime']
    amm_mid = c.get('amm_mid', c.get('yes_price', '?'))
    outcome_check_iso = (datetime.fromisoformat(end_dt_str.replace('Z', '+00:00')) + timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ')

    job = {
        "name": f"watch:{cond20}",
        "schedule": {"kind": "at", "at": fire_iso},
        "payload": {
            "kind": "agentTurn",
            "message": f"""Du bist ein Trading-Research-Agent. Führe folgende Schritte aus:

MARKT: {q_80}
CONDITION_ID: {cond}
POLYMARKET PREIS: {amm_mid}
MARKTSCHLUSS: {end_dt_str}

SCHRITT 1 — WEB RESEARCH mit web_fetch:
Erkenne den Markttyp und fetch die passenden Quellen:
- NCAA/NBA Basketball → web_fetch('https://www.covers.com/picks/ncaab') oder web_fetch('https://www.covers.com/picks/nba')
- NHL → web_fetch('https://www.covers.com/picks/nhl')
- Fußball → web_fetch('https://www.bbc.com/sport/football') oder web_fetch('https://www.soccerway.com')
- Esports (CS, LoL) → web_fetch('https://www.hltv.org/matches') oder web_fetch('https://liquipedia.net/counterstrike/Main_Page')
- Crypto → web_fetch('https://coinmarketcap.com/currencies/bitcoin/')

Fetch 1-2 relevante Seiten. Suche nach Expert-Picks, Verletzungen, Form für diesen Markt.

SCHRITT 2 — CONFIDENCE SCORE (0-100%):
Basierend auf dem was du gefunden hast:
- Klarer Expert-Pick für eine Seite + keine Red Flags → 70-85%
- Teilweise Hinweise, unsicher → 50-65%
- Keine Daten / widersprüchlich → unter 50%
Red Flags: Verletzung Stammkraft, Rotation, sehr ausgeglichenes Duell

SCHRITT 3 — ENTSCHEIDUNG:
- confidence >= 65% UND kein Red Flag → TRADE
- confidence < 65% ODER Red Flag → SKIP

SCHRITT 4 — Research in research.json speichern:
Schreibe mit python3 in /home/node/.openclaw/workspace/trading/research.json:
{{"{cond}": {{"question": "{q_60}", "confidence_pct": X, "sources_summary": "...", "red_flags": "...", "decision": "TRADE/SKIP", "researched_at": "<ISO>"}}}}

SCHRITT 5 — NUR WENN TRADE:
bash /home/node/.openclaw/workspace/trading/market_watcher.sh '{cond}' '{yes_token}' '{end_dt_str}' '{q_60}'

Nur Philipp benachrichtigen wenn TRADED oder technischer Fehler. Kein NO_TRADE Nachricht.

Falls Trade platziert: Cron-Tool nutzen um Outcome-Checker zu registrieren:
- name: outcome:{cond20}
- schedule: at {outcome_check_iso}
- sessionTarget: isolated, timeoutSeconds: 120, delivery: announce to 866661912 telegram
- message: Prüfe Ergebnis für {q_50}. Run redeem.sh. WON → journal+log updaten, Philipp benachrichtigen. REDEEM_ZERO → retry in 2h. LOST → journal+log updaten, Philipp benachrichtigen.

Nächste Wette aus Cron-Liste holen und in Trade-Nachricht einbauen: 📅 Next bet: [Markt] @ [HH:MM Innsbruck]

Bei technischem Fehler: debuggen, fixen, git push, Philipp benachrichtigen.""",

Only notify Philipp on Telegram if a trade was placed (TRADED) or a technical error occurred. Do NOT notify for NO_TRADE.

If a trade WAS placed:
1. Use the cron tool to register an outcome-checker job:
- name: outcome:{cond20}
- schedule: at {outcome_check_iso}
- sessionTarget: isolated
- timeoutSeconds: 120
- delivery: announce to Philipp 866661912 on telegram
- message: Check outcome for market: {q_60} (condition_id: {cond}, yes_token: {yes_token}, end: {end_dt_str})

IMPORTANT: Markets take 2-4h to resolve after end time.
1. Run bash /home/node/.openclaw/workspace/trading/redeem.sh and capture output
2. Check result:
   - REDEEMED with amount > 0 -> WON
   - REDEEM_ZERO -> not resolved yet, schedule retry in 2h silently (no notification)
   - SKIP value $0 -> LOST
3. Update /home/node/.openclaw/workspace/trading/journal.json:
   Find the entry with condition_id={cond} and update ALL of these fields:
   - status: "won" or "lost"
   - outcome: "won" or "lost"
   - pnl: redeem_amount - size_usd (positive if won, negative if lost)
   - pnl_pct: (pnl / size_usd) * 100
   - redeem_amount: actual USDC received (0 if lost)
   - resolved_at: current ISO timestamp
4. Also append to /home/node/.openclaw/workspace/trading/log.json:
   {{
     "timestamp": "<now>",
     "question": "{q_50}",
     "condition_id": "{cond}",
     "result": "WON" or "LOST",
     "size_usd": <original bet>,
     "redeem_amount": <usdc received>,
     "pnl": <redeem - bet>,
     "pnl_pct": <pnl %>",
     "confidence_pct": <from journal entry>,
     "research_summary": <from journal entry>,
     "action": "Outcome recorded"
   }}
5. Notify Philipp: WON ✅ or LOST ❌ -- {q_50} | Bet: $X.XX | Return: $X.XX | P&L: +/-$X.XX (+/-X%) | Portfolio: $XX.XX

2. Also check the cron job list using the cron tool (action=list) and find the NEXT upcoming watcher job after this one. Include it in the trade notification to Philipp:

✅ TRADED: [market] [side] [shares] @ [price]¢ = $[total]
📅 Next bet: [next market name] @ [HH:MM Innsbruck time]

On technical error: debug, fix, git push, notify Philipp.""",
            "timeoutSeconds": 300
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
