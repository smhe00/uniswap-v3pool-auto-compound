#!/bin/bash
set -o pipefail

# ==========================================
# 1. 163 SMTP configuration
# ==========================================
export SMTP_SERVER="smtps://smtp.163.com:465"
export SENDER_EMAIL="xxxx@163.com"
export SENDER_PASS="you app password"
export RECEIVER_EMAIL="xxxx@proton.me"

if [ -z "$1" ]; then
    echo "用法: $0 <要执行的脚本路径>"
    echo "示例: $0 ./run_compound.sh"
    exit 1
fi

TARGET_SCRIPT="$1"
NOW=$(date +"%Y-%m-%d %H:%M:%S")

# Monitoring is read-only. These values are used only by email_monitor.sh
# and are NOT exported to the trading script.
MONITOR_RPC_URL="${AUTOCOMPOUND_MONITOR_RPC_URL:-https://arb1.arbitrum.io/rpc}"
MONITOR_CHAIN_ID="${AUTOCOMPOUND_CHAIN_ID:-42161}"

TARGET_DIR=$(cd "$(dirname "$TARGET_SCRIPT")" 2>/dev/null && pwd)
if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR="."
fi
MONITOR_WORK_DIR="${AUTOCOMPOUND_WORK_DIR:-$TARGET_DIR}"
BROADCAST_JSON="${AUTOCOMPOUND_BROADCAST_JSON:-$MONITOR_WORK_DIR/broadcast/Compound.s.sol/$MONITOR_CHAIN_ID/run-latest.json}"

file_fingerprint() {
    local file="$1"
    if [ ! -f "$file" ]; then
        printf 'MISSING'
        return
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        cksum "$file" | awk '{print $1 ":" $2}'
    fi
}

html_escape() {
    printf '%s' "$1" | sed         -e 's/&/\&amp;/g'         -e 's/</\&lt;/g'         -e 's/>/\&gt;/g'         -e 's/"/\&quot;/g'
}

value_or_na() {
    if [ -n "$1" ]; then
        html_escape "$1"
    else
        printf 'N/A'
    fi
}

extract_value() {
    local label="$1"
    printf '%s\n' "$OUTPUT" |
        grep -F "$label" |
        tail -1 |
        cut -d':' -f2- |
        sed 's/^[[:space:]]*//'
}

send_email() {
    local subject="$1"
    local body="$2"

    echo "正在通过网易 163 专用通道发送战报..."

    curl -s --url "$SMTP_SERVER" \
        --user "$SENDER_EMAIL:$SENDER_PASS" \
        --mail-from "$SENDER_EMAIL" \
        --mail-rcpt "$RECEIVER_EMAIL" \
        -T - <<EOF
From: "🤖 AutoCompound Bot" <$SENDER_EMAIL>
To: <$RECEIVER_EMAIL>
Subject: $subject
Content-Type: text/html; charset="utf-8"

$body
EOF

    if [ $? -eq 0 ]; then
        echo "✅ 战报已成功发送至: $RECEIVER_EMAIL"
    else
        echo "⚠️ 邮件发送失败，请检查网络或授权码！"
    fi
}

# ==========================================
# 2. Snapshot broadcast artifact BEFORE run
# ==========================================
# We intentionally do NOT delete or modify run-latest.json here.
# The fingerprint lets the monitor distinguish this run from an old artifact.
BROADCAST_BEFORE=$(file_fingerprint "$BROADCAST_JSON")

# ==========================================
# 3. Execute original trading pipeline unchanged
# ==========================================
echo "📡 163 监控雷达已启动，正在接管执行: $TARGET_SCRIPT ..."

OUTPUT=$("$TARGET_SCRIPT" 2>&1)
EXIT_CODE=$?

echo "$OUTPUT"

BROADCAST_AFTER=$(file_fingerprint "$BROADCAST_JSON")
BROADCAST_CHANGED=0
if [ "$BROADCAST_AFTER" != "MISSING" ] && [ "$BROADCAST_AFTER" != "$BROADCAST_BEFORE" ]; then
    BROADCAST_CHANGED=1
