#!/bin/bash
set -o pipefail

# ========================================================
# Universal Auto-Compound Bot Execution Pipeline
# ========================================================

# 0. 动态注入环境变量 (适配所有用户的 Cron 裸环境)
export PATH="$PATH:$HOME/.foundry/bin"

# 1. 设定严格的工作目录
WORK_DIR="/home/xxxxxxx/uniswap-bot"
cd $WORK_DIR || exit 1

# 2. 【核心泛化配置区】：支持任意币种对
export TOKEN_ID=1234567

# 设定本位币：0 代表 Token0，1 代表 Token1
# 在 WETH/USDC 池子中，USDC 通常是 Token1，所以设为 1
export BASE_TOKEN_INDEX=1

# 设定复投阈值 (X10000 标定法)
# 如果 BASE 为 USDC，20000 代表 2.0000 USDC
# 如果 BASE 为 WETH，100 代表 0.0100 WETH
# 如果 直接配置为0, 表示由程序自动计算最高效率阈值
export TARGET_MIN_BASE_AMOUNT_X10000=0

# 是否允许自动Zap(自动兑换平衡复投币种) true/false
export ALLOW_AUTO_ZAP="true"

# 3. 定义日志文件路径
LOG_FILE="${WORK_DIR}/compound_bot_${TOKEN_ID}.log"
DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')

echo "====================================================" | tee -a $LOG_FILE
echo "🚀 Pipeline Triggered at: $DATE_STR" | tee -a $LOG_FILE
echo "🔧 NFT ID: $TOKEN_ID | Base Index: $BASE_TOKEN_INDEX | Target(x10000): $TARGET_MIN_BASE_AMOUNT_X10000" | tee -a $LOG_FILE

# 4. 执行 Foundry 脚本
# 如果需要虚拟执行调试, 可以先去除--broadcast选项
forge script $WORK_DIR/script/Compound.s.sol:AutoCompound \
    --rpc-url https://arb1.arbitrum.io/rpc \
    --account bot_account \
    --password-file .pass \
    --broadcast \
    --via-ir 2>&1 | tee -a $LOG_FILE

# 5. 记录退出状态码
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Pipeline Exited Gracefully (Code 0)." | tee -a $LOG_FILE
else
    echo "❌ Pipeline Failed with Exit Code: $EXIT_CODE" | tee -a $LOG_FILE
fi
echo "====================================================" | tee -a $LOG_FILE

exit $EXIT_CODE
