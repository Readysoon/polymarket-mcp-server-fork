#!/bin/bash
# live_monitor.sh — ESPN live monitor: stop-loss + live opportunity buying
# Runs every 5 min during live games

WORKSPACE="/home/node/.openclaw/workspace"
TRADING_DIR="$WORKSPACE/trading"

python3 << 'PYEOF'
import json, os, httpx, asyncio, sys, re
from datetime import datetime, timezone

WORKSPACE = os.environ.get('MW_WORKSPACE', '/home/node/.openclaw/workspace')
TRADING_DIR = f'{WORKSPACE}/trading'
STOP_LOSS_THRESHOLD = 0.22   # sell if our ESPN win prob drops below 22%
BUY_MAX_PRICE       = 0.80   # only buy if Polymarket price < 80¢ (min 10% edge)
BUY_MIN_BET         = 2.50
BUY_MAX_BET         = 25.00

# 3 buy tiers per game — buy once per tier
BUY_TIERS = [0.90, 0.95, 0.98]  # ESPN thresholds

TELEGRAM_BOT = 'https://api.telegram.org/bot8599638540:AAFVTzaLBWQmStBfdd3xSlPEJJQuMH4cEBI/sendMessage'
CHAT_ID = '866661912'
ADDR = os.environ.get('POLYGON_ADDRESS', '').lower()

def send_telegram(msg):
    try:
        import subprocess
        subprocess.run(['curl', '-s', '-X', 'POST', TELEGRAM_BOT,
            '-d', f'chat_id={CHAT_ID}&text={msg[:1000]}'], capture_output=True, timeout=10)
    except: pass

def word_match(team_name, text):
    return bool(re.search(r'\b' + re.escape(team_name) + r'\b', text, re.IGNORECASE))

# ── Load journal ──────────────────────────────────────────────────────────────
try:
    journal = json.load(open(f'{TRADING_DIR}/journal.json'))
    now = datetime.now(timezone.utc)
    open_trades = [t for t in journal.get('trades', [])
                   if t.get('status') in ('open', 'OPEN')
                   and t.get('end_datetime')
                   and datetime.fromisoformat(t['end_datetime'].replace('Z','+00:00')) > now]
except Exception as e:
    print(f'Journal error: {e}')
    sys.exit(0)

# ── Fetch ESPN live win probabilities ─────────────────────────────────────────
def get_espn_winprob():
    results = {}      # team_lower → win_pct
    game_teams = {}   # team_lower → (condition_or_title, other_team, end_dt)
    events_raw = []

    sports = [
        ('nba',   'basketball'),
        ('nhl',   'hockey'),
        ('ncaab', 'basketball/college-basketball'),
    ]
    for league, sport in sports:
        try:
            r = httpx.get(
                f'https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/scoreboard',
                timeout=8
            )
            for event in r.json().get('events', []):
                comp  = event.get('competitions', [{}])[0]
                desc  = event.get('status', {}).get('type', {}).get('description', '')
                if desc not in ('In Progress', 'Halftime'):
                    continue
                prob = comp.get('situation', {}).get('lastPlay', {}).get('probability', {})
                if not prob:
                    continue
                competitors = comp.get('competitors', [])
                teams = []
                for c in competitors:
                    name = c['team']['shortDisplayName']
                    home = c.get('homeAway', '') == 'home'
                    wp   = prob.get('homeWinPercentage' if home else 'awayWinPercentage', None)
                    if wp is not None:
                        results[name.lower()] = round(wp, 4)
                        teams.append(name.lower())
                events_raw.append({
                    'teams': teams,
                    'league': league,
                })
        except Exception as e:
            print(f'ESPN {league} error: {e}')
    return results, events_raw

espn_data, espn_events = get_espn_winprob()
if not espn_data:
    print('No ESPN live games')
    sys.exit(0)

print(f'ESPN live: {list(espn_data.keys())}')

# ── Load watchlist for live buy opportunities ─────────────────────────────────
try:
    watchlist = json.load(open(f'{TRADING_DIR}/watchlist.json')).get('markets', [])
except:
    watchlist = []

# Track which condition_ids + tiers have already been bought
# Key: (condition_id, tier_index) → True
bought_tiers = set()
for t in journal.get('trades', []):
    cid = t.get('condition_id', '')
    tier = t.get('live_buy_tier')
    if cid and tier is not None:
        bought_tiers.add((cid, tier))

# ── Get wallet balance ────────────────────────────────────────────────────────
def get_balance():
    try:
        bh = json.load(open(f'{TRADING_DIR}/balance_history.json'))
        entries = bh if isinstance(bh, list) else bh.get('history', [])
        return float(entries[-1].get('usdce', 0)) if entries else 0.0
    except:
        return 0.0

