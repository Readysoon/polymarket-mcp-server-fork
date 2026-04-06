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

# Paper trading mode
try:
    _cfg = json.load(open(f'{TRADING_DIR}/config.json'))
    PAPER_TRADING = _cfg.get('paper_trading', False)
except:
    PAPER_TRADING = False
if PAPER_TRADING:
    print('📝 PAPER TRADING MODE — kein echtes Geld')

BUY_MAX_PRICE       = 0.97   # nur kaufen wenn Preis < 97¢ (mind. 3¢ Auszahlungspotenzial)
BUY_MIN_BET         = 2.50
BUY_MAX_BET         = 99999.00  # kein Cap — Quarter Kelly bestimmt die Größe

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
    journal = {'trades': []}
    open_trades = []
    now = datetime.now(timezone.utc)
# Note: we no longer exit early if no open trades — ESPN live opportunities
# can be found independently of pre-existing positions

# ── Fetch ESPN live win probabilities ─────────────────────────────────────────
def get_espn_winprob():
    results = {}      # team_lower → win_pct
    events_raw = []
    margins = {}      # team_lower → current lead margin (positive = leading, negative = trailing)

    # ESPN-based leagues with reliable live win probabilities
    # NBA: year-round | NFL: Sept-Jan | NCAA Football: Sept-Jan | NCAAB: Nov-March
    espn_sports = [
        ('nba',   'basketball'),
        ('nfl',   'football'),
        ('college-football', 'football'),
        ('ncaab', 'basketball/college-basketball'),
    ]
    # Note: NHL excluded — no reliable live win probability source
    for league, sport in espn_sports:
        try:
            r = httpx.get(
                f'https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/scoreboard',
                timeout=8
            )
            for event in r.json().get('events', []):
                comp  = event.get('competitions', [{}])[0]
                desc  = event.get('status', {}).get('type', {}).get('description', '')
                if desc not in ('In Progress', 'Halftime', 'In Progress - Rain Delay'):
                    continue
                prob = comp.get('situation', {}).get('lastPlay', {}).get('probability', {})
                if not prob:
                    continue
                competitors = comp.get('competitors', [])
                teams = []
                scores = {}
                for c in competitors:
                    name = c['team']['shortDisplayName']
                    home = c.get('homeAway', '') == 'home'
                    wp   = prob.get('homeWinPercentage' if home else 'awayWinPercentage', None)
                    try:
                        score = int(c.get('score', 0) or 0)
                    except:
                        score = 0
                    scores[name.lower()] = score
                    if wp is not None:
                        results[name.lower()] = round(wp, 4)
                        teams.append(name.lower())
                # Calculate margins: positive = leading
                if len(teams) == 2:
                    t0, t1 = teams[0], teams[1]
                    margin_t0 = scores.get(t0, 0) - scores.get(t1, 0)
                    margins[t0] = margin_t0
                    margins[t1] = -margin_t0
                if teams:
                    events_raw.append({'teams': teams, 'league': league})
        except Exception as e:
            print(f'ESPN {league} error: {e}')

    # MLB via Fangraphs live win probability
    try:
        r = httpx.get('https://www.fangraphs.com/api/livescoreboard', timeout=8)
        for game in r.json().get('games', []):
            if game.get('GameStatus') != 'Inprogress':
                continue
            home_wp = game.get('HomeWinProbability')
            away_wp = game.get('AwayWinProbability')
            home_team = game.get('HomeTeamShortName', '').lower()
            away_team = game.get('AwayTeamShortName', '').lower()
            if home_wp is not None and home_team:
                results[home_team] = round(float(home_wp), 4)
            if away_wp is not None and away_team:
                results[away_team] = round(float(away_wp), 4)
            if home_team and away_team:
                events_raw.append({'teams': [home_team, away_team], 'league': 'mlb'})
    except Exception as e:
        print(f'Fangraphs MLB error: {e}')

    return results, events_raw, margins

# Punkt 2: CLOB Live-Preis abfragen
def get_clob_price(token_id):
    """Get live bid/ask from Polymarket CLOB for accurate pricing."""
    try:
        r = httpx.get(
            f'https://clob.polymarket.com/book?token_id={token_id}',
            timeout=5
        )
        data = r.json()
        bids = data.get('bids', [])
        asks = data.get('asks', [])
        best_bid = float(bids[0]['price']) if bids else None
        best_ask = float(asks[0]['price']) if asks else None
        mid = round((best_bid + best_ask) / 2, 4) if best_bid and best_ask else None
        return best_bid, best_ask, mid
    except:
        return None, None, None

