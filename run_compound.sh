#!/bin/bash
set -o pipefail

# ========================================================
# Universal Auto-Compound Bot Execution Pipeline
# ========================================================

# 0. Dynamic environment for cron
export PATH="$PATH:$HOME/.foundry/bin"

# 1. Working directory
WORK_DIR="/home/xxxxxxx/uniswap-bot"
cd "$WORK_DIR" || exit 1

# 2. Strategy configuration
export TOKEN_ID=1234567
export BASE_TOKEN_INDEX=1
export TARGET_MIN_BASE_AMOUNT_X10000=0
export ALLOW_AUTO_ZAP="true"

RPC_URL="${RPC_URL:-https://arb1.arbitrum.io/rpc}"
CHAIN_ID="${CHAIN_ID:-42161}"

# 3. Logging / Foundry broadcast artifact
LOG_FILE="${WORK_DIR}/compound_bot_${TOKEN_ID}.log"
BROADCAST_JSON="${WORK_DIR}/broadcast/Compound.s.sol/${CHAIN_ID}/run-latest.json"
DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')
RUN_CAPTURE=$(mktemp)
trap 'rm -f "$RUN_CAPTURE"' EXIT

echo "====================================================" | tee -a "$LOG_FILE"
echo "🚀 Pipeline Triggered at: $DATE_STR" | tee -a "$LOG_FILE"
echo "🔧 NFT ID: $TOKEN_ID | Base Index: $BASE_TOKEN_INDEX | Target(x10000): $TARGET_MIN_BASE_AMOUNT_X10000" | tee -a "$LOG_FILE"

# Critical: remove run-latest.json before this run so a previous successful
# compound can never be mistaken for the current run.
rm -f "$BROADCAST_JSON"

# 4. Execute Foundry script
forge script "$WORK_DIR/script/Compound.s.sol:AutoCompound" \
    --rpc-url "$RPC_URL" \
    --account bot_account \
    --password-file .pass \
    --broadcast \
    --via-ir 2>&1 | tee -a "$LOG_FILE" | tee "$RUN_CAPTURE"

EXIT_CODE=${PIPESTATUS[0]}

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "❌ Pipeline Failed with Exit Code: $EXIT_CODE" | tee -a "$LOG_FILE"
    echo "AUTOCOMPOUND_RESULT=FAILED"
    echo "AUTOCOMPOUND_REASON=forge_exit_$EXIT_CODE"
    echo "====================================================" | tee -a "$LOG_FILE"
    exit "$EXIT_CODE"
fi

echo "✅ Forge pipeline exited with code 0; verifying business transaction on-chain..." | tee -a "$LOG_FILE"

# 5. Forge/broadcast success is NOT enough to claim compound success.
# Require an increaseLiquidity tx from THIS run and independently verify
# its on-chain receipt through the configured RPC.
if ! command -v python3 >/dev/null 2>&1; then
    echo "AUTOCOMPOUND_RESULT=UNCERTAIN"
    echo "AUTOCOMPOUND_REASON=python3_missing_for_broadcast_verification"
    echo "====================================================" | tee -a "$LOG_FILE"
    exit 3
fi

if [ ! -s "$BROADCAST_JSON" ]; then
    if grep -q "OUT-OF-RANGE" "$RUN_CAPTURE"; then
        echo "AUTOCOMPOUND_RESULT=BLOCKED"
        echo "AUTOCOMPOUND_REASON=position_out_of_range"
        echo "====================================================" | tee -a "$LOG_FILE"
        exit 2
    fi

    if grep -q "CRITICAL: LOW GAS" "$RUN_CAPTURE"; then
        echo "AUTOCOMPOUND_RESULT=BLOCKED"
        echo "AUTOCOMPOUND_REASON=low_gas"
        echo "====================================================" | tee -a "$LOG_FILE"
        exit 2
    fi

    if grep -q "\[zZZ\] Going back to sleep" "$RUN_CAPTURE"; then
        echo "AUTOCOMPOUND_RESULT=NOOP"
        echo "AUTOCOMPOUND_REASON=below_threshold"
        echo "====================================================" | tee -a "$LOG_FILE"
        exit 0
    fi

    if grep -q "Firing up the execution pipeline" "$RUN_CAPTURE"; then
        echo "AUTOCOMPOUND_RESULT=UNCERTAIN"
        echo "AUTOCOMPOUND_REASON=broadcast_artifact_missing_after_execution_started"
        echo "====================================================" | tee -a "$LOG_FILE"
        exit 3
    fi

    echo "AUTOCOMPOUND_RESULT=NOOP"
    echo "AUTOCOMPOUND_REASON=no_broadcast_transactions"
    echo "====================================================" | tee -a "$LOG_FILE"
    exit 0
