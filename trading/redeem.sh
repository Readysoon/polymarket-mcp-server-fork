#!/bin/bash
# redeem.sh — redeem winning Polymarket positions on-chain
# Supports normal CTF markets and NegRisk markets (via WCOL unwrap)

python3 << 'PYEOF'
import httpx, os, json, time
from eth_account import Account
from web3 import Web3

PRIVATE_KEY = os.environ.get('POLYGON_PRIVATE_KEY', '')
ADDRESS = os.environ.get('POLYGON_ADDRESS', '')

# Paper trading check
import json as _json
TRADING_DIR = '/home/node/.openclaw/workspace/trading'
try:
    _cfg = _json.load(open(f'{TRADING_DIR}/config.json'))
    PAPER_TRADING = _cfg.get('paper_trading', False)
except:
    PAPER_TRADING = False

if PAPER_TRADING:
    # Paper mode: simulate redemption from journal
    from datetime import datetime, timezone as _tz
    now_p = datetime.now(_tz.utc)
    journal = _json.load(open(f'{TRADING_DIR}/journal.json'))
    pb_path = f'{TRADING_DIR}/paper_bankroll.json'
    pb = _json.load(open(pb_path)) if __import__('os').path.exists(pb_path) else {'current_balance': 149.18, 'paper_pnl': 0.0, 'history': []}
    redeemed_paper = []
    for t in journal.get('trades', []):
        if not t.get('paper'): continue
        if t.get('status') not in ('open', 'OPEN'): continue
        end = t.get('end_datetime', '')
        if end and datetime.fromisoformat(end.replace('Z','+00:00')) > now_p: continue
        # Mark as needing resolution - check actual outcome via API
        cid = t.get('condition_id', '')
        try:
            # Use CLOB API — tokens[].winner field is authoritative
            r = __import__('httpx').get(f'https://clob.polymarket.com/markets/{cid}', timeout=5)
            mkt = r.json()
            tokens = mkt.get('tokens', [])
            resolved = mkt.get('closed', False) and any(t2.get('winner') is not None for t2 in tokens)
            winning_outcome = None
            if resolved:
                for tok in tokens:
                    if tok.get('winner') is True:
                        outcome_label = tok.get('outcome', '').lower()
                        # Map outcome label to YES/NO logic
                        # For moneyline: outcome = team name, trade_side = YES (bought winning team)
                        # We store trade_side = YES always for the team we expect to win
                        # So we need to check if the winning token matches our trade_side
                        winning_outcome = outcome_label
                        break
        except:
            resolved = False
            winning_outcome = None

        if resolved and winning_outcome:
            side = t.get('trade_side', 'YES')
            question = t.get('question', '')[:50]
            size = t.get('size_usd', 0)
            price = t.get('entry_price', 0.5)
            shares = size / price
            # Classic YES/NO markets
            classic_win = (side == 'YES' and winning_outcome in ('yes', '1', 'true')) or \
                          (side == 'NO' and winning_outcome in ('no', '0', 'false'))
            # Moneyline markets: outcome = team name, YES token = first team in question
            # We bought YES = we expect the "Pistons" token (first team) to win
            # Check the token price directly: winner token has price=1
            tokens_data = mkt.get('tokens', [])
            yes_token_winner = False
            no_token_winner = False
            if tokens_data:
                yes_token_winner = tokens_data[0].get('winner', False) is True
                no_token_winner = tokens_data[1].get('winner', False) is True if len(tokens_data) > 1 else False
            moneyline_win = (side == 'YES' and yes_token_winner) or (side == 'NO' and no_token_winner)
            if classic_win or moneyline_win:
                pnl = round(shares - size, 2)
                t['status'] = 'WON'
                t['pnl'] = pnl
                t['outcome'] = 'won'
                t['resolved_at'] = now_p.isoformat()
                pb['current_balance'] = round(pb.get('current_balance', 0) + shares, 2)
                pb['paper_pnl'] = round(pb.get('paper_pnl', 0) + pnl, 2)
                pb.setdefault('history', []).append({'t': now_p.isoformat(), 'balance': pb['current_balance'], 'event': 'paper_redeem', 'question': question, 'pnl': pnl})
                redeemed_paper.append(f'{question} +${pnl:.2f}')
                print(f'PAPER REDEEMED WON: {question} | +${pnl:.2f}')
            else:
                t['status'] = 'LOST'
                t['pnl'] = -size
                t['outcome'] = 'lost'
                t['resolved_at'] = now_p.isoformat()
                print(f'PAPER RESOLVED LOST: {question} | -${size:.2f}')

    _json.dump(journal, open(f'{TRADING_DIR}/journal.json', 'w'), indent=2)
    pb['updated_at'] = now_p.isoformat()
    _json.dump(pb, open(pb_path, 'w'), indent=2)
    if redeemed_paper:
        print(f'PAPER REDEEM_DONE: {len(redeemed_paper)} positions resolved')
    else:
        print('PAPER REDEEM: nothing resolved yet')
    exit(0)

