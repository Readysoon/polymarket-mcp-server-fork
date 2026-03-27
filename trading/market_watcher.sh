#!/bin/bash
# market_watcher.sh — single market, single run
# Args: <condition_id> <yes_token_id> <end_datetime> <question> [allocated_usd] [side: YES|NO] [no_token_id]

CONDITION_ID="${1}"
YES_TOKEN="${2}"
END_DATETIME="${3}"
QUESTION="${4}"
ALLOCATED_USD="${5:-}"
TRADE_SIDE="${6:-YES}"      # YES (default) or NO
NO_TOKEN="${7:-}"

WORKSPACE="/home/node/.openclaw/workspace"
TRADING_DIR="$WORKSPACE/trading"

export MW_CONDITION_ID="$CONDITION_ID"
export MW_YES_TOKEN="$YES_TOKEN"
export MW_END_DATETIME="$END_DATETIME"
export MW_QUESTION="$QUESTION"
export MW_WORKSPACE="$WORKSPACE"
export MW_TRADING_DIR="$TRADING_DIR"
export MW_ALLOCATED_USD="$ALLOCATED_USD"
export MW_TRADE_SIDE="$TRADE_SIDE"
export MW_NO_TOKEN="$NO_TOKEN"

python3 << 'PYEOF'
import json, subprocess, sys, os, httpx
from datetime import datetime, timezone, timedelta

CONDITION_ID  = os.environ['MW_CONDITION_ID']
YES_TOKEN     = os.environ['MW_YES_TOKEN']
END_DATETIME  = os.environ['MW_END_DATETIME']
QUESTION      = os.environ['MW_QUESTION']
WORKSPACE     = os.environ['MW_WORKSPACE']
TRADING_DIR   = os.environ['MW_TRADING_DIR']
ALLOCATED_USD = float(os.environ.get('MW_ALLOCATED_USD', '0') or '0')
TRADE_SIDE    = os.environ.get('MW_TRADE_SIDE', 'YES').upper()  # YES or NO
NO_TOKEN      = os.environ.get('MW_NO_TOKEN', '')

# Select the correct token based on side
ACTIVE_TOKEN  = NO_TOKEN if TRADE_SIDE == 'NO' and NO_TOKEN else YES_TOKEN

now = datetime.now(timezone.utc)


# ── Helpers ──────────────────────────────────────────────────────────────────

def send_telegram(msg):
    try:
        subprocess.run([
            'curl', '-s', '-X', 'POST',
            'https://api.telegram.org/bot8599638540:AAFVTzaLBWQmStBfdd3xSlPEJJQuMH4cEBI/sendMessage',
            '-d', f'chat_id=866661912&text={msg[:1000]}'
        ], capture_output=True, timeout=10)
    except:
        pass

def queue_error(error_msg, context=""):
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
    except:
        pass

def mcporter(tool, **kwargs):
    args = ['mcporter', 'call', f'polymarket.{tool}', '--args', json.dumps(kwargs)]
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(r.stdout)
    except:
        return {'error': r.stdout.strip() + r.stderr.strip()}

