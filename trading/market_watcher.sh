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

# ── Telegram helper ─────────────────────────────────────────────────────────
def send_telegram(msg):
    try:
        import subprocess as _sp
        _sp.run([
            'curl', '-s', '-X', 'POST',
            'https://api.telegram.org/bot8599638540:AAFVTzaLBWQmStBfdd3xSlPEJJQuMH4cEBI/sendMessage',
            '-d', f'chat_id=866661912&text={msg[:1000]}'
        ], capture_output=True, timeout=10)
    except: pass

def queue_error(error_msg, context=""):
    """Write error to queue for Sonnet to auto-fix via heartbeat."""
    try:
        eq_path = f"{TRADING_DIR}/error_queue.json"
        try:
            with open(eq_path) as f:
                queue = json.load(f)
        except:
            queue = []
        queue.append({
            "timestamp": now.isoformat(),
            "script": "market_watcher.sh",
            "error": error_msg[:500],
            "context": context[:300],
            "question": QUESTION,
            "condition_id": CONDITION_ID,
        })
        with open(eq_path, 'w') as f:
            json.dump(queue, f, indent=2)
    except: pass

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
    # Use --args JSON to ensure correct types (numbers stay numbers, not strings)
    args = ['mcporter', 'call', f'polymarket.{tool}', '--args', json.dumps(kwargs)]
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(r.stdout)
    except:
        return {'error': r.stdout.strip() + r.stderr.strip()}