USDC   = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"   # native USDC
USDC_E = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"   # bridged USDC.e
CTF    = "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045"
WCOL   = "0x3A3BD7bb9528E159577F7C2e685CC81A765002E2"   # WrappedCollateral
RPC    = "https://polygon-bor-rpc.publicnode.com"

if not PRIVATE_KEY:
    print("ERROR: No POLYGON_PRIVATE_KEY set")
    exit(1)

# Fetch redeemable positions
r = httpx.get(
    f"https://data-api.polymarket.com/positions?user={ADDRESS}&sizeThreshold=0.01",
    timeout=15
)
positions = r.json() if r.status_code == 200 else []
redeemable = [p for p in positions if p.get('redeemable')]

if not redeemable:
    print("REDEEM: nothing to redeem")
    exit(0)

print(f"REDEEM: {len(redeemable)} redeemable position(s) found")

CTF_ABI = [{"name":"redeemPositions","type":"function","inputs":[
    {"name":"collateralToken","type":"address"},
    {"name":"parentCollectionId","type":"bytes32"},
    {"name":"conditionId","type":"bytes32"},
    {"name":"indexSets","type":"uint256[]"}
],"outputs":[]}]

w3 = Web3(Web3.HTTPProvider(RPC))
ctf = w3.eth.contract(address=w3.to_checksum_address(CTF), abi=CTF_ABI)
account = Account.from_key(PRIVATE_KEY)
import time

# Get base nonce once, increment manually to avoid conflicts
base_nonce = w3.eth.get_transaction_count(account.address, 'pending')
nonce_counter = [base_nonce]  # mutable via list

redeemed = []
usdc_abi = [{"name":"balanceOf","type":"function","inputs":[{"name":"account","type":"address"}],"outputs":[{"type":"uint256"}],"stateMutability":"view"}]
usdc_contract = w3.eth.contract(address=w3.to_checksum_address(USDC), abi=usdc_abi)

