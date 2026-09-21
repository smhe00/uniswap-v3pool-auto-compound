#!/bin/bash

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

# ==========================================
# 2. SMTP sender
# ==========================================
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
# 3. Run target and capture machine-readable result
# ==========================================
echo "📡 163 监控雷达已启动，正在接管执行: $TARGET_SCRIPT ..."

OUTPUT=$("$TARGET_SCRIPT" 2>&1)
EXIT_CODE=$?

echo "$OUTPUT"

RESULT=$(printf '%s\n' "$OUTPUT" | grep '^AUTOCOMPOUND_RESULT=' | tail -1 | cut -d= -f2-)
REASON=$(printf '%s\n' "$OUTPUT" | grep '^AUTOCOMPOUND_REASON=' | tail -1 | cut -d= -f2-)
TX_HASH=$(printf '%s\n' "$OUTPUT" | grep '^AUTOCOMPOUND_TX_HASH=' | tail -1 | cut -d= -f2-)
RECEIPT_STATUS=$(printf '%s\n' "$OUTPUT" | grep '^AUTOCOMPOUND_RECEIPT_STATUS=' | tail -1 | cut -d= -f2-)

# ==========================================
# 4. Notification policy
# IMPORTANT:
# Never infer compound success from Forge's
# "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" message.
# SUCCESS is accepted only from run_compound.sh after
# increaseLiquidity receipt verification.
# ==========================================

if echo "$OUTPUT" | grep -q "OUT-OF-RANGE"; then
    SUBJECT="🚨 严重警报：Uniswap 仓位脱轨！"
    BODY="<h3>🚨 AutoCompound 严重警报</h3>
    <p><b>时间:</b> $NOW</p>
    <p><b>状态:</b> 仓位已跌出设定区间 (OUT OF RANGE)。</p>
    <p><b>动作:</b> 本周期未计为复投成功，请检查仓位。</p>"
    send_email "$SUBJECT" "$BODY"
    exit 1
fi

case "$RESULT" in
    SUCCESS)
        INVESTED_AMT=$(printf '%s\n' "$OUTPUT" | grep "Invested Value :" | tail -1 | awk -F': ' '{print $2}' | tr -d ' ')
        NEW_TOTAL=$(printf '%s\n' "$OUTPUT" | grep "New Total Value:" | tail -1 | awk -F': ' '{print $2}' | tr -d ' ')

        [ -z "$INVESTED_AMT" ] && INVESTED_AMT="已确认 increaseLiquidity"
        [ -z "$NEW_TOTAL" ] && NEW_TOTAL="N/A"

        SUBJECT="✅ 复投成功：$INVESTED_AMT"
        BODY="<h3>✅ 自动复投已由链上 Receipt 确认</h3>
        <p><b>时间:</b> $NOW</p>
        <p><b>注入生息资金:</b> <code style='color:green; font-size:16px;'>$INVESTED_AMT</code></p>
        <p><b>当前总净值:</b> <code>$NEW_TOTAL</code></p>
        <p><b>increaseLiquidity Tx:</b> <code>$TX_HASH</code></p>
        <p><b>Receipt Status:</b> <code>$RECEIPT_STATUS</code></p>
        <p><a href='https://arbiscan.io/tx/$TX_HASH'>在 Arbiscan 查看交易</a></p>
        <hr>
        <p><small>只有 increaseLiquidity 的链上 receipt 明确成功，才会发送本邮件。</small></p>"
        send_email "$SUBJECT" "$BODY"
        exit 0
        ;;

    INCOMPLETE)
        SUBJECT="🚨 AutoCompound 未完成：禁止计为复投成功"
        BODY="<h3>🚨 本周期存在链上写入，但复投未被确认</h3>
        <p><b>时间:</b> $NOW</p>
        <p><b>状态:</b> 前序 collect/refuel/zap 可能已经执行，但未找到成功的 increaseLiquidity。</p>
        <p><b>原因:</b> <code>$REASON</code></p>
        <p><b>风险:</b> 资产可能仍停留在钱包中；请勿把本周期计为 compound 成功。</p>"
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;

    FAILED)
        SUBJECT="❌ AutoCompound 链上执行失败"
        BODY="<h3>❌ AutoCompound 执行失败</h3>
        <p><b>时间:</b> $NOW</p>
        <p><b>原因:</b> <code>$REASON</code></p>
        <p><b>退出码:</b> $EXIT_CODE</p>
        <p><b>交易:</b> <code>$TX_HASH</code></p>
        <p><b>Receipt:</b> <code>$RECEIPT_STATUS</code></p>"
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;

    UNCERTAIN)
        SUBJECT="⚠️ AutoCompound 状态不确定：未计为成功"
        BODY="<h3>⚠️ 无法完成链上成功校验</h3>
        <p><b>时间:</b> $NOW</p>
        <p><b>原因:</b> <code>$REASON</code></p>
        <p><b>交易:</b> <code>$TX_HASH</code></p>
        <p><b>处理:</b> 本周期不会被标记为复投成功，请检查 RPC / broadcast artifact / receipt。</p>"
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;

    BLOCKED)
        SUBJECT="⚠️ AutoCompound 被安全条件阻断"
        BODY="<h3>⚠️ 本周期未执行复投</h3>
        <p><b>时间:</b> $NOW</p>
        <p><b>原因:</b> <code>$REASON</code></p>
        <p><b>处理:</b> 本周期未计为复投成功。</p>"
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;

    NOOP)
        echo "ℹ️ 本周期无需复投 ($REASON)，不发送成功邮件。"
        exit 0
        ;;

    *)
        # Fail closed for legacy / unknown output. Even if Foundry prints
        # "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL", that is not sufficient.
        if [ "$EXIT_CODE" -ne 0 ] || echo "$OUTPUT" | grep -q -i "Simulation failed\|Revert\|Error"; then
            SUBJECT="❌ AutoCompound 执行异常"
            BODY="<h3>❌ 执行异常 / RPC 报错</h3>
            <p><b>时间:</b> $NOW</p>
            <p><b>退出码:</b> $EXIT_CODE</p>
            <p><b>状态:</b> 未获得可验证的业务成功结果。</p>"
        else
            SUBJECT="⚠️ AutoCompound 结果未验证：禁止计为成功"
            BODY="<h3>⚠️ 发现旧版或未知格式的执行结果</h3>
            <p><b>时间:</b> $NOW</p>
            <p><b>说明:</b> Forge 流程成功不等于复投业务成功。</p>
            <p><b>处理:</b> 未确认 increaseLiquidity receipt，因此本周期不会标记为成功。</p>"
        fi
        send_email "$SUBJECT" "$BODY"
        exit 1
        ;;
esac