# ── Research Gate ────────────────────────────────────────────────────────────
RESEARCH_FILE="$TRADING_DIR/research.json"
if [ -f "$RESEARCH_FILE" ]; then
    RESEARCH_DECISION=$(python3 -c "
import json, sys
with open('$RESEARCH_FILE') as f:
    r = json.load(f)
entry = r.get('$CONDITION_ID', {})
decision = entry.get('decision', 'SKIP')
confidence = entry.get('confidence_pct', 0)
reason = entry.get('sources_summary', 'no research')
print(f'{decision}|{confidence}|{reason[:80]}')
" 2>/dev/null)
    DECISION=$(echo "$RESEARCH_DECISION" | cut -d'|' -f1)
    CONFIDENCE=$(echo "$RESEARCH_DECISION" | cut -d'|' -f2)
    REASON=$(echo "$RESEARCH_DECISION" | cut -d'|' -f3)

    if [ "$DECISION" != "TRADE" ] || [ "${CONFIDENCE:-0}" -lt 65 ] 2>/dev/null; then
        echo "NO_TRADE (research gate): decision=$DECISION confidence=$CONFIDENCE% reason=$REASON"
        python3 -c "
import json
from datetime import datetime, timezone
with open('$TRADING_DIR/log.json') as f: log = json.load(f)
log.append({'timestamp': datetime.now(timezone.utc).isoformat(), 'question': '$QUESTION', 'condition_id': '$CONDITION_ID', 'result': 'NO_TRADE', 'reason': 'Research gate: decision=$DECISION confidence=$CONFIDENCE', 'action': 'Skipped'})
with open('$TRADING_DIR/log.json', 'w') as f: json.dump(log, f, indent=2)
" 2>/dev/null
        exit 0
    fi
    echo "Research gate passed: $DECISION $CONFIDENCE% — $REASON"
else
    echo "WARNING: research.json not found — proceeding without research gate"
fi

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
                "message": f"Run market watcher for: {QUESTION[:60]}\n\nbash /home/node/.openclaw/workspace/trading/market_watcher.sh '{CONDITION_ID}' '{YES_TOKEN}' '{END_DATETIME}' '{QUESTION[:60]}'\n\nAfter running, always notify Philipp on Telegram with the result: TRADED (what was bought + price), NO_TRADE (reason), or error. If there is a technical error in the script: debug it, fix the code in /home/node/.openclaw/workspace/trading/market_watcher.sh, run the fix, git push to the fork, then notify Philipp on Telegram what was fixed. Never give up silently.",
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
    send_telegram(f"⏰ TIMEOUT: {QUESTION[:50]}\nMarket closed before tradeable — abandoned.")
    sys.exit(0)

best_bid = float(price_data['bid'])
best_ask = float(price_data['ask'])
# AMM can return bid > ask — normalize
if best_bid > best_ask:
    best_bid, best_ask = best_ask, best_bid
spread = best_ask - best_bid
mid = (best_bid + best_ask) / 2

# Load config early for filter values
with open(f'{TRADING_DIR}/config.json') as _cf:
    _early_config = json.load(_cf)
MAX_SPREAD = float(_early_config.get('max_spread', 0.05))
MIN_HOURS = float(_early_config.get('min_hours_before_close', 3.0))

# Minimum hours before close check
if hours_left < MIN_HOURS:
    entry = {
        "timestamp": now.isoformat(),
        "question": QUESTION,
        "condition_id": CONDITION_ID,
        "end_datetime": END_DATETIME,
        "hours_left": round(hours_left, 2),
        "result": "NO_TRADE",
        "reason": f"Only {hours_left:.1f}h left, minimum is {MIN_HOURS}h",
        "action": "Skipped — too close to close"
    }
    write_log(entry)
    print(json.dumps(entry))
    sys.exit(0)

if spread > MAX_SPREAD:
    if hours_left > 0.5:
        retry_mins = 15
        fire_at = (now + timedelta(minutes=retry_mins)).strftime('%Y-%m-%dT%H:%M:%SZ')
        job = {
            "name": f"watch:{CONDITION_ID[:16]}",
            "schedule": {"kind": "at", "at": fire_at},
            "payload": {
                "kind": "agentTurn",
                "message": f"Run market watcher for: {QUESTION[:60]}\n\nbash /home/node/.openclaw/workspace/trading/market_watcher.sh '{CONDITION_ID}' '{YES_TOKEN}' '{END_DATETIME}' '{QUESTION[:60]}'\n\nAfter running, always notify Philipp on Telegram with the result: TRADED (what was bought + price), NO_TRADE (reason), or error. If there is a technical error in the script: debug it, fix the code in /home/node/.openclaw/workspace/trading/market_watcher.sh, run the fix, git push to the fork, then notify Philipp on Telegram what was fixed. Never give up silently.",
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
    send_telegram(f"⏰ TIMEOUT: {QUESTION[:50]}\nSpread too wide until close — abandoned.")
    sys.exit(0)

# ── Spread OK — attempt trade ────────────────────────────────────────────────
# Load config
with open(f'{TRADING_DIR}/config.json') as f:
    prod_config = json.load(f)

min_p = prod_config.get('min_yes_price', 0.50)
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

# Get real balance via RPC
import httpx as _httpx
_address = os.environ.get('POLYGON_ADDRESS', '').lower()
_selector = '0x70a08231' + _address[2:].zfill(64)
_rpcs = ['https://polygon-bor-rpc.publicnode.com', 'https://polygon.llamarpc.com']
_tokens = ['0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359', '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174']
total_balance = 0.0
for _token in _tokens:
    for _rpc in _rpcs:
        try:
            _r = _httpx.post(_rpc, json={'jsonrpc':'2.0','method':'eth_call','params':[{'to':_token,'data':_selector},'latest'],'id':1}, timeout=5.0)
            _val = _r.json().get('result','0x0')
            if _val and _val != '0x':
                total_balance += int(_val, 16) / 1e6
                break
        except: continue
print(f"Balance: ${total_balance:.2f} USDC")

# ── Auto-approve USDC.e to NegRisk CTF Exchange if needed ────────────────────
try:
    import httpx as _ha
    from eth_account import Account as _EthAcct
    _PRIV = os.environ.get('POLYGON_PRIVATE_KEY', '')
    _ADDR = os.environ.get('POLYGON_ADDRESS', '')
    _USDC_E = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
    _NEGRISK = "0xC5d563A36AE78145C45a50134d48A1215220f80a"
    _RPC2 = 'https://polygon-bor-rpc.publicnode.com'
    # Check current allowance
    _al_sel = '0xdd62ed3e' + _ADDR.lower()[2:].zfill(64) + _NEGRISK.lower()[2:].zfill(64)
    _ar = _ha.post(_RPC2, json={'jsonrpc':'2.0','method':'eth_call','params':[{'to':_USDC_E,'data':_al_sel},'latest'],'id':1}, timeout=5.0)
    _al_raw = _ar.json().get('result','0x0')
    _al_val = int(_al_raw, 16) / 1e6 if _al_raw not in ('0x', '0x0', None) else 0.0
    MIN_ALLOWANCE = 50.0  # Keep at least $50 approved
    if _al_val < MIN_ALLOWANCE and _PRIV:
        print(f"AUTO-APPROVE: USDC.e allowance ${_al_val:.4f} < ${MIN_ALLOWANCE} — approving MAX...")
        _a_sel = bytes.fromhex('095ea7b3')
        _a_data = _a_sel + bytes.fromhex(_NEGRISK[2:].zfill(64)) + (2**256 - 1).to_bytes(32, 'big')
        _ng = _ha.post(_RPC2, json={'jsonrpc':'2.0','method':'eth_getTransactionCount','params':[_ADDR,'latest'],'id':2}, timeout=5.0)
        _nonce = int(_ng.json()['result'], 16)
        _gp = _ha.post(_RPC2, json={'jsonrpc':'2.0','method':'eth_gasPrice','params':[],'id':3}, timeout=5.0)
        _gas_price = int(_gp.json()['result'], 16)
        _atx = {'to': _USDC_E,'from':_ADDR,'nonce':_nonce,'gas':100000,'gasPrice':_gas_price,'data':'0x'+_a_data.hex(),'chainId':137,'value':0}
        _acct2 = _EthAcct.from_key(_PRIV)
        _signed2 = _acct2.sign_transaction(_atx)
        _sr = _ha.post(_RPC2, json={'jsonrpc':'2.0','method':'eth_sendRawTransaction','params':['0x'+_signed2.raw_transaction.hex()],'id':4}, timeout=10.0)
        _tx_hash = _sr.json().get('result','')
        print(f"AUTO-APPROVE TX: {_tx_hash}")
        import time as _t2; _t2.sleep(12)  # wait for approval to mine
    else:
        print(f"Allowance OK: USDC.e NegRisk allowance ${_al_val:.2f}")
except Exception as _ae:
    print(f"AUTO-APPROVE ERROR (non-fatal): {_ae}")

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

# Bet sizing: dynamic $1-3 based on AI confidence (set after analysis)
bet_size = 2.00  # default, overridden after AI analysis
print(f"Bet size (default): ${bet_size:.2f}")

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

# AI analysis before placing order
# Note: the agent running this script should also search for recent news about the market
# using web_search before making the final trade decision
print(f"Analyzing market opportunity for: {QUESTION[:60]}")
analysis = mcporter('analyze_market_opportunity', market_id=CONDITION_ID)
analysis_text = str(analysis)

# Extract recommendation from analysis
should_trade = False
trade_side = 'BUY'
analysis_reason = "No analysis available"

if isinstance(analysis, dict) and 'error' not in analysis:
    rec = str(analysis.get('recommendation', '') or analysis.get('action', '') or '').upper()
    confidence = float(analysis.get('confidence', 0) or analysis.get('confidence_score', 0) or 0)
    analysis_reason = analysis.get('reasoning', '') or analysis.get('analysis', '') or analysis_text[:200]
    
    if 'BUY' in rec or 'YES' in rec or rec == 'LONG':
        should_trade = True
        trade_side = 'BUY'
    elif 'SELL' in rec or 'NO' in rec or rec == 'SHORT':
        should_trade = True
        trade_side = 'SELL'
    elif 'HOLD' in rec or 'SKIP' in rec or 'AVOID' in rec or 'PASS' in rec:
        should_trade = False
    else:
        # No clear recommendation — skip
        should_trade = False
    
    # Only trade with sufficient confidence
    if confidence > 0 and confidence < 0.55:
        should_trade = False
        analysis_reason = f"Confidence too low ({confidence:.0%}): {analysis_reason}"
else:
    # Analysis failed (API error etc.) — trade anyway with base bet
    analysis_reason = f"Analysis unavailable: {analysis_text[:100]}"
    should_trade = True
    trade_side = 'BUY'
    confidence = 0  # will use base bet size

# Dynamic bet sizing: scale within configured range based on confidence
bet_base = float(prod_config.get('bet_base', 2.00))
bet_range = float(prod_config.get('bet_range', 1.00))
# confidence 0.55=min, 1.0=max → linear scale within range
conf_norm = max(0.0, min(1.0, (confidence - 0.55) / 0.45)) if confidence >= 0.55 else 0.5
bet_size = round(max(1.0, bet_base - bet_range + conf_norm * 2 * bet_range), 2)
print(f"Analysis: trade={should_trade} side={trade_side} confidence={confidence:.0%} bet=${bet_size:.2f} reason={analysis_reason[:60]}")

if not should_trade:
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
        "result": "NO_TRADE",
        "reason": f"AI skip: {analysis_reason[:120]}",
        "action": "Skipped by AI analysis"
    }
    write_log(entry)
    print(json.dumps(entry))
    sys.exit(0)

# Enforce minimum share size (Polymarket requires >= 5 shares per order)
MIN_SHARES = 5
trade_price = best_ask if trade_side == 'BUY' else best_bid
projected_shares = bet_size / trade_price if trade_price > 0 else 0
if projected_shares < MIN_SHARES:
    min_usd_needed = MIN_SHARES * trade_price
    if min_usd_needed <= max_bet:
        print(f"Adjusting bet_size from ${bet_size:.2f} to ${min_usd_needed:.2f} to meet minimum {MIN_SHARES} shares (price={trade_price:.3f})")
        bet_size = round(min_usd_needed, 2)
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
            "min_usd_needed": round(min_usd_needed, 2),
            "result": "NO_TRADE",
            "reason": f"Minimum shares ({MIN_SHARES}) requires ${min_usd_needed:.2f} which exceeds max_bet (${max_bet})",
            "action": "Skipped — min order size too large"
        }
        write_log(entry)
        print(json.dumps(entry))
        sys.exit(0)

# Try to read confidence from research.json (pre-trade research)
research_confidence = None
research_summary = None
try:
    import json as _json2
    with open(f'{TRADING_DIR}/research.json') as _rf:
        _research = _json2.load(_rf)
    _r_entry = _research.get(CONDITION_ID)
    if _r_entry:
        research_confidence = _r_entry.get('confidence_pct')
        research_summary = _r_entry.get('sources_summary')
except:
    pass

# Place market order (AMM)
result = mcporter('create_market_order',
    market_id=CONDITION_ID,
    side=trade_side,
    size=float(bet_size)
)

if result.get('success') or result.get('order_id'):
    trade = {
        'bot_id': 'prod',
        'timestamp': now.isoformat(),
        'question': QUESTION,
        'condition_id': CONDITION_ID,
        # Entry data
        'entry_price': best_ask,
        'spread_at_entry': round(spread, 4),
        'mid_at_entry': round(mid, 4),
        'hours_before_close': round(hours_left, 2),
        'size_usd': bet_size,
        'shares': round(bet_size / best_ask, 2),
        'max_payout': round(bet_size / best_ask, 2),  # shares * $1.00
        'max_return_pct': round((1.0 - best_ask) / best_ask * 100, 1),  # % gain if won
        'end_datetime': END_DATETIME,
        'order_id': result.get('order_id'),
        # Research data
        'confidence_pct': research_confidence,
        'research_summary': research_summary,
        # Outcome (filled later)
        'status': 'open',
        'outcome': None,
        'pnl': None,
        'pnl_pct': None,
        'resolved_at': None,
        'redeem_amount': None
    }
    prod_journal.setdefault('trades', []).append(trade)
    with open(f'{TRADING_DIR}/journal.json', 'w') as f:
        json.dump(prod_journal, f, indent=2)

    # (legacy log-based confidence fallback — kept for compatibility)
    if research_confidence is None:
        try:
            with open(LOG_FILE) as _lf:
                _all_logs = _json2.load(_lf)
            for _entry in reversed(_all_logs):
                if _entry.get('condition_id') == CONDITION_ID and _entry.get('result') == 'RESEARCH':
                    research_confidence = _entry.get('confidence_pct')
                    research_summary = _entry.get('sources_summary')
                    break
        except:
            pass

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
        "confidence_pct": research_confidence,
        "research_summary": research_summary,
        "result": "TRADED",
        "reason": "All conditions met — order placed",
        "action": f"BUY {round(bet_size/best_ask,2)} shares @ {best_ask:.2f} = ${bet_size:.2f}"
    }
    write_log(entry)
    print(json.dumps(entry))
    print(f"TRADED: {QUESTION[:50]} @ {best_ask:.2f} ${bet_size:.2f} ({round(bet_size/best_ask,2)} shares)")
    send_telegram(f"✅ TRADED: {QUESTION[:50]}\n{trade_side} ${bet_size:.2f} @ {best_ask:.2f}¢")
