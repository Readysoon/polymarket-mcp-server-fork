#!/bin/bash
# run.sh — All-in-one: Redeem + Scan + Research + Trade + Report
# Runs every 2h via cron

TRADING_DIR="/home/node/.openclaw/workspace/trading"
WORKSPACE="/home/node/.openclaw/workspace"

echo "=== RUN START $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# STEP 1: Redeem winning positions
echo "--- STEP 1: Redeem ---"
bash "$TRADING_DIR/redeem.sh" 2>&1

# STEP 2: Run scanner to find candidates
echo "--- STEP 2: Scanner ---"
bash "$TRADING_DIR/scanner.sh" 2>&1

echo "=== RUN DONE ==="