fi

PARSE_OUTPUT=$(python3 - "$BROADCAST_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

transactions = data.get("transactions") or []
increase_hash = ""

for tx in reversed(transactions):
    function = str(tx.get("function") or "")
    if "increaseLiquidity" in function:
        increase_hash = str(tx.get("hash") or tx.get("transactionHash") or "")
        if increase_hash:
            break

print(len(transactions))
print(increase_hash)
PY
)
PARSE_CODE=$?

if [ "$PARSE_CODE" -ne 0 ]; then
    echo "AUTOCOMPOUND_RESULT=UNCERTAIN"
    echo "AUTOCOMPOUND_REASON=broadcast_json_parse_failed"
    echo "====================================================" | tee -a "$LOG_FILE"
    exit 3
fi

TX_COUNT=$(printf '%s\n' "$PARSE_OUTPUT" | sed -n '1p')
INCREASE_TX=$(printf '%s\n' "$PARSE_OUTPUT" | sed -n '2p')

if [ -z "$INCREASE_TX" ]; then
    if [ "${TX_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        # Some writes may already have happened (collect/refuel/zap), but
        # the actual reinvest transaction is absent. Never report success.
        echo "AUTOCOMPOUND_RESULT=INCOMPLETE"
        echo "AUTOCOMPOUND_REASON=write_transactions_without_increase_liquidity"
        echo "AUTOCOMPOUND_BROADCAST_TX_COUNT=${TX_COUNT:-unknown}"
        echo "====================================================" | tee -a "$LOG_FILE"
        exit 2
    fi

    echo "AUTOCOMPOUND_RESULT=NOOP"
    echo "AUTOCOMPOUND_REASON=no_increase_liquidity_transaction"
    echo "====================================================" | tee -a "$LOG_FILE"
    exit 0
fi

if ! command -v cast >/dev/null 2>&1; then
    echo "AUTOCOMPOUND_RESULT=UNCERTAIN"
    echo "AUTOCOMPOUND_REASON=cast_missing_for_receipt_verification"
    echo "AUTOCOMPOUND_TX_HASH=$INCREASE_TX"
    echo "====================================================" | tee -a "$LOG_FILE"
    exit 3
fi

RECEIPT_STATUS=$(cast receipt --rpc-url "$RPC_URL" "$INCREASE_TX" status 2>/dev/null)
RECEIPT_CODE=$?
RECEIPT_STATUS=$(printf '%s' "$RECEIPT_STATUS" | tr -d '[:space:]')

if [ "$RECEIPT_CODE" -ne 0 ] || [ -z "$RECEIPT_STATUS" ]; then
    echo "AUTOCOMPOUND_RESULT=UNCERTAIN"
    echo "AUTOCOMPOUND_REASON=receipt_unavailable"
    echo "AUTOCOMPOUND_TX_HASH=$INCREASE_TX"
    echo "====================================================" | tee -a "$LOG_FILE"
    exit 3
fi

case "$RECEIPT_STATUS" in
    1|0x1|0x01|0x001)
        echo "✅ increaseLiquidity receipt confirmed on-chain: $INCREASE_TX" | tee -a "$LOG_FILE"
        echo "AUTOCOMPOUND_RESULT=SUCCESS"
        echo "AUTOCOMPOUND_TX_HASH=$INCREASE_TX"
        echo "AUTOCOMPOUND_RECEIPT_STATUS=1"
        echo "====================================================" | tee -a "$LOG_FILE"
        exit 0
        ;;
    *)
        echo "❌ increaseLiquidity transaction did not succeed on-chain: status=$RECEIPT_STATUS" | tee -a "$LOG_FILE"
        echo "AUTOCOMPOUND_RESULT=FAILED"
        echo "AUTOCOMPOUND_REASON=increase_liquidity_receipt_failed"
        echo "AUTOCOMPOUND_TX_HASH=$INCREASE_TX"
        echo "AUTOCOMPOUND_RECEIPT_STATUS=$RECEIPT_STATUS"
        echo "====================================================" | tee -a "$LOG_FILE"
        exit 2
        ;;
esac