bankroll = get_balance()
print(f'Bankroll: ${bankroll:.2f}')

# ── Helper: sell position ─────────────────────────────────────────────────────
async def sell_position(token, shares, sell_price):
    sys.path.insert(0, f'{WORKSPACE}/src')
    from polymarket_mcp.auth.client import PolymarketClient
    client = PolymarketClient(
        private_key=os.environ['POLYGON_PRIVATE_KEY'],
        address=os.environ['POLYGON_ADDRESS'],
        api_key=os.environ['POLYMARKET_API_KEY'],
        api_secret=os.environ['POLYMARKET_API_SECRET'],
        passphrase=os.environ['POLYMARKET_PASSPHRASE'],
        chain_id=137
    )
    client._initialize_client()
    raw = shares
    best = None
    for q in range(max(1, int(raw * 4) - 8), int(raw * 4) + 9):
        ts = round(q / 4, 2)
        tc = ts * sell_price
        if abs(tc - round(tc, 2)) < 1e-9:
            if best is None or abs(ts - raw) < abs(best - raw):
                best = ts
    if best is None:
        best = round(raw / 0.25) * 0.25
    return await client.post_order(token_id=token, price=sell_price,
                                   size=round(best, 2), side='SELL', order_type='FOK')

# ── Helper: buy position ──────────────────────────────────────────────────────
async def buy_position(token_id, price, size_usd):
    sys.path.insert(0, f'{WORKSPACE}/src')
    from polymarket_mcp.auth.client import PolymarketClient
    client = PolymarketClient(
        private_key=os.environ['POLYGON_PRIVATE_KEY'],
        address=os.environ['POLYGON_ADDRESS'],
        api_key=os.environ['POLYMARKET_API_KEY'],
        api_secret=os.environ['POLYMARKET_API_SECRET'],
        passphrase=os.environ['POLYMARKET_PASSPHRASE'],
        chain_id=137
    )
    client._initialize_client()
    shares = round(size_usd / price, 2)
    return await client.post_order(token_id=token_id, price=round(price + 0.01, 3),
                                   size=shares, side='BUY', order_type='GTC')

# ── 1. STOP-LOSS: check existing open trades ──────────────────────────────────
for trade in open_trades:
    question     = trade.get('question', '')
    side         = trade.get('trade_side', 'YES')
    condition_id = trade.get('condition_id', '')
    outcome_team = trade.get('outcome', None)

    matched_team = matched_wp = our_wp = None

    if outcome_team:
        for team, wp in espn_data.items():
            if word_match(team, outcome_team) or word_match(outcome_team, team):
                matched_team, matched_wp, our_wp = team, wp, wp
                break

    if matched_wp is None:
        all_matches = [(t, w) for t, w in espn_data.items() if word_match(t, question)]
        if not all_matches:
            continue
        matched_team, matched_wp = all_matches[0]
        our_wp = matched_wp if side == 'YES' else 1 - matched_wp

    print(f'[STOPLOSS] {question[:40]} | side={side} | ESPN {matched_team}={matched_wp:.1%} | our={our_wp:.1%}')

    if our_wp < STOP_LOSS_THRESHOLD:
        print(f'STOP-LOSS TRIGGERED: {question[:40]} ({our_wp:.1%} < {STOP_LOSS_THRESHOLD:.0%})')
        try:
            positions = httpx.get(
                f'https://data-api.polymarket.com/positions?user={ADDR}&sizeThreshold=0.01', timeout=15
            ).json()
            pos = next((p for p in positions if p.get('conditionId') == condition_id), None)
            if not pos:
                print(f'Position not found on-chain')
                continue
            shares    = float(pos.get('size', 0))
            cur_price = float(pos.get('curPrice', 0))
            cur_value = float(pos.get('currentValue', 0))
            token     = pos.get('asset', '')
            sell_price = round(cur_price - 0.01, 3)

            result = asyncio.run(sell_position(token, shares, sell_price))
            print(f'SELL result: {result}')

            if result.get('success') or result.get('status') in ('matched', 'delayed'):
                pnl = round(cur_value - (trade.get('size_usd') or 0), 2)
                for t in journal['trades']:
                    if t.get('condition_id') == condition_id:
                        t['status'] = 'SOLD'
                        t['pnl'] = pnl
                        t['note'] = f'Auto stop-loss: ESPN {our_wp:.1%} < {STOP_LOSS_THRESHOLD:.0%}'
                        t['resolved_at'] = now.isoformat()
                json.dump(journal, open(f'{TRADING_DIR}/journal.json', 'w'), indent=2)
                msg = f'🛑 STOP-LOSS: {question[:40]} | ${cur_value:.2f} zurück | PnL: ${pnl:.2f}'
                print(f'STOP-LOSS SOLD: {msg}')
                send_telegram(msg)
        except Exception as e:
            print(f'Stop-loss error: {e}')