for p in redeemable:
    condition_id = p['conditionId']
    outcome_index = p.get('outcomeIndex', 0)
    title = p.get('title', 'Unknown')[:50]
    value = p.get('currentValue', 0)

    # Skip invalid outcome index (e.g. neg risk markets not yet resolvable)
    if outcome_index >= 256:
        print(f"SKIP (invalid outcomeIndex {outcome_index}): {title}")
        continue

    # Skip if value is 0 (already lost/worthless)
    if float(value) <= 0:
        print(f"SKIP (value $0): {title}")
        continue

    index_set = 1 << outcome_index

    try:
        is_neg_risk = p.get('negativeRisk', False)
        gas_price = int(w3.eth.gas_price * 1.5)
        nonce = nonce_counter[0]
        nonce_counter[0] += 1

        # NegRisk markets: redeem via WCOL, then unwrap to USDC.e
        wcol_abi = [{'name':'balanceOf','type':'function','inputs':[{'name':'a','type':'address'}],'outputs':[{'type':'uint256'}],'stateMutability':'view'},
                    {'name':'unwrap','type':'function','inputs':[{'name':'_receiver','type':'address'},{'name':'_amount','type':'uint256'}],'outputs':[]}]
        wcol_contract = w3.eth.contract(address=w3.to_checksum_address(WCOL), abi=wcol_abi)
        usdce_contract = w3.eth.contract(address=w3.to_checksum_address(USDC_E), abi=[{'name':'balanceOf','type':'function','inputs':[{'name':'a','type':'address'}],'outputs':[{'type':'uint256'}],'stateMutability':'view'}])

        if is_neg_risk:
            # Step 1: redeemPositions with WCOL as collateral
            wcol_before = wcol_contract.functions.balanceOf(account.address).call()
            tx = ctf.functions.redeemPositions(
                w3.to_checksum_address(WCOL), b'\x00'*32,
                bytes.fromhex(condition_id[2:]), [index_set]
            ).build_transaction({'from': account.address, 'nonce': nonce, 'gas': 200000, 'gasPrice': gas_price, 'chainId': 137})
        else:
            # Normal market: redeem with USDC.e (Polymarket uses USDC.e as collateral)
            bal_before = usdce_contract.functions.balanceOf(account.address).call()
            tx = ctf.functions.redeemPositions(
                w3.to_checksum_address(USDC_E), b'\x00'*32,
                bytes.fromhex(condition_id[2:]), [index_set]
            ).build_transaction({'from': account.address, 'nonce': nonce, 'gas': 200000, 'gasPrice': gas_price, 'chainId': 137})

        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        confirmed = False
        for _ in range(12):
            time.sleep(5)
            try:
                receipt = w3.eth.get_transaction_receipt(tx_hash)
                if receipt and receipt.status == 1:
                    confirmed = True
                    break
                elif receipt and receipt.status == 0:
                    print(f"REDEEM_REVERTED: {title}")
                    break
            except: pass

        if confirmed:
            if is_neg_risk:
                # Step 2: unwrap WCOL → USDC.e
                wcol_after = wcol_contract.functions.balanceOf(account.address).call()
                wcol_gained = wcol_after - wcol_before
                if wcol_gained > 0:
                    usdce_before = usdce_contract.functions.balanceOf(account.address).call()
                    nonce2 = nonce_counter[0]; nonce_counter[0] += 1
                    tx2 = wcol_contract.functions.unwrap(account.address, wcol_gained).build_transaction(
                        {'from': account.address, 'nonce': nonce2, 'gas': 150000, 'gasPrice': gas_price, 'chainId': 137})
                    signed2 = account.sign_transaction(tx2)
                    w3.eth.send_raw_transaction(signed2.raw_transaction)
                    time.sleep(15)
                    usdce_after = usdce_contract.functions.balanceOf(account.address).call()
                    received = (usdce_after - usdce_before) / 1e6
                    if received > 0:
                        print(f"REDEEMED: {title} | +${received:.2f} USDC.e | tx={tx_hash.hex()[:16]}...")
                        redeemed.append({'title': title, 'value': received, 'tx': tx_hash.hex()})
                    else:
                        print(f"REDEEM_ZERO: {title} | wcol gained but unwrap gave $0")
                else:
                    print(f"REDEEM_ZERO: {title} | no wcol gained")
            else:
                bal_after = usdce_contract.functions.balanceOf(account.address).call()
                received = (bal_after - bal_before) / 1e6
                if received > 0:
                    print(f"REDEEMED: {title} | +${received:.2f} USDC.e | tx={tx_hash.hex()[:16]}...")
                    redeemed.append({'title': title, 'value': received, 'tx': tx_hash.hex()})
                else:
                    print(f"REDEEM_ZERO: {title} | tx confirmed but $0 received (market not resolved yet)")
        else:
            print(f"REDEEM_UNCONFIRMED: {title} | tx={tx_hash.hex()[:16]}...")
    except Exception as e:
        print(f"REDEEM_ERROR: {title} | {e}")

if redeemed:
    total = sum(r['value'] for r in redeemed)
    print(f"REDEEM_DONE: {len(redeemed)} positions redeemed, ~${total:.2f} USDC.e freed")
    for r in redeemed:
        print(f"NOTIFY: Redeemed '{r['title']}' — ${r['value']:.2f} USDC.e back in wallet")

    # Update journal status for redeemed positions
    try:
        from datetime import datetime, timezone as _tz2
        import json as _j2
        _journal = _j2.load(open(f'{TRADING_DIR}/journal.json'))
        _redeemed_titles = {r['title'].lower() for r in redeemed}
        for _t in _journal.get('trades', []):
            _q = _t.get('question', '')[:50].lower()
            if _q in _redeemed_titles and _t.get('status') == 'open':
                _match = next((r for r in redeemed if r['title'].lower() == _q), None)
                if _match:
                    _t['status'] = 'WON'
                    _t['outcome'] = 'won'
                    _t['pnl'] = round(_match['value'] - _t.get('size_usd', 0), 2)
                    _t['resolved_at'] = datetime.now(_tz2.utc).isoformat()
                    _t['redeem_amount'] = _match['value']
        _j2.dump(_journal, open(f'{TRADING_DIR}/journal.json', 'w'), indent=2)
        print(f'Journal updated for {len(redeemed)} redeemed positions')
    except Exception as _je:
        print(f'Journal update error: {_je}')

# Auto-swap USDC (native) → USDC.e via Uniswap V3
# (py-clob-client needs USDC.e for trading; native USDC can't be used directly)
UNISWAP_ROUTER = "0xE592427A0AEce92De3Edee1F18E0157C05861564"
USDC_NATIVE = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"