def schedule_retry(minutes, label="retry"):
    fire_at = (now + timedelta(minutes=minutes)).strftime('%Y-%m-%dT%H:%M:%SZ')
    job = {
        "name": f"watch:{CONDITION_ID[:16]}",
        "schedule": {"kind": "at", "at": fire_at},
        "payload": {
            "kind": "agentTurn",
            "message": (
                f"Run market watcher for: {QUESTION[:60]}\n\n"
                f"bash /home/node/.openclaw/workspace/trading/market_watcher.sh "
                f"'{CONDITION_ID}' '{YES_TOKEN}' '{END_DATETIME}' '{QUESTION[:60]}'\n\n"
                "After running, always notify Philipp on Telegram with the result: "
                "TRADED (what was bought + price), NO_TRADE (reason), or error. "
                "If there is a technical error: debug it, fix the code, git push, then notify Philipp."
            ),
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
    print(f"Rescheduled {label} in {minutes}min at {fire_at}")


# ── Load config ───────────────────────────────────────────────────────────────

with open(f'{TRADING_DIR}/config.json') as f:
    config = json.load(f)

MIN_P             = float(config.get('min_yes_price', 0.50))
MAX_P             = float(config.get('max_yes_price', 0.80))
MAX_SPREAD        = float(config.get('max_spread', 0.05))
MIN_HOURS         = float(config.get('min_hours_before_close', 3.0))
MAX_SPREAD_TRADE  = float(config.get('max_spread', 0.10))
MAX_BET           = float(config.get('max_bet_usd', 25))
BET_BASE          = float(config.get('bet_base', 2.00))
BET_RANGE         = float(config.get('bet_range', 1.00))


# ── Parse end time ────────────────────────────────────────────────────────────

try:
    end_dt = datetime.fromisoformat(END_DATETIME.replace('Z', '+00:00'))
except Exception:
    print(f"ERROR: bad end_datetime {END_DATETIME}")
    sys.exit(1)

hours_left = (end_dt - now).total_seconds() / 3600

if hours_left < 0.1:
    print(f"EXPIRED: {QUESTION[:50]}")
    sys.exit(0)


# ── AMM price check ───────────────────────────────────────────────────────────

price_data = mcporter('get_current_price', token_id=ACTIVE_TOKEN, side='BOTH')
print(f"Trading side: {TRADE_SIDE} | token: {ACTIVE_TOKEN[:20]}...")

if 'error' in price_data or price_data.get('bid') is None or price_data.get('ask') is None:
    error_detail = price_data.get('error', 'no price available')
    if hours_left > 1:
        schedule_retry(30, "no-price")
        print(json.dumps({"result": "NOT_READY", "reason": f"No AMM price: {error_detail}", "action": "Retry in 30min"}))
    else:
        print(json.dumps({"result": "TIMEOUT", "reason": f"No AMM price and <1h left: {error_detail}", "action": "Abandoned"}))
        send_telegram(f"⏰ TIMEOUT: {QUESTION[:50]}\nMarket closed before tradeable — abandoned.")
    sys.exit(0)

best_bid = float(price_data['bid'])
best_ask = float(price_data['ask'])
if best_bid > best_ask:
    best_bid, best_ask = best_ask, best_bid
spread = best_ask - best_bid
mid    = (best_bid + best_ask) / 2


# ── Pre-trade filters ─────────────────────────────────────────────────────────

if hours_left < MIN_HOURS:
    print(json.dumps({"result": "NO_TRADE", "reason": f"Only {hours_left:.1f}h left (min {MIN_HOURS}h)", "action": "Skipped"}))
    sys.exit(0)

if spread > MAX_SPREAD:
    if hours_left > 0.5:
        schedule_retry(15, "wide-spread")
        print(json.dumps({"result": "NOT_READY", "reason": f"Spread {spread:.4f} > max {MAX_SPREAD}", "action": "Retry in 15min"}))
    else:
        print(json.dumps({"result": "TIMEOUT", "reason": "Spread too wide until close", "action": "Abandoned"}))
        send_telegram(f"⏰ TIMEOUT: {QUESTION[:50]}\nSpread too wide until close — abandoned.")
    sys.exit(0)

if not (MIN_P <= mid <= MAX_P):
    print(json.dumps({"result": "NO_TRADE", "reason": f"Mid {mid:.3f} outside range {MIN_P}-{MAX_P}", "action": "Skipped"}))
    sys.exit(0)


# ── Auto-redeem winning positions ─────────────────────────────────────────────

try:
    from eth_account import Account as _Account
    from web3 import Web3 as _Web3

    _PRIV = os.environ.get('POLYGON_PRIVATE_KEY', '')
    _ADDR = os.environ.get('POLYGON_ADDRESS', '')
    _USDC = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
    _CTF  = "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045"
    _RPC  = "https://polygon-bor-rpc.publicnode.com"
    _CTF_ABI = [{"name": "redeemPositions", "type": "function", "inputs": [
        {"name": "collateralToken", "type": "address"},
        {"name": "parentCollectionId", "type": "bytes32"},
        {"name": "conditionId", "type": "bytes32"},
        {"name": "indexSets", "type": "uint256[]"}
    ], "outputs": []}]

    _r = httpx.get(f"https://data-api.polymarket.com/positions?user={_ADDR}&sizeThreshold=0.01", timeout=15)
    _positions = _r.json() if _r.status_code == 200 else []
    _redeemable = [p for p in _positions if p.get('redeemable')]

    if _redeemable and _PRIV:
        _w3 = _Web3(_Web3.HTTPProvider(_RPC))
        _ctf = _w3.eth.contract(address=_w3.to_checksum_address(_CTF), abi=_CTF_ABI)
        _acct = _Account.from_key(_PRIV)
        for _p in _redeemable:
            try:
                _index_set = 1 << _p.get('outcomeIndex', 0)
                _tx = _ctf.functions.redeemPositions(
                    _w3.to_checksum_address(_USDC), b'\x00' * 32,
                    bytes.fromhex(_p['conditionId'][2:]), [_index_set]
                ).build_transaction({
                    'from': _acct.address,
                    'nonce': _w3.eth.get_transaction_count(_acct.address),
                    'gas': 200000,
                    'gasPrice': _w3.eth.gas_price,
                    'chainId': 137
                })
                _signed = _acct.sign_transaction(_tx)
                _w3.eth.send_raw_transaction(_signed.raw_transaction)
                print(f"REDEEMED: {_p.get('title', '?')[:40]} ${_p.get('currentValue', 0):.2f}")
            except Exception as _e:
                print(f"REDEEM_ERROR: {_e}")
        import time as _t; _t.sleep(8)  # wait for tx to settle
except Exception as _redeem_err:
    print(f"REDEEM_ATTEMPT_ERROR: {_redeem_err}")


# ── Get USDC balance (native + bridged) ───────────────────────────────────────

_address = os.environ.get('POLYGON_ADDRESS', '').lower()
_selector = '0x70a08231' + _address[2:].zfill(64)
_rpcs   = ['https://polygon-bor-rpc.publicnode.com', 'https://polygon.llamarpc.com']
_tokens = ['0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359', '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174']
total_balance = 0.0
for _token in _tokens:
    for _rpc in _rpcs:
        try:
            _resp = httpx.post(_rpc, json={
                'jsonrpc': '2.0', 'method': 'eth_call',
                'params': [{'to': _token, 'data': _selector}, 'latest'], 'id': 1
            }, timeout=5.0)
            _val = _resp.json().get('result', '0x0')
            if _val and _val != '0x':
                total_balance += int(_val, 16) / 1e6
                break
        except:
            continue
print(f"Balance: ${total_balance:.2f} USDC")


# ── Auto-approve USDC.e to NegRisk CTF Exchange ───────────────────────────────

try:
    from eth_account import Account as _EthAcct2
    _PRIV2  = os.environ.get('POLYGON_PRIVATE_KEY', '')
    _ADDR2  = os.environ.get('POLYGON_ADDRESS', '')
    _USDC_E  = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
    _NEGRISK = "0xC5d563A36AE78145C45a50134d48A1215220f80a"
    _RPC2    = 'https://polygon-bor-rpc.publicnode.com'
    _MIN_ALLOWANCE = 50.0

    _al_sel = '0xdd62ed3e' + _ADDR2.lower()[2:].zfill(64) + _NEGRISK.lower()[2:].zfill(64)
    _ar = httpx.post(_RPC2, json={'jsonrpc': '2.0', 'method': 'eth_call',
        'params': [{'to': _USDC_E, 'data': _al_sel}, 'latest'], 'id': 1}, timeout=5.0)
    _al_raw = _ar.json().get('result', '0x0')
    _al_val = int(_al_raw, 16) / 1e6 if _al_raw not in ('0x', '0x0', None) else 0.0

    if _al_val < _MIN_ALLOWANCE and _PRIV2:
        print(f"AUTO-APPROVE: USDC.e allowance ${_al_val:.4f} < ${_MIN_ALLOWANCE} — approving MAX...")
        _a_data = bytes.fromhex('095ea7b3') + bytes.fromhex(_NEGRISK[2:].zfill(64)) + (2**256 - 1).to_bytes(32, 'big')
        _ng = httpx.post(_RPC2, json={'jsonrpc': '2.0', 'method': 'eth_getTransactionCount',
            'params': [_ADDR2, 'latest'], 'id': 2}, timeout=5.0)
        _nonce = int(_ng.json()['result'], 16)
        _gp = httpx.post(_RPC2, json={'jsonrpc': '2.0', 'method': 'eth_gasPrice',
            'params': [], 'id': 3}, timeout=5.0)
        _gas_price = int(_gp.json()['result'], 16)
        _atx = {
            'to': _USDC_E, 'from': _ADDR2, 'nonce': _nonce, 'gas': 100000,
            'gasPrice': _gas_price, 'data': '0x' + _a_data.hex(), 'chainId': 137, 'value': 0
        }
        _acct3 = _EthAcct2.from_key(_PRIV2)
        _signed3 = _acct3.sign_transaction(_atx)
        _sr = httpx.post(_RPC2, json={'jsonrpc': '2.0', 'method': 'eth_sendRawTransaction',
            'params': ['0x' + _signed3.raw_transaction.hex()], 'id': 4}, timeout=10.0)
        print(f"AUTO-APPROVE TX: {_sr.json().get('result', '')}")
        import time as _t2; _t2.sleep(12)
    else:
        print(f"Allowance OK: USDC.e NegRisk allowance ${_al_val:.2f}")
except Exception as _ae:
    print(f"AUTO-APPROVE ERROR (non-fatal): {_ae}")


# ── DUPLICATE CHECK ───────────────────────────────────────────────────────────

try:
    with open(f"{TRADING_DIR}/journal.json") as _jf:
        _jdata = json.load(_jf)
    _existing = [t for t in _jdata.get('trades', [])
                 if t.get('condition_id') == CONDITION_ID
                 and t.get('status') in ('open', 'OPEN')]
    if _existing:
        print(f"DUPLICATE SKIP: {QUESTION[:50]} already open (condition_id={CONDITION_ID[:20]})")
        sys.exit(0)
except Exception as _de:
    print(f"Duplicate check error (non-fatal): {_de}")

if total_balance < 1.0:
    print(json.dumps({
        "result": "NO_TRADE",
        "reason": f"Balance ${total_balance:.2f} < $1.00 minimum",
        "action": "Deposit more USDC"
    }))
    sys.exit(0)


# ── AI analysis ───────────────────────────────────────────────────────────────

print(f"Analyzing: {QUESTION[:60]}")
analysis = mcporter('analyze_market_opportunity', market_id=CONDITION_ID)

should_trade    = False
trade_side      = 'BUY'
analysis_reason = "No analysis available"
confidence      = 0.0

if isinstance(analysis, dict) and 'error' not in analysis:
    rec        = str(analysis.get('recommendation', '') or analysis.get('action', '') or '').upper()
    confidence = float(analysis.get('confidence', 0) or analysis.get('confidence_score', 0) or 0)
    analysis_reason = analysis.get('reasoning', '') or analysis.get('analysis', '') or str(analysis)[:200]

    if 'BUY' in rec or 'YES' in rec or rec == 'LONG':
        should_trade = True
        trade_side   = 'BUY'
    elif 'SELL' in rec or 'NO' in rec or rec == 'SHORT':
        should_trade = True
        trade_side   = 'SELL'
    else:
        should_trade = False  # HOLD / SKIP / AVOID / unclear

    if 0 < confidence < 0.55:
        should_trade    = False
        analysis_reason = f"Confidence too low ({confidence:.0%}): {analysis_reason}"
else:
    # Analysis API unavailable — trade with base size
    analysis_reason = f"Analysis unavailable: {str(analysis)[:100]}"
    should_trade    = True
    trade_side      = 'BUY'

# ── Bet sizing ────────────────────────────────────────────────────────────────
# Use Runner-allocated amount if provided; otherwise dynamic sizing from confidence.
if ALLOCATED_USD >= 2.50:
    bet_size = round(float(ALLOCATED_USD), 2)
    print(f"Bet size (Runner allocation): ${bet_size:.2f}")
else:
    conf_norm = max(0.0, min(1.0, (confidence - 0.55) / 0.45)) if confidence >= 0.55 else 0.5
    bet_size  = round(max(1.0, BET_BASE - BET_RANGE + conf_norm * 2 * BET_RANGE), 2)
    print(f"Bet size (dynamic): ${bet_size:.2f}")

print(f"Analysis: trade={should_trade} side={trade_side} confidence={confidence:.0%} bet=${bet_size:.2f}")

if not should_trade:
    print(json.dumps({
        "result": "NO_TRADE",
        "reason": f"AI skip: {analysis_reason[:120]}",
        "action": "Skipped by AI analysis"
    }))
    sys.exit(0)


# ── Minimum share enforcement ─────────────────────────────────────────────────

MIN_SHARES = 5
trade_price      = best_ask if trade_side == 'BUY' else best_bid
projected_shares = bet_size / trade_price if trade_price > 0 else 0

if projected_shares < MIN_SHARES:
    min_usd_needed = MIN_SHARES * trade_price
    if min_usd_needed <= MAX_BET:
        print(f"Adjusting bet_size ${bet_size:.2f} → ${min_usd_needed:.2f} to meet {MIN_SHARES}-share minimum")
        bet_size = round(min_usd_needed, 2)
    else:
        print(json.dumps({
            "result": "NO_TRADE",
            "reason": f"Min {MIN_SHARES} shares requires ${min_usd_needed:.2f} > max_bet ${MAX_BET}",
            "action": "Skipped — min order too large"
        }))
        sys.exit(0)


# ── Share-rounding (maker/taker must have ≤ 2 decimal places) ─────────────────
# Polymarket requires both share quantity (maker) and cost (shares×price, taker)
# to have at most 2 decimal places. We search quarter-share increments (0.25 step)
# which always give 2-decimal quantities, then check that shares×price also rounds cleanly.

_raw_shares  = float(bet_size) / best_ask
_best_shares = None

# Search quarter-share increments: maker (shares) always has ≤ 2 decimals.
# Pick closest valid combo where taker (shares×price) also rounds cleanly to 2 dp.
for _q in range(max(1, int(_raw_shares * 4) - 8), int(_raw_shares * 4) + 9):
    _try_shares = round(_q / 4, 2)   # 0.25 step → always ≤ 2 decimal places
    _try_cost   = _try_shares * best_ask
    if abs(_try_cost - round(_try_cost, 2)) < 1e-9:   # taker rounds cleanly
        if _best_shares is None or abs(_try_shares - _raw_shares) < abs(_best_shares - _raw_shares):
            _best_shares = _try_shares

if _best_shares is None:
    _best_shares = round(_raw_shares / 0.25) * 0.25   # last-resort

bet_size = round(_best_shares * best_ask, 2)
print(f"Rounded to ${bet_size:.2f} ({_best_shares:.2f} shares @ {best_ask:.4f})")


# ── Load research (for confidence/summary in journal) ─────────────────────────

research_confidence = None
research_summary    = None
try:
    with open(f'{TRADING_DIR}/research.json') as _rf:
        _research = json.load(_rf)
    _r_entry = _research.get(CONDITION_ID)
    if _r_entry:
        research_confidence = _r_entry.get('confidence_pct')
        research_summary    = _r_entry.get('sources_summary')
except:
    pass


# ── Place FOK order ───────────────────────────────────────────────────────────
# For NO side: buy the NO token directly (it's always a BUY order on the token)
if TRADE_SIDE == 'NO' and NO_TOKEN:
    # For NO token: use post_order directly (same as SELL orders use)
    import asyncio, sys as _sys
    _sys.path.insert(0, WORKSPACE + '/src')
    async def _place_no_order():
        from polymarket_mcp.auth.client import PolymarketClient
        _client = PolymarketClient(
            private_key=os.environ['POLYGON_PRIVATE_KEY'],
            address=os.environ['POLYGON_ADDRESS'],
            api_key=os.environ['POLYMARKET_API_KEY'],
            api_secret=os.environ['POLYMARKET_API_SECRET'],
            passphrase=os.environ['POLYMARKET_PASSPHRASE'],
            chain_id=137
        )
        _client._initialize_client()
        return await _client.post_order(
            token_id=ACTIVE_TOKEN,
            price=round(best_ask, 4),
            size=round(float(_best_shares), 2),
            side='BUY',
            order_type='FOK'
        )
    _no_result = asyncio.run(_place_no_order())
    result = {'success': _no_result.get('success', False), 'order_id': _no_result.get('orderID'), **_no_result}
else:
    # Use post_order directly with pre-rounded shares (avoids mcporter internal rounding issues)
    import asyncio, sys as _sys
    _sys.path.insert(0, WORKSPACE + '/src')
    async def _place_yes_order():
        from polymarket_mcp.auth.client import PolymarketClient
        _client = PolymarketClient(
            private_key=os.environ['POLYGON_PRIVATE_KEY'],
            address=os.environ['POLYGON_ADDRESS'],
            api_key=os.environ['POLYMARKET_API_KEY'],
            api_secret=os.environ['POLYMARKET_API_SECRET'],
            passphrase=os.environ['POLYMARKET_PASSPHRASE'],
            chain_id=137
        )
        _client._initialize_client()
        return await _client.post_order(
            token_id=YES_TOKEN,
            price=round(best_ask, 4),
            size=round(float(_best_shares), 2),
            side='BUY',
            order_type='FOK'
        )
    _yes_result = asyncio.run(_place_yes_order())
    result = {'success': _yes_result.get('success', False), 'order_id': _yes_result.get('orderID'), **_yes_result}

if not (result.get('success') or result.get('order_id')):
    err_msg = str(result.get('error', result))

    # CLOB spread safety check = illiquid orderbook → NO_TRADE (not ERROR)
    if 'Safety check failed: Market spread' in err_msg and 'exceeds maximum' in err_msg:
        import re as _re
        _m = _re.search(r'Market spread ([\d.]+)%', err_msg)
        clob_spread_pct = _m.group(1) if _m else 'unknown'
        print(json.dumps({
            "result": "NO_TRADE",
            "reason": f"CLOB illiquid ({clob_spread_pct}% spread) — AMM {mid:.3f} but no liquid CLOB orders",
            "action": "Skipped — CLOB spread too wide"
        }))
        print(f"NO_TRADE: {QUESTION[:50]} — CLOB illiquid ({clob_spread_pct}% spread)")
    else:
        print(json.dumps({"result": "ERROR", "reason": f"Order failed: {result}", "action": "Trade attempt failed"}))
        print(f"ALERT: Order failed for {QUESTION[:50]} — {result}")
        send_telegram(f"❌ ORDER FAILED: {QUESTION[:50]}\n{str(result)[:200]}")
        queue_error(f"Order failed: {str(result)}", f"market_id={CONDITION_ID} side={trade_side} size={bet_size}")
    sys.exit(0)


# ── ON-CHAIN CONFIRMATION ─────────────────────────────────────────────────────

import time as _time

_ADDR = os.environ.get('POLYGON_ADDRESS', '')
_onchain_confirmed = False
_onchain_tx        = None
_onchain_size      = None

print(f"Waiting for on-chain confirmation ({CONDITION_ID[:20]}...)...")

for _attempt in range(6):  # 6×5s = 30s (FOK fills instantly or rejects)
    _time.sleep(5)
    try:
        _act_r = httpx.get(
            f"https://data-api.polymarket.com/activity?user={_ADDR}&limit=20", timeout=10
        )
        for _act in _act_r.json():
            if (_act.get('conditionId') == CONDITION_ID
                    and _act.get('type') == 'TRADE'
                    and float(_act.get('usdcSize', 0)) > 0):
                _onchain_confirmed = True
                _onchain_tx   = _act.get('transactionHash')
                _onchain_size = float(_act.get('usdcSize', 0))
                print(f"ON-CHAIN CONFIRMED: tx={_onchain_tx[:20]}... size=${_onchain_size:.2f}")
                break
    except Exception as _ce:
        print(f"On-chain check {_attempt+1} error: {_ce}")
    if _onchain_confirmed:
        break
    print(f"On-chain check {_attempt+1}/6 — not yet...")

# ── RETRY in 1¢ steps with Kelly recalculation ────────────────────────────────

if not _onchain_confirmed:
    _retry_price = round(best_ask + 0.01, 3)

    while not _onchain_confirmed:
        # Recalculate Kelly bet at new price
        _p = confidence
        _b = (1 - _retry_price) / _retry_price
        _kp = max(0, (_p * _b - (1 - _p)) / _b)
        _new_bet = round(max(2.50, _kp * 0.5 * total_balance), 2)

        # EV check: must still have minimum edge
        _ev_ok = confidence >= _retry_price + 0.08
        print(f"Retry at {_retry_price:.3f}: Kelly ${_new_bet:.2f} | EV={'✅' if _ev_ok else '❌ STOP'}")

        if not _ev_ok:
            queue_error(f"Unmatched — EV exhausted at {_retry_price}",
                        f"condition_id={CONDITION_ID} last_price={_retry_price}")
            sys.exit(1)

        # Place retry order
        bet_size = _new_bet
        _raw_shares2 = float(bet_size) / _retry_price
        _best_shares2 = None
        for _q2 in range(max(1, int(_raw_shares2 * 4) - 8), int(_raw_shares2 * 4) + 9):
            _ts2 = round(_q2 / 4, 2)
            _tc2 = _ts2 * _retry_price
            if abs(_tc2 - round(_tc2, 2)) < 1e-9:
                if _best_shares2 is None or abs(_ts2 - _raw_shares2) < abs(_best_shares2 - _raw_shares2):
                    _best_shares2 = _ts2
        if _best_shares2 is None:
            _best_shares2 = round(_raw_shares2 / 0.25) * 0.25
        bet_size = round(_best_shares2 * _retry_price, 2)

        # Place order
        async def _retry_order():
            from polymarket_mcp.auth.client import PolymarketClient
            _c = PolymarketClient(
                private_key=os.environ['POLYGON_PRIVATE_KEY'],
                address=os.environ['POLYGON_ADDRESS'],
                api_key=os.environ['POLYMARKET_API_KEY'],
                api_secret=os.environ['POLYMARKET_API_SECRET'],
                passphrase=os.environ['POLYMARKET_PASSPHRASE'],
                chain_id=137
            )
            _c._initialize_client()
            return await _c.post_order(
                token_id=ACTIVE_TOKEN,
                price=round(_retry_price, 4),
                size=round(float(_best_shares2), 2),
                side='BUY',
                order_type='FOK'
            )
        _r2 = asyncio.run(_retry_order())
        best_ask = _retry_price

        # Check on-chain
        for _a2 in range(6):
            _time.sleep(5)
            try:
                _ar2 = httpx.get(f"https://data-api.polymarket.com/activity?user={_ADDR}&limit=20", timeout=10)
                for _act2 in _ar2.json():
                    if (_act2.get('conditionId') == CONDITION_ID
                            and _act2.get('type') == 'TRADE'
                            and float(_act2.get('usdcSize', 0)) > 0):
                        _onchain_confirmed = True
                        _onchain_tx = _act2.get('transactionHash')
                        _onchain_size = float(_act2.get('usdcSize', 0))
                        print(f"RETRY CONFIRMED at {_retry_price}: tx={_onchain_tx[:20]}... ${_onchain_size:.2f}")
                        break
            except: pass
            if _onchain_confirmed:
                break

        if not _onchain_confirmed:
            _retry_price = round(_retry_price + 0.01, 3)  # try next cent


# ── Write journal entry ───────────────────────────────────────────────────────

try:
    with open(f'{TRADING_DIR}/journal.json') as f:
        journal = json.load(f)
except:
    journal = {'trades': []}

trade = {
    'bot_id': 'prod',
    'timestamp': now.isoformat(),
    'question': QUESTION,
    'condition_id': CONDITION_ID,
    'entry_price': best_ask,
    'spread_at_entry': round(spread, 4),
    'mid_at_entry': round(mid, 4),
    'hours_before_close': round(hours_left, 2),
    'size_usd': _onchain_size or bet_size,
    'shares': round((_onchain_size or bet_size) / best_ask, 2),
    'max_payout': round(bet_size / best_ask, 2),
    'max_return_pct': round((1.0 - best_ask) / best_ask * 100, 1),
    'end_datetime': END_DATETIME,
    'order_id': result.get('order_id'),
    'confidence_pct': research_confidence,
    'research_summary': research_summary,
    'status': 'open',
    'outcome': None,
    'pnl': None,
    'pnl_pct': None,
    'resolved_at': None,
    'redeem_amount': None
}
journal.setdefault('trades', []).append(trade)
with open(f'{TRADING_DIR}/journal.json', 'w') as f:
    json.dump(journal, f, indent=2)

print(f"TRADED: {QUESTION[:50]} @ {best_ask:.2f} ${bet_size:.2f} ({_best_shares:.2f} shares)")
send_telegram(f"✅ TRADED: {QUESTION[:50]}\n{trade_side} ${bet_size:.2f} @ {best_ask:.2f}¢")

PYEOF