# ── 2. LIVE BUY: scan all live ESPN games for high-confidence opportunities ───
bought_this_run = set()  # (cid, tier_idx) — avoid double-buy in same run

for event in espn_events:
    teams = event.get('teams', [])
    for team in teams:
        wp = espn_data.get(team, 0)

        # Find highest applicable tier
        active_tier_idx = None
        for i, threshold in reversed(list(enumerate(BUY_TIERS))):
            if wp >= threshold:
                active_tier_idx = i
                break
        if active_tier_idx is None:
            continue

        # Find matching market in watchlist
        market = None
        for m in watchlist:
            if word_match(team, m.get('question', '')):
                market = m
                break
        if not market:
            print(f'[LIVEBUY] {team} ESPN={wp:.1%} — no watchlist match')
            continue

        cid = market.get('condition_id', '')

        # Check if this tier (or higher) already bought
        if (cid, active_tier_idx) in bought_tiers or (cid, active_tier_idx) in bought_this_run:
            print(f'[LIVEBUY] {team} tier={active_tier_idx} — already bought at this tier, skip')
            continue

        # Check current Polymarket price
        yes_price = float(market.get('yes_price') or market.get('amm_ask') or 1.0)
        no_price  = float(market.get('no_price')  or 1 - yes_price)

        # Determine buy side: team before "vs" → YES, after → NO
        q = market.get('question', '')
        before_vs = q.lower().split(' vs')[0] if ' vs' in q.lower() else q.lower()
        if word_match(team, before_vs):
            buy_side  = 'YES'
            buy_price = yes_price
            token_id  = market.get('yes_token_id') or market.get('clob_token_ids', [None])[0]
        else:
            buy_side  = 'NO'
            buy_price = no_price
            token_id  = market.get('no_token_id') or (market.get('clob_token_ids', [None, None])[1])

        if buy_price >= BUY_MAX_PRICE:
            print(f'[LIVEBUY] {team} ESPN={wp:.1%} price={buy_price:.2f} — too high, skip')
            continue

        edge = wp - buy_price
        if edge < 0.10:
            print(f'[LIVEBUY] {team} edge={edge:.1%} — insufficient, skip')
            continue

        # Divergence multiplier: bigger edge = more money
        if edge >= 0.35:
            div_mult = 2.0
        elif edge >= 0.20:
            div_mult = 1.5
        else:
            div_mult = 1.0

        # Quarter Kelly × divergence multiplier
        b = (1 - buy_price) / buy_price
        kelly = max(0, (wp * b - (1 - wp)) / b)
        bet = round(min(BUY_MAX_BET, max(BUY_MIN_BET, kelly * 0.25 * bankroll * div_mult)), 2)

        print(f'[LIVEBUY] {team} ESPN={wp:.1%} Poly={buy_price:.2f} edge={edge:.1%} tier={active_tier_idx} mult={div_mult}x bet=${bet:.2f}')

        if bankroll < bet + 2:
            print(f'[LIVEBUY] Insufficient bankroll (${bankroll:.2f})')
            continue
        if not token_id:
            print(f'[LIVEBUY] No token_id, skip')
            continue

        try:
            result = asyncio.run(buy_position(token_id, buy_price, bet))
            print(f'BUY result: {result}')
            if result.get('success') or result.get('orderID'):
                bought_this_run.add((cid, active_tier_idx))
                journal['trades'].append({
                    'bot_id': 'live_monitor',
                    'timestamp': now.isoformat(),
                    'question': market.get('question', ''),
                    'condition_id': cid,
                    'trade_side': buy_side,
                    'entry_price': buy_price,
                    'size_usd': bet,
                    'shares': round(bet / buy_price, 2),
                    'end_datetime': market.get('end_datetime', ''),
                    'confidence_pct': round(wp * 100, 1),
                    'research_summary': f'ESPN live: {team} {wp:.1%} win prob',
                    'status': 'open',
                    'outcome': None,
                    'pnl': None,
                    'order_id': result.get('orderID', ''),
                    'live_buy_tier': active_tier_idx,
                    'note': f'LIVE BUY tier{active_tier_idx}: ESPN {wp:.1%} vs Poly {buy_price:.2f} edge={edge:.1%} mult={div_mult}x',
                })
                json.dump(journal, open(f'{TRADING_DIR}/journal.json', 'w'), indent=2)
                msg = f'⚡ LIVE BUY T{active_tier_idx+1}: {q[:35]} | {buy_side} @{buy_price:.2f} | ESPN {wp:.1%} | ${bet:.2f}'
                print(msg)
                send_telegram(msg)
        except Exception as e:
            print(f'Live buy error: {e}')

PYEOF