fi

# ==========================================
# 4. Parse existing telemetry (read-only)
# ==========================================
TOKEN_NFT=$(extract_value "Token NFT ID    :")
BASE_TOKEN=$(extract_value "Base Token Set  :")
BASE_FEE=$(extract_value "BaseFee (Gwei)  :")
CURRENT_PRICE=$(extract_value "Current Price   :")
POSITION_RANGE=$(extract_value "Position Range  :")
POSITION_STATUS=$(extract_value "Status          :")
PRINCIPAL_VALUE=$(extract_value " Total Value  :")
PENDING_FEE=$(extract_value "Pending Fee    :")
WALLET_BALANCE=$(extract_value "Wallet Balance :")
TOTAL_CAPITAL=$(extract_value "Total Capital  :")
OPTIMAL_R=$(extract_value "Optimal R* :")
DECISION=$(extract_value "[DECISION] Status:")
INVESTED_AMT=$(extract_value "Invested Value :")
LIQUIDITY_ADDED=$(extract_value "Liquidity (L)  :")
NEW_TOTAL=$(extract_value "New Total Value:")
TRUE_EXCESS=$(extract_value "True Excess Cap. :")
ZAP_GAIN_COST=$(extract_value "Zap Gain vs Cost :")
FUEL_STATUS=$(printf '%s\n' "$OUTPUT" | grep -F "[Fuel Check]" | tail -1 | sed 's/^[[:space:]]*//')

# ==========================================
# 5. Independent on-chain verification
# ==========================================
TX_COUNT=""
INCREASE_TX=""
PARSE_OK=0
RECEIPT_STATUS=""
RECEIPT_BLOCK=""
RECEIPT_GAS=""
VERIFY_REASON=""

if [ "$BROADCAST_CHANGED" -eq 1 ]; then
    if command -v python3 >/dev/null 2>&1; then
        PARSED=$(python3 - "$BROADCAST_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

transactions = data.get("transactions") or []
increase_hash = ""

for tx in reversed(transactions):
    function = str(tx.get("function") or "")
    if "increaseLiquidity" not in function:
        continue

    increase_hash = str(
        tx.get("hash")
        or tx.get("transactionHash")
        or tx.get("txHash")
        or ""
    )
    if increase_hash:
        break

print("TX_COUNT=" + str(len(transactions)))
print("INCREASE_TX=" + increase_hash)
PY
        )
        if [ $? -eq 0 ]; then
            PARSE_OK=1
            TX_COUNT=$(printf '%s\n' "$PARSED" | grep '^TX_COUNT=' | tail -1 | cut -d= -f2-)
            INCREASE_TX=$(printf '%s\n' "$PARSED" | grep '^INCREASE_TX=' | tail -1 | cut -d= -f2-)
        else
            VERIFY_REASON="broadcast_json_parse_failed"
        fi
    else
        VERIFY_REASON="python3_missing"
    fi
else
    VERIFY_REASON="no_new_broadcast_artifact"
fi

if [ -n "$INCREASE_TX" ]; then
    if command -v cast >/dev/null 2>&1; then
        RECEIPT_STATUS=$(cast receipt --rpc-url "$MONITOR_RPC_URL" "$INCREASE_TX" status 2>/dev/null)
        RECEIPT_STATUS=$(printf '%s' "$RECEIPT_STATUS" | tr -d '[:space:]')

        if [ -n "$RECEIPT_STATUS" ]; then
            RECEIPT_BLOCK=$(cast receipt --rpc-url "$MONITOR_RPC_URL" "$INCREASE_TX" blockNumber 2>/dev/null | tr -d '[:space:]')
            RECEIPT_GAS=$(cast receipt --rpc-url "$MONITOR_RPC_URL" "$INCREASE_TX" gasUsed 2>/dev/null | tr -d '[:space:]')
        else
            VERIFY_REASON="receipt_unavailable"
        fi
    else
        VERIFY_REASON="cast_missing"
    fi
fi

