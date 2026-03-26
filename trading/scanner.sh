#!/bin/bash
# scanner.sh — scan Polymarket for tradeable candidates and queue watcher jobs

WORKSPACE="/home/node/.openclaw/workspace"

python3 << PYEOF
import json, httpx, subprocess
from datetime import datetime, timezone, timedelta

WORKSPACE = "$WORKSPACE"
TRADING_DIR = f"{WORKSPACE}/trading"

with open(f'{TRADING_DIR}/config.json') as f:
    config = json.load(f)

min_price = config['min_yes_price']
max_price = config['max_yes_price']
MIN_VOL   = 50000  # min 24h volume — real activity signal

now    = datetime.now(timezone.utc)
cutoff = datetime.fromtimestamp(now.timestamp() + 28 * 3600, tz=timezone.utc)

BASE = "https://gamma-api.polymarket.com/markets"


# ── Fetch candidates from Polymarket ─────────────────────────────────────────

candidates = []
with httpx.Client(timeout=15) as client:
    offset = 0
    while offset < 500:
        r = client.get(
            f"{BASE}?active=true&closed=false&order=volume24hr&ascending=false&limit=200&offset={offset}"
        )
        batch = r.json()
        if not batch:
            break
        for m in batch:
            vol = float(m.get('volume24hr') or 0)
            if vol < MIN_VOL:
                break  # sorted descending — stop early

            try:
                ed = datetime.fromisoformat(m['endDate'].replace('Z', '+00:00'))
            except:
                continue
            if ed < now or ed > cutoff:
                continue

            q    = m.get('question', '')
            slug = m.get('slug', '')

            # Skip up/down and social-media markets
            if 'Up or Down' in q or 'updown' in slug.lower():
                continue
            if any(x in q.lower() for x in ['tweet', 'post ', 'elon musk', 'twitter', 'x.com']):
                continue

            # Skip neg-risk markets (can't redeem programmatically)
            if m.get('negRisk', False):
                continue

            # Skip markets already open in journal
            cid = m.get('conditionId', m.get('condition_id', ''))
            try:
                with open(f'{TRADING_DIR}/journal.json') as jf:
                    journal = json.load(jf)
                if any(t.get('condition_id') == cid and t.get('status') == 'open'
                       for t in journal.get('trades', [])):
                    continue
            except:
                pass

            prices = m.get('outcomePrices', '[0,0]')
            if isinstance(prices, str):
                prices = json.loads(prices)
            try:
                yes = float(prices[0])
            except:
                continue

            if yes < min_price:        # too speculative
                continue
            if yes > 0.90:             # near-certain, always skip
                continue
            # Between max_price (0.75) and 0.90: pass through, Runner EV-check decides

            token_ids = (json.loads(m['clobTokenIds'])
                         if isinstance(m.get('clobTokenIds'), str)
                         else m.get('clobTokenIds', []))
            liq = float(m.get('liquidityClob') or m.get('liquidityNum') or m.get('liquidity') or 0)

            candidates.append({
                'question': q,
                'condition_id': cid,
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


# ── Orderbook pre-filter (AMM price check) ───────────────────────────────────

def mcporter(tool, **kwargs):
    args = ['mcporter', 'call', f'polymarket.{tool}']
    for k, v in kwargs.items():
        args.append(f'{k}={json.dumps(v) if isinstance(v, (dict, list)) else str(v)}')
    r = subprocess.run(args, capture_output=True, text=True, timeout=10)
    try:
        return json.loads(r.stdout)
    except:
        return {'error': r.stdout.strip() + r.stderr.strip()}

MAX_SPREAD = 0.10
MIN_MID    = 0.15
MAX_MID    = 0.90

real_candidates = []
for c in candidates[:30]:  # max 30 for orderbook check
    yes_token = c['clob_token_ids'][0] if c['clob_token_ids'] else ''
    if not yes_token:
        print(f"SKIP (no token): {c['question'][:55]}")
        continue

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
    if bid > ask:
        bid, ask = ask, bid
    spread = ask - bid
    mid    = (bid + ask) / 2

    if spread > MAX_SPREAD:
        print(f"SKIP (spread {spread:.2f}): {c['question'][:55]}")
        continue
    if not (MIN_MID <= mid <= MAX_MID):
        print(f"SKIP (mid {mid:.2f} out of range): {c['question'][:55]}")
        continue

    c['amm_bid']    = round(bid, 4)
    c['amm_ask']    = round(ask, 4)
    c['amm_spread'] = round(spread, 4)
    c['amm_mid']    = round(mid, 4)
    real_candidates.append(c)
    print(f"CANDIDATE: {c['question'][:55]} | mid={mid:.2f} spread={spread:.3f}")

candidates = real_candidates


# ── Save watchlist ────────────────────────────────────────────────────────────

with open(f'{TRADING_DIR}/watchlist.json', 'w') as f:
    json.dump({'markets': candidates, 'last_scanned': now.isoformat()}, f, indent=2)

print(f"SCANNER_DONE:{len(candidates)}")


# ── Queue watcher jobs ────────────────────────────────────────────────────────

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
    end_dt  = datetime.fromisoformat(c['end_datetime'].replace('Z', '+00:00'))
    fire_at = end_dt - timedelta(hours=max_window)
    if fire_at <= now + timedelta(minutes=5):
        fire_at = now + timedelta(minutes=2)
    fire_iso = fire_at.strftime('%Y-%m-%dT%H:%M:%SZ')

    yes_token     = c['clob_token_ids'][0] if c['clob_token_ids'] else ''
    cond          = c['condition_id']
    cond20        = cond[:20]
    end_dt_str    = c['end_datetime']
    amm_mid       = c.get('amm_mid', c.get('yes_price', '?'))
    outcome_check = (datetime.fromisoformat(end_dt_str.replace('Z', '+00:00')) + timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ')

    # Pre-strip apostrophes to avoid shell quoting issues in f-string
    q_80 = c['question'][:80].replace("'", "")
    q_60 = c['question'][:60].replace("'", "")
    q_50 = c['question'][:50].replace("'", "")

    # Read research for this candidate if available
    research_entry = {}
    try:
        with open(f'{TRADING_DIR}/research.json') as rf:
            research_entry = json.load(rf).get(cond, {})
    except:
        pass

    allocated_usd    = research_entry.get('allocated_usd', 3.0)
    confidence       = research_entry.get('confidence_pct', 0)
    sources_summary  = research_entry.get('sources_summary', 'No research available')
    red_flags        = research_entry.get('red_flags', 'unknown')

    job = {
        "name": f"watch:{cond20}",
        "schedule": {"kind": "at", "at": fire_iso},
        "payload": {
            "kind": "agentTurn",
            "message": f"""Du bist ein Watcher-Agent. Der Scanner hat bereits Research für diesen Markt durchgeführt.

MARKT: {q_80}
CONDITION_ID: {cond}
YES_TOKEN: {yes_token}
MARKTSCHLUSS: {end_dt_str}
AKTUELLER_POLYMARKET_PREIS: {amm_mid}
RESEARCH_SUMMARY: {sources_summary}
CONFIDENCE: {confidence}%
ALLOKIERTES_BUDGET: ${allocated_usd:.2f}
RED_FLAGS: {red_flags}

DEINE AUFGABE:

1. Prüfe den AKTUELLEN Marktpreis:
   mcporter call polymarket.get_current_price token_id={yes_token} side=BOTH
   Verwende den mid-Preis (bid+ask)/2

2. EV-CHECK — Lohnt sich der Trade noch?
   Regel: confidence_pct/100 muss >= aktueller_preis + 0.08
   Beispiel: 72% Confidence @ 0.62¢ → 0.72 >= 0.62 + 0.08 = 0.70 ✅ TRADE
   Beispiel: 72% Confidence @ 0.68¢ → 0.72 >= 0.68 + 0.08 = 0.76 ❌ SKIP
   
   Falls confidence/100 < aktueller_preis + 0.08 → SKIP (Kurs zu hoch für die Confidence)

3. Falls Markt fast geschlossen (< 30 Min) → SKIP

4. Entscheide wie viel du einsetzt:
   - Max: ${allocated_usd:.2f} (vom Scanner allokiert)
   - Min: $2.50
   - Bei gutem EV (confidence/100 - preis > 0.15) → volles Budget
   - Bei knappem EV (confidence/100 - preis = 0.08-0.15) → halbes Budget

4. NUR WENN TRADE:
   bash /home/node/.openclaw/workspace/trading/market_watcher.sh '{cond}' '{yes_token}' '{end_dt_str}' '{q_60}'

5. Falls Trade platziert — Outcome-Checker registrieren:
   - name: outcome:{cond20}
   - schedule: at {outcome_check}
   - sessionTarget: isolated, timeoutSeconds: 120
   - delivery: announce to 866661912 telegram
   - message: Prüfe Ergebnis für {q_50} (condition_id: {cond}, yes_token: {yes_token}). Run redeem.sh. REDEEMED > 0 → WON, journal+log updaten, Philipp benachrichtigen. REDEEM_ZERO → retry in 2h. LOST → journal+log updaten, Philipp benachrichtigen.

6. Trade-Nachricht an Philipp:
   ✅ TRADED: {q_50} | ${allocated_usd:.2f} @ [preis]¢
   📅 Next bet: [nächster Watcher aus Cron-Liste] @ [HH:MM Innsbruck]

7. Bei SKIP → keine Nachricht an Philipp.
8. Bei technischem Fehler → debuggen, fixen, git push, Philipp benachrichtigen.""",
            "timeoutSeconds": 300
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
    print(f"QUEUED [{fire_iso}]: {c['question'][:55]}")

PYEOF
