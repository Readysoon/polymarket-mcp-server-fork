#!/bin/bash
# live_monitor.sh — ESPN live win probability monitor + auto stop-loss
# Runs every 5 min, sells positions if ESPN win-prob drops below threshold

WORKSPACE="/home/node/.openclaw/workspace"
TRADING_DIR="$WORKSPACE/trading"

python3 << 'PYEOF'
import json, os, httpx, asyncio, sys
from datetime import datetime, timezone

WORKSPACE = os.environ.get('MW_WORKSPACE', '/home/node/.openclaw/workspace')
TRADING_DIR = f'{WORKSPACE}/trading'
STOP_LOSS_THRESHOLD = 0.22  # sell if ESPN win prob drops below 22%

# ── Load open positions from journal ─────────────────────────────────────────
try:
    journal = json.load(open(f'{TRADING_DIR}/journal.json'))
    open_trades = [t for t in journal.get('trades', [])
                   if t.get('status') in ('open', 'OPEN')]
except Exception as e:
    print(f'Journal error: {e}')
    sys.exit(0)

if not open_trades:
    sys.exit(0)

# ── Fetch ESPN live scores ───────────────────────────────────────────────────
def get_espn_winprob():
    results = {}
    sports = [('nba', 'basketball'), ('nhl', 'hockey'), ('ncaab', 'basketball/college-basketball')]
    for league, sport in sports:
        try:
            r = httpx.get(
                f'https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/scoreboard',
                timeout=8
            )
            for event in r.json().get('events', []):
                comp = event.get('competitions', [{}])[0]
                status = event.get('status', {})
                desc = status.get('type', {}).get('description', '')
                if desc not in ('In Progress', 'Halftime'):
                    continue
                situation = comp.get('situation', {})
                prob = situation.get('lastPlay', {}).get('probability', {})
                if not prob:
                    continue
                for c in comp.get('competitors', []):
                    name = c['team']['shortDisplayName']
                    home = c.get('homeAway', '') == 'home'
                    win_pct = prob.get('homeWinPercentage' if home else 'awayWinPercentage', None)
                    if win_pct is not None:
                        results[name.lower()] = round(win_pct, 4)
        except Exception as e:
            print(f'ESPN {league} error: {e}')
    return results

espn_data = get_espn_winprob()
if not espn_data:
    sys.exit(0)

print(f'ESPN live games: {list(espn_data.keys())}')

# ── Check each open trade ────────────────────────────────────────────────────
ADDR = os.environ.get('POLYGON_ADDRESS', '').lower()

for trade in open_trades:
    question = trade.get('question', '')
    side = trade.get('trade_side', 'YES')
    condition_id = trade.get('condition_id', '')

    # Find ALL matching ESPN teams in this question
    # For YES: we win if the matched team wins → use their win prob directly
    # For NO: we win if the YES-team loses → find the team that corresponds to our outcome
    # The journal stores 'outcome' field (e.g. "Hornets") = team we're backing
    outcome_team = trade.get('outcome', None)  # e.g. "Hornets" for a NO trade on Celtics vs Hornets

    matched_team = None
    matched_wp = None

    if outcome_team:
        # Try to match the outcome team directly (the team we need to WIN)
        outcome_lower = outcome_team.lower()
        for team, wp in espn_data.items():
            if team in outcome_lower or outcome_lower in team:
                matched_team = team
                matched_wp = wp
                our_wp = wp  # we win if outcome_team wins, regardless of YES/NO
                break

    if matched_wp is None:
        # Fallback: match any team in question
        all_matches = [(team, wp) for team, wp in espn_data.items() if team in question.lower()]
        if not all_matches:
            continue
        if side == 'YES':
            # Use first match (the team we're backing)
            matched_team, matched_wp = all_matches[0]
            our_wp = matched_wp
        else:
            # For NO, we win if the YES-team loses → use 1 - YES-team's win prob
            # But only if we couldn't find outcome_team above
            matched_team, matched_wp = all_matches[0]
            our_wp = 1 - matched_wp

    if matched_wp is None:
        continue

    print(f'{question[:45]} | side={side} | ESPN {matched_team}={matched_wp:.1%} | our_wp={our_wp:.1%}')

    if our_wp < STOP_LOSS_THRESHOLD:
        print(f'STOP-LOSS TRIGGERED: {question[:45]} — win prob {our_wp:.1%} < {STOP_LOSS_THRESHOLD:.0%}')

        # Get current position
        try:
            r = httpx.get(f'https://data-api.polymarket.com/positions?user={ADDR}&sizeThreshold=0.01', timeout=15)
            positions = r.json()
            matching_pos = None
            for p in positions:
                if p.get('conditionId') == condition_id:
                    matching_pos = p
                    break

            if not matching_pos:
                print(f'Position not found on-chain for {condition_id[:20]}')
                continue

            shares = float(matching_pos.get('size', 0))
            cur_price = float(matching_pos.get('curPrice', 0))
            token = matching_pos.get('asset', '')
            cur_value = float(matching_pos.get('currentValue', 0))

            print(f'Selling {shares} shares @ {cur_price:.3f} = ${cur_value:.2f}')

            # Sell via post_order
            sys.path.insert(0, f'{WORKSPACE}/src')

            async def sell():
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
                sell_price = round(cur_price - 0.01, 3)  # slightly below market
                # Round shares to valid combo
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
                return await client.post_order(
                    token_id=token,
                    price=sell_price,
                    size=round(best, 2),
                    side='SELL',
                    order_type='FOK'
                )

            result = asyncio.run(sell())
            print(f'SELL result: {result}')

            if result.get('success') or result.get('status') in ('matched', 'delayed'):
                # Update journal
                for t in journal['trades']:
                    if t.get('condition_id') == condition_id:
                        t['status'] = 'SOLD'
                        t['pnl'] = round(cur_value - (t.get('size_usd') or 0), 2)
                        t['note'] = f'Auto stop-loss: ESPN win-prob {our_wp:.1%} < {STOP_LOSS_THRESHOLD:.0%}'
                        t['resolved_at'] = datetime.now(timezone.utc).isoformat()
                json.dump(journal, open(f'{TRADING_DIR}/journal.json', 'w'), indent=2)
                print(f'STOP-LOSS SOLD: {question[:45]} | ${cur_value:.2f} back | pnl=${round(cur_value-(trade.get("size_usd",0)),2):.2f}')

        except Exception as e:
            print(f'Stop-loss sell error: {e}')

PYEOF
