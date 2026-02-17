// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// ==========================================
// Interfaces
// ==========================================
interface IERC20Metadata {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16 observationCardinality, uint16 observationCardinalityNext,
        uint8 feeProtocol, bool unlocked
    );
}

interface IMinimalPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1,
        uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);
    struct IncreaseLiquidityParams {
        uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min; uint256 deadline;
    }
    function increaseLiquidity(IncreaseLiquidityParams calldata params) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

library Math {
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y; uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) { z = 1; }
    }
}

contract AutoCompound is Script {
    uint256 constant APPROVE_MULTIPLIER = 28;
    uint256 constant MAX_BASE_FEE_WEI = 2 * 1e8; 

    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    struct LogRecord {
        uint256 timestamp;
        uint256 baseFee;
        int24 currentTick;
        bool inRange;
        
        uint256 principal0;
        uint256 principal1;
        uint256 principalTotalBase;
        
        uint256 fee0;
        uint256 fee1;
        uint256 feeTotalBase;
    }

    function getValueOf0In1(uint256 amount0, uint160 sqrtRatioX96) internal pure returns (uint256) {
        uint256 temp = (amount0 * uint256(sqrtRatioX96)) >> 96;
        return (temp * uint256(sqrtRatioX96)) >> 96;
    }

    function getValueOf1In0(uint256 amount1, uint160 sqrtRatioX96) internal pure returns (uint256) {
        uint256 temp = (amount1 << 96) / uint256(sqrtRatioX96);
        return (temp << 96) / uint256(sqrtRatioX96);
    }

    function getTotalValueBase(uint256 amt0, uint256 amt1, uint160 sqrtRatioX96, uint8 baseIdx) internal pure returns (uint256) {
        if (baseIdx == 0) return amt0 + getValueOf1In0(amt1, sqrtRatioX96);
        else return getValueOf0In1(amt0, sqrtRatioX96) + amt1;
    }

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= 887272, 'T');
            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e88ea9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8fbc1ada98aba12ca8b5f9227) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    function getAmountsForLiquidity(uint160 sqrtRatioX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = (uint256(liquidity) << 96) * (sqrtRatioBX96 - sqrtRatioAX96) / sqrtRatioBX96 / sqrtRatioAX96;
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = (uint256(liquidity) << 96) * (sqrtRatioBX96 - sqrtRatioX96) / sqrtRatioBX96 / sqrtRatioX96;
            amount1 = (uint256(liquidity) * (sqrtRatioX96 - sqrtRatioAX96)) / 0x1000000000000000000000000;
        } else {
            amount1 = (uint256(liquidity) * (sqrtRatioBX96 - sqrtRatioAX96)) / 0x1000000000000000000000000;
        }
    }

    function getEthPriceInBase(address baseToken, uint8 baseDecimals) internal view returns (uint256) {
        if (baseToken == WETH) return 10 ** baseDecimals; 
        
        address pool = IUniswapV3Factory(FACTORY).getPool(WETH, baseToken, 500);
        if (pool == address(0)) pool = IUniswapV3Factory(FACTORY).getPool(WETH, baseToken, 3000);
        if (pool == address(0)) pool = IUniswapV3Factory(FACTORY).getPool(WETH, baseToken, 10000);

        if (pool != address(0)) {
            (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
            address token0 = WETH < baseToken ? WETH : baseToken;
            if (WETH == token0) return getValueOf0In1(10**18, sqrtPriceX96);
            else return getValueOf1In0(10**18, sqrtPriceX96);
        }
        return 3000 * (10 ** baseDecimals);
    }

    function formatDecimals(uint256 value, uint8 decimals) internal pure returns (string memory) {
        if (decimals == 0) return vm.toString(value);
        uint256 base = 10**decimals; uint256 intPart = value / base; uint256 fracPart = value % base;
        string memory fracString = vm.toString(fracPart);
        uint256 padding = decimals - bytes(fracString).length; string memory zeros = "";
        for (uint256 i = 0; i < padding; i++) { zeros = string.concat(zeros, "0"); }
        return string.concat(vm.toString(intPart), ".", zeros, fracString);
    }

    function getBeijingTime(uint256 timestamp) internal pure returns (string memory) {
        uint256 ts = timestamp + 8 hours;
        int256 __days = int256(ts / 86400); int256 L = __days + 68569 + 2440588; int256 N = 4 * L / 146097; L = L - (146097 * N + 3) / 4;
        int256 _year = 4000 * (L + 1) / 1461001; L = L - 1461 * _year / 4 + 31; int256 _month = 80 * L / 2447;
        int256 _day = L - 2447 * _month / 80; L = _month / 11; _month = _month + 2 - 12 * L; _year = 100 * (N - 49) + _year + L;
        uint256 year = uint256(_year); uint256 month = uint256(_month); uint256 day = uint256(_day);
        uint256 hrs = (ts / 3600) % 24; uint256 mins = (ts / 60) % 60; uint256 secs = ts % 60;
        return string.concat(
            vm.toString(year), "-", month < 10 ? string.concat("0", vm.toString(month)) : vm.toString(month), "-",
            day < 10 ? string.concat("0", vm.toString(day)) : vm.toString(day), " ",
            hrs < 10 ? string.concat("0", vm.toString(hrs)) : vm.toString(hrs), ":",
            mins < 10 ? string.concat("0", vm.toString(mins)) : vm.toString(mins), ":",
            secs < 10 ? string.concat("0", vm.toString(secs)) : vm.toString(secs)
        );
    }

    // ==========================================
    // Main Runtime
    // ==========================================
    function run() external {
        IMinimalPositionManager manager = IMinimalPositionManager(POSITION_MANAGER);
        LogRecord memory record;

        // --- Fetch Environment Variables ---
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint8 baseTokenIndex = uint8(vm.envUint("BASE_TOKEN_INDEX"));
        require(baseTokenIndex == 0 || baseTokenIndex == 1, "BASE_TOKEN_INDEX must be 0 or 1");
        uint256 targetMinX10000 = vm.envUint("TARGET_MIN_BASE_AMOUNT_X10000");
        bool allowZap = vm.envOr("ALLOW_AUTO_ZAP", false);

        // 1. Fetch Context & Token Metadata
        record.timestamp = block.timestamp;
        record.baseFee = block.basefee;
        
        address owner = manager.ownerOf(tokenId);
        (, , address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = manager.positions(tokenId);
        
        string memory sym0 = IERC20Metadata(token0).symbol();
        string memory sym1 = IERC20Metadata(token1).symbol();
        uint8 dec0 = IERC20Metadata(token0).decimals();
        uint8 dec1 = IERC20Metadata(token1).decimals();

        string memory symBase = baseTokenIndex == 0 ? sym0 : sym1;
        uint8 decBase = baseTokenIndex == 0 ? dec0 : dec1;
        address baseTokenAddress = baseTokenIndex == 0 ? token0 : token1;
        
        address poolAddress = IUniswapV3Factory(FACTORY).getPool(token0, token1, fee);
        (, int24 currentTick, , , , , ) = IUniswapV3Pool(poolAddress).slot0();

        record.currentTick = currentTick;
        record.inRange = (currentTick >= tickLower && currentTick < tickUpper);

        uint160 sqrtPriceX96 = getSqrtRatioAtTick(currentTick);
        uint160 sqrtPriceAX96 = getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceBX96 = getSqrtRatioAtTick(tickUpper);

        uint256 price0In1 = getValueOf0In1(10**uint256(dec0), sqrtPriceX96);
        uint256 priceA0In1 = getValueOf0In1(10**uint256(dec0), sqrtPriceAX96);
        uint256 priceB0In1 = getValueOf0In1(10**uint256(dec0), sqrtPriceBX96);

        console.log("====================================================");
        console.log("             UNIVERSAL TELEMETRY DASHBOARD          ");
        console.log("====================================================");
        console.log(string.concat("Time (UTC+8)   : ", getBeijingTime(record.timestamp)));
        console.log(string.concat("Token NFT ID   : ", vm.toString(tokenId)));
        console.log(string.concat("Base Token Set : ", symBase, " (Index: ", vm.toString(baseTokenIndex), ")"));
        console.log(string.concat("BaseFee (Gwei) : ", formatDecimals(record.baseFee, 9)));
        console.log(string.concat("Current Price  : ", formatDecimals(price0In1, dec1), " ", sym1, "/", sym0, " (Tick: ", vm.toString(record.currentTick), ")"));
        console.log(string.concat("Position Range : ", formatDecimals(priceA0In1, dec1), " <---> ", formatDecimals(priceB0In1, dec1), " ", sym1, "/", sym0));
        console.log(string.concat("Status         : ", record.inRange ? "IN-RANGE [OK]" : "OUT-OF-RANGE [WARN]"));

        if (record.baseFee > MAX_BASE_FEE_WEI) {
            console.log("\n[!] SKIP: Network congested. BaseFee exceeds threshold.");
            return;
        }

        if (!record.inRange) {
            console.log("\n[!] FATAL ERROR: Position is OUT OF RANGE!");
            return; 
        }

        (record.principal0, record.principal1) = getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
        record.principalTotalBase = getTotalValueBase(record.principal0, record.principal1, sqrtPriceX96, baseTokenIndex);

        console.log("\n--- Principal Liquidity ---");
        console.log(string.concat("  -> ", sym0, "      : ", formatDecimals(record.principal0, dec0)));
        console.log(string.concat("  -> ", sym1, "      : ", formatDecimals(record.principal1, dec1)));
        console.log(string.concat("  Total Value  : ", formatDecimals(record.principalTotalBase, decBase), " ", symBase));

        // ==========================================
        // 1. 独立计算最优门限 R*
        // ==========================================
        uint256 optimalThresholdBase;
        uint256 ethPriceInBase = getEthPriceInBase(baseTokenAddress, decBase);

        if (targetMinX10000 == 0) {
            uint256 estimatedGas = allowZap ? 380000 : 250000;
            //uint256 estimatedGas = 250000; // 综合估算中位数
            uint256 costCInBase = (tx.gasprice * estimatedGas * ethPriceInBase) / 1e18;
            optimalThresholdBase = Math.sqrt(2 * record.principalTotalBase * costCInBase);
            console.log("\n[AI Brain] Dynamic R* Threshold Computed:");
            console.log(string.concat("  -> Optimal R* : ", formatDecimals(optimalThresholdBase, decBase), " ", symBase));
        } else {
            optimalThresholdBase = (targetMinX10000 * (10**uint256(decBase))) / 10000;
        }

        // ==========================================
        // 2. 独立模块 A：判决是否收取 Fee
        // ==========================================
        uint256 snapshotId = vm.snapshot();
        vm.startPrank(owner);
        IMinimalPositionManager.CollectParams memory simParams = IMinimalPositionManager.CollectParams({
            tokenId: tokenId, recipient: owner, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        (record.fee0, record.fee1) = manager.collect(simParams);
        vm.stopPrank();
        require(vm.revertTo(snapshotId), "Snapshot rollback failed");

        record.feeTotalBase = getTotalValueBase(record.fee0, record.fee1, sqrtPriceX96, baseTokenIndex);
        
        console.log("\n--- Module A: Collect Check ---");
        console.log(string.concat("  -> Pending Fee: ", formatDecimals(record.feeTotalBase, decBase), " ", symBase));
        
        bool shouldCollect = record.feeTotalBase >= optimalThresholdBase;
        if (shouldCollect) {
            console.log("  -> [YES] Fee >= R*. Will execute Collect.");
        } else {
            console.log("  -> [NO] Fee < R*. Skipping Collect.");
        }

        // ==========================================
        // 3. 独立模块 B：预判复投火力
        // ==========================================
        // 预测钱包将拥有的资产（当前物理余额 + 即将收取的预期Fee）
        uint256 expectedBal0 = IERC20Metadata(token0).balanceOf(owner) + (shouldCollect ? record.fee0 : 0);
        uint256 expectedBal1 = IERC20Metadata(token1).balanceOf(owner) + (shouldCollect ? record.fee1 : 0);
        uint256 expectedWalletTotalBase = getTotalValueBase(expectedBal0, expectedBal1, sqrtPriceX96, baseTokenIndex);

        console.log("\n--- Module B: Reinvest Check ---");
        console.log(string.concat("  -> Exp. Wallet: ", formatDecimals(expectedWalletTotalBase, decBase), " ", symBase));

        bool shouldReinvest = expectedWalletTotalBase >= optimalThresholdBase;
        if (shouldReinvest) {
            console.log("  -> [YES] Wallet >= R*. Will execute Reinvest.");
        } else {
            console.log("  -> [NO] Wallet < R*. Skipping Reinvest.");
        }

        // 如果两个动作都不需要执行，打印详细的对比数据并彻底休眠！
        if (!shouldCollect && !shouldReinvest) {
            console.log(unicode"\n[💤] SKIP: Conditions not met for any action.");
            console.log(string.concat("  -> Target Threshold (R*) : ", formatDecimals(optimalThresholdBase, decBase), " ", symBase));
            console.log(string.concat("  -> Current Pending Fee   : ", formatDecimals(record.feeTotalBase, decBase), " ", symBase, " (Need >= R*)"));
            console.log(string.concat("  -> Current Wallet Cap.   : ", formatDecimals(expectedWalletTotalBase, decBase), " ", symBase, " (Need >= R*)"));
            console.log("Going back to sleep to save Gas.");
            console.log("====================================================");
            return;
        }

        // ==========================================
        // 🚨 ENTERING REAL ON-CHAIN MUTATION PHASE 🚨
        // ==========================================
        console.log(unicode"\n[🚀] Firing up the execution pipeline...");
        vm.startBroadcast();

        // [执行模块 A]
        if (shouldCollect) {
            manager.collect(simParams);
            console.log("  -> [Collected] Successfully harvested fees.");
        }

        // [执行模块 B & C]
        if (shouldReinvest) {
            // 重新读取最真实的物理余额（防止模拟误差）
            uint256 finalBal0 = IERC20Metadata(token0).balanceOf(owner);
            uint256 finalBal1 = IERC20Metadata(token1).balanceOf(owner);

            // ==========================================
            // 4. 独立模块 C：V3 动态曲率 Zap 引擎 (Ultimate Edition)
            // ==========================================
            if (allowZap) {
                console.log("\n--- Module C: V3 Dynamic Curve Zap Engine ---");
                
                uint256 val0 = getTotalValueBase(finalBal0, 0, sqrtPriceX96, baseTokenIndex);
                uint256 val1 = getTotalValueBase(0, finalBal1, sqrtPriceX96, baseTokenIndex);
                uint256 walletTotalVal = val0 + val1;

                (uint256 req0, uint256 req1) = getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, 1e18);
                uint256 reqVal0 = getTotalValueBase(req0, 0, sqrtPriceX96, baseTokenIndex);
                uint256 reqVal1 = getTotalValueBase(0, req1, sqrtPriceX96, baseTokenIndex);
                uint256 reqTotalVal = reqVal0 + reqVal1;

                require(reqTotalVal > 0, "Invalid pool ratio");

                uint256 targetVal0 = (walletTotalVal * reqVal0) / reqTotalVal;
                uint256 targetVal1 = (walletTotalVal * reqVal1) / reqTotalVal;

                // 1. 算出“闪兑催化剂” (需要被 Swap 的偏差值，即钥匙)
                bool is0Dominant = val0 > targetVal0;
                uint256 excessVal = is0Dominant ? (val0 - targetVal0) : (val1 - targetVal1);

                // 2. [数学魔法] 算出这笔催化剂能“撬动”的【全部真实闲置资金】(钥匙 + 宝藏)！
                // 推导: 闲置总资金 = 偏差值 * (总比例 / 稀缺方比例)
                uint256 totalIdleCapital = is0Dominant ? (excessVal * reqTotalVal) / reqVal1 : (excessVal * reqTotalVal) / reqVal0;

                uint256 feeRateHalfX1e6 = fee / 2; 
                uint256 expectedYieldRateX1e6 = (optimalThresholdBase * 1e6) / record.principalTotalBase;

                console.log(string.concat("  -> Target Ratio     : ", is0Dominant ? sym0 : sym1, " needs to be swapped."));
                console.log(string.concat("  -> Excess Catalyst  : ", formatDecimals(excessVal, decBase), " ", symBase));
                console.log(string.concat("  -> Total Idle Cap.  : ", formatDecimals(totalIdleCapital, decBase), " ", symBase));

                // 3. 计算绝对利润：全部闲置资金的预期收益 vs (Swap手续费 + 链上Gas)
                uint256 expectedGain = (totalIdleCapital * expectedYieldRateX1e6) / 1e6;
                uint256 swapFeeCost = (excessVal * feeRateHalfX1e6) / 1e6;
                uint256 zapGasCostBase = (tx.gasprice * 150000 * ethPriceInBase) / 1e18;

                console.log(string.concat("  -> Exp. Zap Gain    : ", formatDecimals(expectedGain, decBase), " ", symBase));
                console.log(string.concat("  -> Est. Gas+Fee Cost: ", formatDecimals(zapGasCostBase + swapFeeCost, decBase), " ", symBase));

                // 4. 终极判决：只要生息利润大于摩擦成本，立刻扣动扳机
                if (expectedGain > (zapGasCostBase + swapFeeCost)) {
                    console.log("  -> [ZAP APPROVED] Gain > Cost. Executing precision swap...");
                    
                    if (is0Dominant) {
                        uint256 swapAmount0 = (finalBal0 * excessVal) / val0;
                        console.log(string.concat("  -> Swapping ", sym0, " : ", formatDecimals(swapAmount0, dec0)));
                        
                        uint256 routerAllowance0 = IERC20Metadata(token0).allowance(owner, SWAP_ROUTER);
                        if (routerAllowance0 < swapAmount0) {
                            uint256 approveAmt = swapAmount0 * APPROVE_MULTIPLIER;
                            IERC20Metadata(token0).approve(SWAP_ROUTER, approveAmt);
                        }
                        ISwapRouter(SWAP_ROUTER).exactInputSingle(
                            ISwapRouter.ExactInputSingleParams({
                                tokenIn: token0, tokenOut: token1, fee: fee, recipient: owner,
                                deadline: block.timestamp + 1200, amountIn: swapAmount0, amountOutMinimum: 0, sqrtPriceLimitX96: 0
                            })
                        );
                    } else {
                        uint256 swapAmount1 = (finalBal1 * excessVal) / val1;
                        console.log(string.concat("  -> Swapping ", sym1, " : ", formatDecimals(swapAmount1, dec1)));
                        
                        uint256 routerAllowance1 = IERC20Metadata(token1).allowance(owner, SWAP_ROUTER);
                        if (routerAllowance1 < swapAmount1) {
                            uint256 approveAmt = swapAmount1 * APPROVE_MULTIPLIER;
                            IERC20Metadata(token1).approve(SWAP_ROUTER, approveAmt);
                        }
                        ISwapRouter(SWAP_ROUTER).exactInputSingle(
                            ISwapRouter.ExactInputSingleParams({
                                tokenIn: token1, tokenOut: token0, fee: fee, recipient: owner,
                                deadline: block.timestamp + 1200, amountIn: swapAmount1, amountOutMinimum: 0, sqrtPriceLimitX96: 0
                            })
                        );
                    }
                    
                    // 刷新最新物理余额，此时已成完美配比
                    finalBal0 = IERC20Metadata(token0).balanceOf(owner);
                    finalBal1 = IERC20Metadata(token1).balanceOf(owner);
                } else {
                    console.log("  -> [BYPASS] Gain <= Cost. Mathematically unprofitable to Zap.");
                }
            }

            // [执行复投]
            uint256 allowance0 = IERC20Metadata(token0).allowance(owner, POSITION_MANAGER);
            uint256 allowance1 = IERC20Metadata(token1).allowance(owner, POSITION_MANAGER);

            if (allowance0 < finalBal0 && finalBal0 > 0) {
                IERC20Metadata(token0).approve(POSITION_MANAGER, finalBal0 * APPROVE_MULTIPLIER);
            }
            if (allowance1 < finalBal1 && finalBal1 > 0) {
                IERC20Metadata(token1).approve(POSITION_MANAGER, finalBal1 * APPROVE_MULTIPLIER);
            }

            IMinimalPositionManager.IncreaseLiquidityParams memory incParams = IMinimalPositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: finalBal0, amount1Desired: finalBal1,
                amount0Min: 0, amount1Min: 0,
                deadline: block.timestamp + 180 
            });

            (uint128 addedLiquidity, uint256 used0, uint256 used1) = manager.increaseLiquidity(incParams);
            
            uint256 totalUsedBase = getTotalValueBase(used0, used1, sqrtPriceX96, baseTokenIndex);
            uint256 newTotalBase = record.principalTotalBase + totalUsedBase;

            console.log("\n--- Reinvestment Successful ---");
            console.log(string.concat("Invested Value : +", formatDecimals(totalUsedBase, decBase), " ", symBase));
            console.log(string.concat("Liquidity (L)  : +", vm.toString(addedLiquidity), " (Math Unit)"));
            console.log(string.concat("New Total Value: ", formatDecimals(newTotalBase, decBase), " ", symBase));
        }

        vm.stopBroadcast();
        console.log("====================================================");
    }
}