espn_data, espn_events, espn_margins = get_espn_winprob()
if not espn_data:
    print('No ESPN live games')
    sys.exit(0)

print(f'ESPN live: {list(espn_data.keys())}')

# ── Fetch Polymarket markets only for teams currently live on ESPN ────────────
def fetch_markets_for_teams(live_teams):
    """Search Polymarket for live teams in parallel (faster, avoids timeouts)."""
    if not live_teams:
        return []
    import concurrent.futures
    seen_cids = set()
    markets = []

    def search_team(team):
        try:
            # Probiere mehrere Suchanfragen: Kurzname, Varianten
            candidates = []
            for search_term in [team, team.title()]:
                for endpoint, params in [
                    ('https://gamma-api.polymarket.com/markets', {'active': 'true', 'closed': 'false', 'limit': '20', 'search': search_term}),
                    ('https://gamma-api.polymarket.com/events', {'active': 'true', 'closed': 'false', 'limit': '10', 'search': search_term, 'tag_slug': 'nba'}),
                ]:
                    try:
                        r = httpx.get(endpoint, params=params, timeout=6)
                        raw = r.json()
                        # Events API gibt Liste von Events mit markets drin
                        if 'events' in endpoint or (isinstance(raw, list) and raw and 'markets' in raw[0]):
                            for ev in (raw if isinstance(raw, list) else []):
                                for m in ev.get('markets', []):
                                    candidates.append(m)
                        else:
                            data = raw if isinstance(raw, list) else raw.get('markets', raw)
                            candidates.extend(data if isinstance(data, list) else [])
                    except:
                        pass
            results = []
            seen = set()
            for m in candidates:
                q = m.get('question', '')
                cid = m.get('conditionId', '') or m.get('condition_id', '')
                if not cid: continue

                # Erlaubte Markttypen:
                # 1. Moneyline: "Team A vs. Team B"
                # 2. Spread: "Spread: Team (-X.5)" oder "Team (-X.5)"
                # 3. Kein O/U, Handicap, Props, Maps
                q_lower = q.lower()
                is_moneyline = (' vs. ' in q or ' vs ' in q)
                is_spread = ('spread' in q_lower or (team.lower() in q_lower and any(x in q for x in ['-', '+']) and '.5' in q))
                if not is_moneyline and not is_spread: continue
                if any(x in q_lower for x in ['o/u', 'over', 'under', 'handicap', 'total', 'map', 'game ', 'pts', 'points', 'assists', 'rebounds', 'wins the']):
                    continue

                # outcomePrices kann JSON-String sein
                oprices_raw = m.get('outcomePrices', ['0.5', '0.5'])
                if isinstance(oprices_raw, str):
                    import json as _j
                    try: oprices_raw = _j.loads(oprices_raw)
                    except: oprices_raw = ['0.5', '0.5']
                yes_price = float(oprices_raw[0]) if oprices_raw else 0.5

                tokens = m.get('clobTokenIds', []) or m.get('clob_token_ids', [])
                results.append({
                    'question': q,
                    'condition_id': cid,
                    'yes_price': yes_price,
                    'no_price': round(1 - yes_price, 4),
                    'yes_token_id': tokens[0] if len(tokens) > 0 else '',
                    'no_token_id': tokens[1] if len(tokens) > 1 else '',
                    'end_datetime': m.get('endDate', '') or m.get('end_date_iso', ''),
                    'liquidity': float(m.get('liquidity', 0) or 0),
                    'market_type': 'spread' if is_spread and not is_moneyline else 'moneyline',
                })
                seen.add(cid)
            return results
        except Exception as e:
            print(f'Polymarket search error ({team}): {e}')
            return []

    # Parallel fetch — all teams simultaneously
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        futures = {executor.submit(search_team, team): team for team in live_teams}
        for future in concurrent.futures.as_completed(futures, timeout=10):
            for m in future.result():
                if m['condition_id'] not in seen_cids:
                    seen_cids.add(m['condition_id'])
                    markets.append(m)

    # Fallback: alle heutigen NBA/MLB Events direkt von Polymarket laden
    if not markets:
        try:
            fallback = []
            seen_fb = set()
            for tag in ['nba', 'mlb', 'nfl']:
                r = httpx.get('https://gamma-api.polymarket.com/events',
                    params={'tag_slug': tag, 'active': 'true', 'closed': 'false', 'limit': 50},
                    timeout=8)
                for ev in r.json():
                    title = ev.get('title','')
                    if ' vs' not in title: continue
                    for m in ev.get('markets', []):
                        q = m.get('question','')
                        cid = m.get('conditionId','') or m.get('condition_id','')
                        if not cid or cid in seen_fb: continue
                        q_lower = q.lower()
                        if any(x in q_lower for x in ['o/u','over','under','total','pts','points','assists','rebounds','1h ']):
                            continue
                        oprices_raw = m.get('outcomePrices', ['0.5','0.5'])
                        if isinstance(oprices_raw, str):
                            import json as _jj
                            try: oprices_raw = _jj.loads(oprices_raw)
                            except: oprices_raw = ['0.5','0.5']
                        yes_price = float(oprices_raw[0]) if oprices_raw else 0.5
                        tokens = m.get('clobTokenIds',[]) or []
                        if isinstance(tokens, str):
                            import json as _jj
                            try: tokens = _jj.loads(tokens)
                            except: tokens = []
                        seen_fb.add(cid)
                        fallback.append({
                            'question': q,
                            'condition_id': cid,
                            'yes_price': yes_price,
                            'no_price': round(1 - yes_price, 4),
                            'yes_token_id': tokens[0] if len(tokens) > 0 else '',
                            'no_token_id': tokens[1] if len(tokens) > 1 else '',
                            'end_datetime': m.get('endDate','') or '',
                            'liquidity': float(m.get('liquidity', 0) or 0),
                            'market_type': 'spread' if 'spread' in q_lower else 'moneyline',
                        })
            if fallback:
                markets = fallback
                print(f'Fallback: {len(markets)} Polymarket markets from today events')
            else:
                # Letzter Fallback: Watchlist
                markets = json.load(open(f'{TRADING_DIR}/watchlist.json')).get('markets', [])
                print(f'Fallback: watchlist ({len(markets)} markets)')
        except Exception as _fe:
            print(f'Fallback error: {_fe}')
    print(f'Markets fetched for {len(live_teams)} live teams: {len(markets)} found')
    return markets