# ==========================================
# 6. Determine monitoring result
# ==========================================
RESULT="NOOP"
REASON="no_execution_required"

if echo "$OUTPUT" | grep -q "OUT-OF-RANGE"; then
    RESULT="BLOCKED"
    REASON="position_out_of_range"
elif echo "$OUTPUT" | grep -q "CRITICAL: LOW GAS"; then
    RESULT="BLOCKED"
    REASON="low_gas"
elif [ "$EXIT_CODE" -ne 0 ] || echo "$OUTPUT" | grep -q -i "Simulation failed\|Revert\|Error"; then
    RESULT="FAILED"
    REASON="pipeline_or_rpc_error"
elif echo "$OUTPUT" | grep -q "\[zZZ\] Going back to sleep"; then
    RESULT="NOOP"
    REASON="below_threshold"
elif echo "$OUTPUT" | grep -q "Firing up the execution pipeline"; then
    if [ "$BROADCAST_CHANGED" -ne 1 ]; then
        RESULT="UNCERTAIN"
        REASON="no_new_broadcast_artifact"
    elif [ "$PARSE_OK" -ne 1 ]; then
        RESULT="UNCERTAIN"
        REASON="${VERIFY_REASON:-broadcast_parse_unavailable}"
    elif [ -z "$INCREASE_TX" ]; then
        if [ "${TX_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            RESULT="INCOMPLETE"
            REASON="write_transactions_without_increase_liquidity"
        else
            RESULT="INCOMPLETE"
            REASON="execution_started_without_increase_liquidity"
        fi
    else
        case "$RECEIPT_STATUS" in
            1|0x1|0x01|0x001)
                RESULT="SUCCESS"
                REASON="increase_liquidity_receipt_confirmed"
                ;;
            0|0x0|0x00|0x000)
                RESULT="FAILED"
                REASON="increase_liquidity_receipt_failed"
                ;;
            *)
                RESULT="UNCERTAIN"
                REASON="${VERIFY_REASON:-receipt_status_unknown}"
                ;;
        esac
    fi
fi

# ==========================================
# 7. Build rich status snapshot
# ==========================================
MARKET_HTML="<h4>Market / Position</h4>
<table border='0' cellpadding='4'>
<tr><td><b>NFT</b></td><td>$(value_or_na "$TOKEN_NFT")</td></tr>
<tr><td><b>Base Token</b></td><td>$(value_or_na "$BASE_TOKEN")</td></tr>
<tr><td><b>Current Price</b></td><td>$(value_or_na "$CURRENT_PRICE")</td></tr>
<tr><td><b>LP Range</b></td><td>$(value_or_na "$POSITION_RANGE")</td></tr>
<tr><td><b>Position Status</b></td><td>$(value_or_na "$POSITION_STATUS")</td></tr>
<tr><td><b>Base Fee</b></td><td>$(value_or_na "$BASE_FEE")</td></tr>
</table>"

ACCOUNT_HTML="<h4>Capital / Account</h4>
<table border='0' cellpadding='4'>
<tr><td><b>Principal</b></td><td>$(value_or_na "$PRINCIPAL_VALUE")</td></tr>
<tr><td><b>Pending Fee</b></td><td>$(value_or_na "$PENDING_FEE")</td></tr>
<tr><td><b>Wallet Balance</b></td><td>$(value_or_na "$WALLET_BALANCE")</td></tr>
<tr><td><b>Total Capital</b></td><td>$(value_or_na "$TOTAL_CAPITAL")</td></tr>
<tr><td><b>Optimal R*</b></td><td>$(value_or_na "$OPTIMAL_R")</td></tr>
<tr><td><b>Decision</b></td><td>$(value_or_na "$DECISION")</td></tr>
</table>"

