#!/bin/bash
# Auto-redeemer — checks for winning positions and redeems them on-chain
# Supports both normal CTF markets and NegRisk markets (via WCOL unwrap)

python3 << 'PYEOF'
import httpx, os, json, time
from eth_account import Account
from web3 import Web3

PRIVATE_KEY = os.environ.get('POLYGON_PRIVATE_KEY', '')
ADDRESS = os.environ.get('POLYGON_ADDRESS', '')
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
            # Normal market: redeem with native USDC
            bal_before = usdc_contract.functions.balanceOf(account.address).call()
            tx = ctf.functions.redeemPositions(
                w3.to_checksum_address(USDC), b'\x00'*32,
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
                bal_after = usdc_contract.functions.balanceOf(account.address).call()
                received = (bal_after - bal_before) / 1e6
                if received > 0:
                    print(f"REDEEMED: {title} | +${received:.2f} USDC | tx={tx_hash.hex()[:16]}...")
                    redeemed.append({'title': title, 'value': received, 'tx': tx_hash.hex()})
                else:
                    print(f"REDEEM_ZERO: {title} | tx confirmed but $0 received (market not resolved yet)")
        else:
            print(f"REDEEM_UNCONFIRMED: {title} | tx={tx_hash.hex()[:16]}...")
    except Exception as e:
        print(f"REDEEM_ERROR: {title} | {e}")

if redeemed:
    total = sum(r['value'] for r in redeemed)
    print(f"REDEEM_DONE: {len(redeemed)} positions redeemed, ~${total:.2f} USDC freed")
    # Notify
    for r in redeemed:
        print(f"NOTIFY: Redeemed '{r['title']}' — ${r['value']:.2f} USDC back in wallet")

PYEOF