# Get live team names — only teams with ESPN >= 85% (likely candidates)
# Cap at 10 teams to avoid Polymarket rate limits
live_teams_display = []
for event in espn_events:
    for team in event.get('teams', []):
        wp = espn_data.get(team, 0)
        if wp >= 0.85 and team not in live_teams_display:
            live_teams_display.append(team)

# If no team is at 85%+, fetch all live teams (capped at 10)
if not live_teams_display:
    for event in espn_events:
        for team in event.get('teams', []):
            if team not in live_teams_display:
                live_teams_display.append(team)
    live_teams_display = live_teams_display[:10]

print(f'Teams to search (ESPN ≥85% or top 10): {live_teams_display}')
watchlist = fetch_markets_for_teams(live_teams_display)

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

# ── Helper: round shares to valid increment ───────────────────────────────────
def round_shares(raw, price):
    best = None
    for q in range(max(1, int(raw * 4) - 8), int(raw * 4) + 9):
        ts = round(q / 4, 2)
        tc = ts * price
        if abs(tc - round(tc, 2)) < 1e-9:
            if best is None or abs(ts - raw) < abs(best - raw):
                best = ts
    return round(best if best is not None else round(raw / 0.25) * 0.25, 2)

# ── Helper: sell position (aggressive FOK ladder) ─────────────────────────────
async def sell_position(token, shares, cur_price):
    """Try to sell at progressively lower prices until filled."""
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

    # Stufenweise: bid-0.01 → bid-0.03 → bid-0.05 → bid (market)
    offsets = [0.01, 0.03, 0.05, 0.00]
    for i, offset in enumerate(offsets):
        price = max(0.01, round(cur_price - offset, 3))
        size = round_shares(shares, price)
        order_type = 'FOK'
        print(f'SELL attempt {i+1}/4: price={price:.3f} size={size} ({order_type})')
        try:
            result = await client.post_order(
                token_id=token, price=price, size=size,
                side='SELL', order_type=order_type
            )
            status = result.get('status', '')
            success = result.get('success') or result.get('orderID') or status in ('matched', 'delayed')
            print(f'  → {status} | success={success}')
            if success and status != 'unmatched':
                return result
            # unmatched or no fill → try lower price
        except Exception as e:
            print(f'  → error: {e}')
            # orderbook gone or other error → abort
            if 'does not exist' in str(e) or 'orderbook' in str(e).lower():
                print('  → orderbook closed, aborting')
                return {'success': False, 'error': str(e)}

    return {'success': False, 'error': 'All sell attempts failed'}

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

    # FOK = Fill or Kill: sofort gefüllt oder sofort storniert
    # Kein offenes GTC das nie gefüllt wird aber als "Trade" gilt
    # Preis leicht über Ask damit wir tatsächlich matchen
    order_price = round(price + 0.01, 2)  # 2 decimal places → maker_amount stays clean
    shares = round(size_usd / order_price, 2)  # 2 decimal shares: price*shares has max 4 digits
    result = await client.post_order(token_id=token_id, price=order_price,
                                     size=shares, side='BUY', order_type='FOK')

    # FOK: prüfe ob wirklich gefüllt — errorMsg "no match" bedeutet nicht gefüllt
    error_msg = result.get('errorMsg', '') or ''
    if 'no match' in error_msg.lower() or 'not matched' in error_msg.lower() or 'insufficient' in error_msg.lower():
        print(f'FOK not filled: {error_msg}')
        return {'success': False, 'error': error_msg, 'filled': False}

    # Kein orderID zurück → auch nicht gefüllt
    if not result.get('orderID') and not result.get('order_id'):
        print(f'FOK no orderID: {result}')
        return {'success': False, 'error': 'no orderID', 'filled': False}

    result['filled'] = True
    return result

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

            if PAPER_TRADING:
                result = {'success': True, 'status': 'paper', 'paper': True}
                print(f'📝 PAPER STOP-LOSS: würde {shares} shares @ {cur_price:.3f} verkaufen')
            else:
                result = asyncio.run(sell_position(token, shares, cur_price))
            print(f'SELL result: {result}')

            if result.get('success') or result.get('status') in ('matched', 'delayed', 'paper'):
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

                # Paper bankroll: Geld zurückbuchen
                if PAPER_TRADING:
                    try:
                        import os as _os
                        pb_path = f'{TRADING_DIR}/paper_bankroll.json'
                        pb = json.load(open(pb_path)) if _os.path.exists(pb_path) else {'current_balance': 151.91, 'paper_pnl': 0.0, 'history': []}
                        pb['current_balance'] = round(pb.get('current_balance', 151.91) + cur_value, 2)
                        pb['paper_pnl'] = round(pb.get('paper_pnl', 0) + pnl, 2)
                        pb.setdefault('history', []).append({
                            't': now.isoformat(),
                            'balance': pb['current_balance'],
                            'event': 'paper_stop_loss',
                            'question': question[:50],
                            'pnl': pnl,
                            'returned': cur_value,
                        })
                        pb['updated_at'] = now.isoformat()
                        json.dump(pb, open(pb_path, 'w'), indent=2)
                    except Exception as _pe:
                        print(f'Paper bankroll stop-loss update error: {_pe}')
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

        # Agent entscheidet die richtige Seite via Claude API
        q = market.get('question', '')
        yes_token_id = market.get('yes_token_id') or market.get('clob_token_ids', [None])[0]
        no_token_id  = market.get('no_token_id') or (market.get('clob_token_ids', [None, None])[1])

        # Prüfe ob CLOB noch Orders akzeptiert (Markt offen?)
        try:
            _clob_info = httpx.get(f'https://clob.polymarket.com/markets/{cid}', timeout=5).json()
            if not _clob_info.get('accepting_orders', True):
                print(f'[LIVEBUY] {team} — CLOB accepting_orders=false, Markt geschlossen, skip')
                continue
        except Exception as _e:
            print(f'[LIVEBUY] CLOB market check error: {_e}')

        # Spread-Check: nur kaufen wenn aktueller Vorsprung > Spread-Linie
        market_type = market.get('market_type', 'moneyline')
        if market_type == 'spread':
            # Spread-Linie aus Frage extrahieren: "Spread: Cavaliers (-13.5)" → 13.5
            import re as _re
            spread_match = _re.search(r'\([-+]?(\d+\.?\d*)\)', q)
            if spread_match:
                spread_line = float(spread_match.group(1))
                current_margin = espn_margins.get(team, None)
                if current_margin is None:
                    print(f'[LIVEBUY] {team} spread — kein Spielstand verfügbar, skip')
                    continue
                if current_margin <= spread_line:
                    print(f'[LIVEBUY] {team} spread {spread_line} — Vorsprung {current_margin:.0f} Punkte reicht nicht, skip')
                    continue
                print(f'[LIVEBUY] {team} spread {spread_line} ✓ — Vorsprung {current_margin:.0f} Punkte deckt Spread')
            else:
                print(f'[LIVEBUY] {team} — Spread-Linie nicht lesbar aus "{q}", skip')
                continue

        # Live CLOB prices
        yes_clob_bid, yes_clob_ask, yes_clob_mid = get_clob_price(yes_token_id) if yes_token_id else (None, None, None)
        no_clob_bid,  no_clob_ask,  no_clob_mid  = get_clob_price(no_token_id)  if no_token_id  else (None, None, None)
        yes_mid = yes_clob_mid if yes_clob_mid is not None else yes_price
        no_mid  = no_clob_mid  if no_clob_mid  is not None else no_price

        def ask_claude_side(question, team_name, espn_wp, yes_mid, no_mid):
            """Ask Claude which token to buy to bet ON this team winning."""
            try:
                prompt = (
                    f'Polymarket question: "{question}"\n'
                    f'I want to profit if "{team_name}" wins/covers this game.\n'
                    f'YES token price: {yes_mid:.3f} (implies YES outcome wins with {yes_mid:.0%} prob)\n'
                    f'NO token price: {no_mid:.3f} (implies YES outcome loses with {no_mid:.0%} prob)\n'
                    f'ESPN win probability for "{team_name}": {espn_wp:.0%}\n\n'
                    f'For spread markets like "Spread: Team (-X.5)", YES means the team covers.\n'
                    f'For moneyline markets like "Team A vs Team B", YES means Team A wins.\n'
                    f'Which token (YES or NO) should I buy to profit if "{team_name}" wins/covers?\n'
                    f'Reply with exactly one word: YES or NO'
                )
                r = httpx.post(
                    'https://api.anthropic.com/v1/messages',
                    headers={
                        'x-api-key': os.environ.get('ANTHROPIC_API_KEY', ''),
                        'anthropic-version': '2023-06-01',
                        'content-type': 'application/json',
                    },
                    json={
                        'model': 'claude-haiku-4-5',
                        'max_tokens': 10,
                        'messages': [{'role': 'user', 'content': prompt}]
                    },
                    timeout=8
                )
                answer = r.json()['content'][0]['text'].strip().upper()
                if 'YES' in answer:
                    return 'YES'
                elif 'NO' in answer:
                    return 'NO'
            except Exception as e:
                print(f'Claude side decision error: {e}')
            # Fallback: price proximity
            return 'YES' if abs(yes_mid - espn_wp) <= abs(no_mid - espn_wp) else 'NO'

        buy_side = ask_claude_side(q, team, wp, yes_mid, no_mid)

        if buy_side == 'YES':
            buy_price = yes_clob_ask if yes_clob_ask else yes_price
            token_id  = yes_token_id
        else:
            buy_price = no_clob_ask if no_clob_ask else no_price
            token_id  = no_token_id

        print(f'[SIDE] {team} ESPN={wp:.1%} | YES={yes_mid:.3f} NO={no_mid:.3f} → Claude says: {buy_side} @{buy_price:.3f}')

        # KEIN end_datetime Check mehr — Polymarket setzt end_datetime = Tip-Off,
        # aber der CLOB bleibt während des Spiels aktiv (P2P Trading möglich).
        # ESPN gibt uns nur live Teams wenn das Spiel wirklich läuft (status "In Progress").
        # Ein Final/ended Spiel erscheint nicht mehr in get_espn_winprob() → natürlicher Filter.

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
            if PAPER_TRADING:
                result = {'success': True, 'orderID': f'PAPER-{cid[:16]}', 'status': 'paper', 'paper': True}
                print(f'📝 PAPER LIVE BUY: würde {buy_side} @{buy_price:.3f} für ${bet:.2f} kaufen')
            else:
                # Prüfe verfügbare Liquidität im Ask-Buch
                shares_wanted = round(bet / buy_price, 2)
                available_shares = 0.0
                try:
                    book = httpx.get(f'https://clob.polymarket.com/book?token_id={token_id}', timeout=5).json()
                    for ask in book.get('asks', []):
                        if float(ask.get('price', 1)) <= buy_price + 0.02:  # leichte Toleranz
                            available_shares += float(ask.get('size', 0))
                except Exception as _be:
                    print(f'Book check error: {_be}')
                    available_shares = shares_wanted  # assume ok if check fails

                if available_shares <= 0:
                    print(f'[LIVEBUY] Kein Liquidität im Ask-Buch, skip')
                    continue

                # Wenn nicht genug für volle Order → halbe Shares probieren (min 2 Retries)
                actual_shares = shares_wanted
                actual_bet = bet
                if available_shares < shares_wanted:
                    actual_shares = round(min(available_shares * 0.9, shares_wanted / 2), 2)
                    actual_bet = round(actual_shares * buy_price, 2)
                    print(f'[LIVEBUY] Nur {available_shares:.1f} Shares verfügbar → reduziere auf {actual_shares:.1f} Shares (${actual_bet:.2f})')
                    if actual_bet < BUY_MIN_BET:
                        print(f'[LIVEBUY] Reduzierter Bet ${actual_bet:.2f} < Min ${BUY_MIN_BET:.2f}, skip')
                        continue

                # Loop: probiere immer kleinere Beträge bis FOK erfolgreich
                total_filled_shares = 0.0
                total_filled_usd = 0.0
                attempt_shares = actual_shares
                attempt_bet = actual_bet
                last_result = None
                while attempt_bet >= BUY_MIN_BET:
                    attempt_result = asyncio.run(buy_position(token_id, buy_price, attempt_bet))
                    print(f'  Attempt {attempt_shares:.1f} shares ${attempt_bet:.2f}: filled={attempt_result.get("filled")} err={attempt_result.get("error","")}')
                    if attempt_result.get('filled'):
                        total_filled_shares += attempt_shares
                        total_filled_usd += attempt_bet
                        last_result = attempt_result
                        print(f'  ✓ Filled {attempt_shares:.1f} shares — total so far: {total_filled_shares:.1f} shares ${total_filled_usd:.2f}')
                        # Prüfe ob noch mehr Liquidität vorhanden
                        remaining = actual_shares - total_filled_shares
                        if remaining < 1:
                            break
                        next_shares = round(min(remaining, attempt_shares), 2)
                        next_bet = round(next_shares * buy_price, 2)
                        if next_bet < BUY_MIN_BET:
                            break
                        attempt_shares = next_shares
                        attempt_bet = next_bet
                    else:
                        # FOK miss — halbiere und probiere nochmal
                        attempt_shares = round(attempt_shares / 2, 2)
                        attempt_bet = round(attempt_shares * buy_price, 2)
                        if attempt_bet < BUY_MIN_BET:
                            break

                result = last_result or {'filled': False}
                bet = total_filled_usd if total_filled_usd > 0 else bet
                actual_shares = total_filled_shares if total_filled_shares > 0 else actual_shares
                print(f'[LIVEBUY] Gesamt gefüllt: {total_filled_shares:.1f} shares / ${total_filled_usd:.2f} von Ziel ${actual_bet:.2f}')

            print(f'BUY result: {result}')
            filled = result.get('filled', False) or (result.get('success') and result.get('orderID') and PAPER_TRADING)
            if not filled:
                print(f'[LIVEBUY] Keine einzige Order gefüllt — kein Journal-Eintrag')
                continue
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
                    'paper': PAPER_TRADING,
                })
                json.dump(journal, open(f'{TRADING_DIR}/journal.json', 'w'), indent=2)

                # Paper bankroll update
                if PAPER_TRADING:
                    try:
                        import os as _os
                        pb_path = f'{TRADING_DIR}/paper_bankroll.json'
                        pb = json.load(open(pb_path)) if _os.path.exists(pb_path) else {'current_balance': 151.91, 'paper_pnl': 0.0, 'history': []}
                        pb['current_balance'] = round(pb.get('current_balance', 151.91) - bet, 2)
                        pb.setdefault('history', []).append({
                            't': now.isoformat(),
                            'balance': pb['current_balance'],
                            'event': 'paper_live_buy',
                            'question': market.get('question','')[:50],
                            'side': buy_side,
                            'tier': active_tier_idx + 1,
                            'espn_wp': round(wp * 100, 1),
                            'price': buy_price,
                            'size_usd': bet,
                        })
                        pb['updated_at'] = now.isoformat()
                        json.dump(pb, open(pb_path, 'w'), indent=2)
                        print(f'📝 Paper Bankroll: ${pb["current_balance"]:.2f} (invested ${bet:.2f})')
                    except Exception as _pe:
                        print(f'Paper bankroll update error: {_pe}')

                msg = f'⚡ LIVE BUY T{active_tier_idx+1}: {q[:35]} | {buy_side} @{buy_price:.2f} | ESPN {wp:.1%} | ${bet:.2f}'
                print(msg)
        except Exception as e:
            print(f'Live buy error: {e}')

PYEOF
