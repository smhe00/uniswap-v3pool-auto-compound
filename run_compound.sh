#!/bin/bash

# ========================================================
# Universal Auto-Compound Bot Execution Pipeline
# ========================================================

# 1. 设定严格的工作目录
WORK_DIR="/home/peter/uniswap-auto-compound"
cd $WORK_DIR || exit 1

# 2. 【核心泛化配置区】：支持任意币种对
export TOKEN_ID=1234567

# 设定本位币：0 代表 Token0，1 代表 Token1
# 在 WETH/USDC 池子中，USDC 通常是 Token1，所以设为 1
export BASE_TOKEN_INDEX=1

# 设定复投阈值 (X10000 标定法)
# 如果 BASE 为 USDC，20000 代表 2.0000 USDC
# 如果 BASE 为 WETH，100 代表 0.0100 WETH
export TARGET_MIN_BASE_AMOUNT_X10000=10000

# 3. 定义日志文件路径
LOG_FILE="$WORK_DIR/compound_bot.log"
DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')

echo "====================================================" >> $LOG_FILE
echo "🚀 Pipeline Triggered at: $DATE_STR" >> $LOG_FILE
echo "🔧 NFT ID: $TOKEN_ID | Base Index: $BASE_TOKEN_INDEX | Target(x10000): $TARGET_MIN_BASE_AMOUNT_X10000" >> $LOG_FILE

# 4. 执行 Foundry 脚本
forge script script/Compound.s.sol:AutoCompound \
    --rpc-url https://arb1.arbitrum.io/rpc \
    --account test_bot_account \
    --password-file .pass \
    --broadcast \
    --via-ir >> $LOG_FILE 2>&1

# 5. 记录退出状态码
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Pipeline Exited Gracefully (Code 0)." >> $LOG_FILE
else
    echo "❌ Pipeline Failed with Exit Code: $EXIT_CODE" >> $LOG_FILE
fi
echo "====================================================" >> $LOG_FILE
