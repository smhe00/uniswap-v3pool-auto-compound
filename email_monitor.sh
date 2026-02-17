#!/bin/bash

# ==========================================
# 1. 网易 163 SMTP 配置 (极简版)
# ==========================================
export SMTP_SERVER="smtps://smtp.163.com:465"
export SENDER_EMAIL="xxxx@163.com"
export SENDER_PASS="you app password" 
export RECEIVER_EMAIL="xxxx@proton.me"

# 检查是否传入了目标脚本
if [ -z "$1" ]; then
    echo "用法: $0 <要执行的脚本路径>"
    echo "示例: $0 ./run_compound.sh"
    exit 1
fi

TARGET_SCRIPT="$1"
NOW=$(date +"%Y-%m-%d %H:%M:%S")

# ==========================================
# 2. 纯 Curl 163 发信引擎
# ==========================================
send_email() {
    local subject="$1"
    local body="$2"
    
    echo "正在通过网易 163 专用通道发送战报..."

    # 使用 smtps 协议直连 465 加密端口
    # 注意：163 邮箱极其严格，From 字段尖括号里的邮箱必须和登录邮箱一模一样
    curl -s --url "${SMTP_SERVER}" \
        --user "${SENDER_EMAIL}:${SENDER_PASS}" \
        --mail-from "${SENDER_EMAIL}" \
        --mail-rcpt "${RECEIVER_EMAIL}" \
        -T - <<EOF
From: "🤖 AutoCompound Bot" <${SENDER_EMAIL}>
To: <${RECEIVER_EMAIL}>
Subject: ${subject}
Content-Type: text/html; charset="utf-8"

${body}
EOF

    if [ $? -eq 0 ]; then
        echo "✅ 战报已成功空投至: ${RECEIVER_EMAIL}"
    else
        echo "⚠️ 邮件发送失败，请检查网络或授权码！"
    fi
}

# ==========================================
# 3. 核心拦截：捕获执行输出与状态码
# ==========================================
echo "📡 163 监控雷达已启动，正在接管执行: $TARGET_SCRIPT ..."

OUTPUT=$($TARGET_SCRIPT 2>&1)
EXIT_CODE=$?

# 把原脚本的高亮日志照常打印到屏幕上
echo "$OUTPUT"

# ==========================================
# 4. 模式匹配与分发
# ==========================================

# 场景 A：仓位脱轨 (最高优先级)
if echo "$OUTPUT" | grep -q "OUT-OF-RANGE"; then
    SUBJECT="🚨 严重警报：Uniswap 仓位脱轨！"
    BODY="<h3>🚨 AutoCompound 严重警报</h3>
    <p><b>时间:</b> ${NOW}</p>
    <p><b>状态:</b> 仓位已跌出设定区间 (OUT OF RANGE)！</p>
    <p><b>动作:</b> 脚本已自动硬阻断。请立刻登入处理！</p>"
    send_email "$SUBJECT" "$BODY"
    exit 1
fi

# 场景 B：主网执行失败
if [ $EXIT_CODE -ne 0 ] || echo "$OUTPUT" | grep -q -i "Simulation failed\|Revert\|Error"; then
    SUBJECT="❌ AutoCompound 执行异常"
    BODY="<h3>❌ 执行异常 / RPC 报错</h3>
    <p><b>时间:</b> ${NOW}</p>
    <p><b>退出码:</b> ${EXIT_CODE}</p>
    <p><b>建议:</b> 请检查 Arbitrum RPC 节点状态或滑点。</p>"
    send_email "$SUBJECT" "$BODY"
    exit 1
fi

# 场景 C：主网执行成功 (提取完美战报)
if echo "$OUTPUT" | grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL"; then
    INVESTED_AMT=$(echo "$OUTPUT" | grep "Invested Value :" | awk -F': ' '{print $2}' | tr -d ' ')
    NEW_TOTAL=$(echo "$OUTPUT" | grep "New Total Value:" | awk -F': ' '{print $2}' | tr -d ' ')
    
    SUBJECT="✅ 复投成功：注入 ${INVESTED_AMT}"
    BODY="<h3>✅ 自动复投狙击成功</h3>
    <p><b>时间:</b> ${NOW}</p>
    <p><b>注入生息资金:</b> <code style='color:green; font-size:16px;'>${INVESTED_AMT}</code></p>
    <p><b>当前总净值:</b> <code>${NEW_TOTAL}</code></p>
    <hr>
    <p><small>本邮件由纯 Bash + Curl 163 引擎驱动。</small></p>"
    send_email "$SUBJECT" "$BODY"
    exit 0
fi

exit 0
