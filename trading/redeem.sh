#!/bin/bash
# Auto-redeemer — checks for winning positions and redeems them on-chain

python3 << 'PYEOF'
import httpx, os, json
from eth_account import Account
from web3 import Web3

PRIVATE_KEY = os.environ.get('POLYGON_PRIVATE_KEY', '')
ADDRESS = os.environ.get('POLYGON_ADDRESS', '')
USDC = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
CTF  = "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045"
RPC  = "https://polygon-bor-rpc.publicnode.com"  # reliable, no rate limit

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
        bal_before = usdc_contract.functions.balanceOf(account.address).call()
        nonce = w3.eth.get_transaction_count(account.address)
        # Use 1.5x current gas price to avoid "replacement transaction underpriced"
        gas_price = int(w3.eth.gas_price * 1.5)
        tx = ctf.functions.redeemPositions(
            w3.to_checksum_address(USDC),
            b'\x00' * 32,
            bytes.fromhex(condition_id[2:]),
            [index_set]
        ).build_transaction({
            'from': account.address,
            'nonce': nonce,
            'gas': 200000,
            'gasPrice': gas_price,
            'chainId': 137
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        import time as _time
        confirmed = False
        for _ in range(12):
            _time.sleep(5)
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
