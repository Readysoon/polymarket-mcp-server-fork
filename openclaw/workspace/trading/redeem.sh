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
RPC  = "https://1rpc.io/matic"

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
for p in redeemable:
    condition_id = p['conditionId']
    outcome_index = p.get('outcomeIndex', 0)
    index_set = 1 << outcome_index  # bit position for the winning outcome
    title = p.get('title', 'Unknown')[:50]
    value = p.get('currentValue', 0)

    try:
        nonce = w3.eth.get_transaction_count(account.address)
        tx = ctf.functions.redeemPositions(
            w3.to_checksum_address(USDC),
            b'\x00' * 32,
            bytes.fromhex(condition_id[2:]),
            [index_set]
        ).build_transaction({
            'from': account.address,
            'nonce': nonce,
            'gas': 200000,
            'gasPrice': w3.eth.gas_price,
            'chainId': 137
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        print(f"REDEEMED: {title} | ${value:.2f} | tx={tx_hash.hex()[:16]}...")
        redeemed.append({'title': title, 'value': value, 'tx': tx_hash.hex()})
    except Exception as e:
        print(f"REDEEM_ERROR: {title} | {e}")

if redeemed:
    total = sum(r['value'] for r in redeemed)
    print(f"REDEEM_DONE: {len(redeemed)} positions redeemed, ~${total:.2f} USDC freed")
    # Notify
    for r in redeemed:
        print(f"NOTIFY: Redeemed '{r['title']}' — ${r['value']:.2f} USDC back in wallet")

PYEOF