try:
    usdc_native_abi = [
        {'name':'balanceOf','type':'function','inputs':[{'name':'a','type':'address'}],'outputs':[{'type':'uint256'}],'stateMutability':'view'},
        {'name':'approve','type':'function','inputs':[{'name':'spender','type':'address'},{'name':'amount','type':'uint256'}],'outputs':[{'type':'bool'}],'stateMutability':'nonpayable'},
        {'name':'allowance','type':'function','inputs':[{'name':'owner','type':'address'},{'name':'spender','type':'address'}],'outputs':[{'type':'uint256'}],'stateMutability':'view'},
    ]
    usdce_abi_full = [
        {'name':'balanceOf','type':'function','inputs':[{'name':'a','type':'address'}],'outputs':[{'type':'uint256'}],'stateMutability':'view'},
    ]
    usdc_native_c = w3.eth.contract(address=w3.to_checksum_address(USDC_NATIVE), abi=usdc_native_abi)
    # Keep $2 USDC native for gas costs; swap the rest to USDC.e
    usdc_native_bal = usdc_native_c.functions.balanceOf(account.address).call()
    GAS_RESERVE = 2_000_000  # keep $2 native USDC for gas
    usdce_bal = max(0, usdc_native_bal - GAS_RESERVE)

    if usdce_bal > 0:
        print(f"Auto-swapping ${usdce_bal/1e6:.2f} USDC → USDC.e...")

        # Approve router to spend USDC native
        gas_price = int(w3.eth.gas_price * 1.5)
        cur_allowance = usdc_native_c.functions.allowance(account.address, w3.to_checksum_address(UNISWAP_ROUTER)).call()
        if cur_allowance < usdce_bal:
            nonce = nonce_counter[0]; nonce_counter[0] += 1
            approve_tx = usdc_native_c.functions.approve(
                w3.to_checksum_address(UNISWAP_ROUTER), 2**256 - 1
            ).build_transaction({'from': account.address, 'nonce': nonce, 'gas': 100000, 'gasPrice': gas_price, 'chainId': 137})
            signed_approve = account.sign_transaction(approve_tx)
            w3.eth.send_raw_transaction(signed_approve.raw_transaction)
            time.sleep(8)

        # Swap USDC native → USDC.e via Uniswap V3 exactInputSingle
        ROUTER_ABI = [{'name':'exactInputSingle','type':'function','inputs':[{'name':'params','type':'tuple','components':[
            {'name':'tokenIn','type':'address'},{'name':'tokenOut','type':'address'},
            {'name':'fee','type':'uint24'},{'name':'recipient','type':'address'},
            {'name':'deadline','type':'uint256'},{'name':'amountIn','type':'uint256'},
            {'name':'amountOutMinimum','type':'uint256'},{'name':'sqrtPriceLimitX96','type':'uint160'}
        ]}],'outputs':[{'type':'uint256'}],'stateMutability':'payable'}]

        router = w3.eth.contract(address=w3.to_checksum_address(UNISWAP_ROUTER), abi=ROUTER_ABI)
        usdce_c2 = w3.eth.contract(address=w3.to_checksum_address(USDC_E), abi=[{'name':'balanceOf','type':'function','inputs':[{'name':'a','type':'address'}],'outputs':[{'type':'uint256'}],'stateMutability':'view'}])
        usdce_before = usdce_c2.functions.balanceOf(account.address).call()

        min_out = int(usdce_bal * 0.995)  # 0.5% slippage tolerance
        deadline = int(time.time()) + 300

        nonce = nonce_counter[0]; nonce_counter[0] += 1
        swap_tx = router.functions.exactInputSingle((
            w3.to_checksum_address(USDC_NATIVE),
            w3.to_checksum_address(USDC_E),
            100,  # 0.01% fee pool
            account.address,
            deadline,
            usdce_bal,
            min_out,
            0
        )).build_transaction({'from': account.address, 'nonce': nonce, 'gas': 300000, 'gasPrice': gas_price, 'chainId': 137, 'value': 0})
        signed_swap = account.sign_transaction(swap_tx)
        swap_hash = w3.eth.send_raw_transaction(signed_swap.raw_transaction)
        print(f"Swap TX: {swap_hash.hex()[:16]}...")
        time.sleep(15)
        receipt = w3.eth.get_transaction_receipt(swap_hash)
        usdce_after = usdce_c2.functions.balanceOf(account.address).call()
        swapped = (usdce_after - usdce_before) / 1e6
        if receipt and receipt.status == 1 and swapped > 0:
            print(f"SWAP_DONE: ${usdce_bal/1e6:.2f} USDC → ${swapped:.2f} USDC.e ✅")
        else:
            print(f"SWAP_FAILED or PENDING: status={receipt.status if receipt else 'pending'}")
    else:
        print("No USDC native to swap (or balance at $2 reserve).")
except Exception as e:
    print(f"SWAP_ERROR (non-fatal): {e}")

PYEOF