EXEC_HTML="<h4>This Cycle</h4>
<table border='0' cellpadding='4'>
<tr><td><b>Invested</b></td><td>$(value_or_na "$INVESTED_AMT")</td></tr>
<tr><td><b>Liquidity Added</b></td><td>$(value_or_na "$LIQUIDITY_ADDED")</td></tr>
<tr><td><b>New Total</b></td><td>$(value_or_na "$NEW_TOTAL")</td></tr>
<tr><td><b>True Excess Capital</b></td><td>$(value_or_na "$TRUE_EXCESS")</td></tr>
<tr><td><b>Zap Gain vs Cost</b></td><td>$(value_or_na "$ZAP_GAIN_COST")</td></tr>
<tr><td><b>Fuel</b></td><td>$(value_or_na "$FUEL_STATUS")</td></tr>
</table>"

CHAIN_HTML="<h4>On-chain Verification</h4>
<table border='0' cellpadding='4'>
<tr><td><b>Monitor Result</b></td><td>$(value_or_na "$RESULT")</td></tr>
<tr><td><b>Reason</b></td><td>$(value_or_na "$REASON")</td></tr>
<tr><td><b>Broadcast Tx Count</b></td><td>$(value_or_na "$TX_COUNT")</td></tr>
<tr><td><b>increaseLiquidity Tx</b></td><td>$(value_or_na "$INCREASE_TX")</td></tr>
<tr><td><b>Receipt Status</b></td><td>$(value_or_na "$RECEIPT_STATUS")</td></tr>
<tr><td><b>Block</b></td><td>$(value_or_na "$RECEIPT_BLOCK")</td></tr>
<tr><td><b>Gas Used</b></td><td>$(value_or_na "$RECEIPT_GAS")</td></tr>
</table>"

if [ -n "$INCREASE_TX" ]; then
    CHAIN_HTML="$CHAIN_HTML<p><a href='https://arbiscan.io/tx/$(html_escape "$INCREASE_TX")'>View transaction on Arbiscan</a></p>"
fi

FULL_STATUS="$MARKET_HTML$ACCOUNT_HTML$EXEC_HTML$CHAIN_HTML"

# ==========================================
# 8. Notification policy
# ==========================================
case "$RESULT" in
    SUCCESS)
        SUBJECT="✅ 复投成功：${INVESTED_AMT:-已确认 increaseLiquidity}"
        BODY="<h3>✅ AutoCompound VERIFIED SUCCESS</h3>
        <p><b>时间:</b> $NOW</p>
        <p>只有本轮新的 <code>increaseLiquidity</code> 交易且链上 receipt 明确成功，才会发送成功邮件。</p>
        $FULL_STATUS"
        send_email "$SUBJECT" "$BODY"
        exit 0
        ;;

    BLOCKED)
        SUBJECT="🚨 AutoCompound 被安全条件阻断"
        BODY="<h3>🚨 AutoCompound BLOCKED</h3>
        <p><b>时间:</b> $NOW</p>
        <p>本周期未计为复投成功。</p>
        $FULL_STATUS"
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;

    INCOMPLETE)
        SUBJECT="🚨 AutoCompound 未完成：资金可能停留在钱包"
        BODY="<h3>🚨 AutoCompound INCOMPLETE</h3>
        <p><b>时间:</b> $NOW</p>
        <p>检测到执行阶段/链上写入，但没有确认成功的 <code>increaseLiquidity</code>。本周期禁止计为复投成功。</p>
        $FULL_STATUS"
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;

    FAILED)
        SUBJECT="❌ AutoCompound 执行失败"
        BODY="<h3>❌ AutoCompound FAILED</h3>
        <p><b>时间:</b> $NOW</p>
        <p><b>原脚本退出码:</b> $EXIT_CODE</p>
        <p>本周期未计为复投成功。</p>
        $FULL_STATUS"
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;

    UNCERTAIN)
        SUBJECT="⚠️ AutoCompound 状态不确定：未计为成功"
        BODY="<h3>⚠️ AutoCompound UNCERTAIN</h3>
        <p><b>时间:</b> $NOW</p>
        <p>监控层无法取得足够的本轮链上证据，因此采用 fail-closed：不报告复投成功。</p>
        $FULL_STATUS"
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;

    NOOP)
        echo "ℹ️ 本周期无需复投 ($REASON)，不发送成功邮件。"
        exit 0
        ;;
esac

exit 1