else:
    err_msg = str(result.get('error', result))
    # CLOB spread safety check failure = illiquid orderbook → treat as NO_TRADE, not ERROR
    if 'Safety check failed: Market spread' in err_msg and 'exceeds maximum' in err_msg:
        # Extract CLOB spread from error message for logging
        import re as _re
        clob_spread_match = _re.search(r'Market spread ([\d.]+)%', err_msg)
        clob_spread_pct = clob_spread_match.group(1) if clob_spread_match else 'unknown'
        entry = {
            "timestamp": now.isoformat(),
            "question": QUESTION,
            "condition_id": CONDITION_ID,
            "end_datetime": END_DATETIME,
            "hours_left": round(hours_left, 2),
            "best_bid": best_bid,
            "best_ask": best_ask,
            "amm_spread": round(spread, 4),
            "clob_spread_pct": clob_spread_pct,
            "mid": round(mid, 4),
            "portfolio_value": total_balance,
            "bet_size_usd": bet_size,
            "result": "NO_TRADE",
            "reason": f"CLOB orderbook illiquid (spread {clob_spread_pct}%) — AMM price {mid:.3f} but no liquid CLOB orders",
            "action": "Skipped — CLOB spread too wide for limit order"
        }
        write_log(entry)
        print(json.dumps(entry))
        print(f"NO_TRADE: {QUESTION[:50]} — CLOB illiquid ({clob_spread_pct}% spread)")
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
        send_telegram(f"❌ ORDER FAILED: {QUESTION[:50]}\n{str(result)[:200]}")
        queue_error(f"Order failed: {str(result)}", f"market_id={CONDITION_ID} side={trade_side} size={bet_size}")

PYEOF
