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

interface IWETH9 {
    function balanceOf(address account) external view returns (uint256);
    function withdraw(uint256 wad) external;
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
    
    bool private debugMode;

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

    function logDebug(string memory msg1, uint256 val) internal view {
        if (debugMode) console.log(string.concat("[DEBUG] ", msg1, vm.toString(val)));
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

    // Refined formatter with 8-decimal limit
    function formatDecimals(uint256 value, uint8 decimals) internal pure returns (string memory) {
        if (decimals == 0) return vm.toString(value);
        uint256 base = 10**decimals; 
        uint256 intPart = value / base; 
        uint256 fracPart = value % base;
        
        string memory fracString = vm.toString(fracPart);
        uint256 padding = decimals - bytes(fracString).length; 
        string memory zeros = "";
        for (uint256 i = 0; i < padding; i++) { zeros = string.concat(zeros, "0"); }
        
        string memory fullFrac = string.concat(zeros, fracString);
        
        // Hard-clip to 8 decimal places for cleaner logs
        if (bytes(fullFrac).length > 8) {
            bytes memory truncated = new bytes(8);
            for(uint i=0; i<8; i++) {
                truncated[i] = bytes(fullFrac)[i];
            }
            fullFrac = string(truncated);
        }
        
        return string.concat(vm.toString(intPart), ".", fullFrac);
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

        // --- 0. Initialize ---
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint8 baseTokenIndex = uint8(vm.envUint("BASE_TOKEN_INDEX"));
        uint256 targetMinX10000 = vm.envUint("TARGET_MIN_BASE_AMOUNT_X10000");
        bool allowZap = vm.envOr("ALLOW_AUTO_ZAP", false);
        debugMode = vm.envOr("DEBUG_ENABLE", false);

        // ====================================================
        // 🔍 PHASE 1: ANALYSIS & PRE-CALCULATION
        // ====================================================

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
        uint160 sqrtPriceX96 = getSqrtRatioAtTick(currentTick);
        
        record.currentTick = currentTick;
        record.inRange = (currentTick >= tickLower && currentTick < tickUpper);
        
        uint160 sqrtPriceAX96 = getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceBX96 = getSqrtRatioAtTick(tickUpper);
        uint256 price0In1 = getValueOf0In1(10**uint256(dec0), sqrtPriceX96);
        uint256 priceA0In1 = getValueOf0In1(10**uint256(dec0), sqrtPriceAX96);
        uint256 priceB0In1 = getValueOf0In1(10**uint256(dec0), sqrtPriceBX96);

        console.log("====================================================");
        console.log("             UNIVERSAL TELEMETRY DASHBOARD          ");
        console.log("====================================================");
        console.log(string.concat("Time (UTC+8)    : ", getBeijingTime(record.timestamp)));
        console.log(string.concat("Token NFT ID    : ", vm.toString(tokenId)));
        console.log(string.concat("Base Token Set  : ", symBase, " (Index: ", vm.toString(baseTokenIndex), ")"));
        console.log(string.concat("BaseFee (Gwei)  : ", formatDecimals(record.baseFee, 9)));
        console.log(string.concat("Current Price   : ", formatDecimals(price0In1, dec1), " ", sym1, "/", sym0, " (Tick: ", vm.toString(record.currentTick), ")"));
        console.log(string.concat("Position Range  : ", formatDecimals(priceA0In1, dec1), " <---> ", formatDecimals(priceB0In1, dec1), " ", sym1, "/", sym0));
        console.log(string.concat("Status          : ", record.inRange ? "IN-RANGE [OK]" : "OUT-OF-RANGE [WARN]"));

        if (!record.inRange) {
             console.log("\n[!] FATAL: Position OUT OF RANGE. Stopping."); 
             return; 
        }

        (record.principal0, record.principal1) = getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
        record.principalTotalBase = getTotalValueBase(record.principal0, record.principal1, sqrtPriceX96, baseTokenIndex);

        console.log("\n--- Principal Liquidity ---");
        console.log(string.concat(" -> ", sym0, "       : ", formatDecimals(record.principal0, dec0)));
        console.log(string.concat(" -> ", sym1, "       : ", formatDecimals(record.principal1, dec1)));
        console.log(string.concat(" Total Value  : ", formatDecimals(record.principalTotalBase, decBase), " ", symBase));

        // 1.2 Simulate Collect
        uint256 snapshotId = vm.snapshot();
        vm.startPrank(owner);
        IMinimalPositionManager.CollectParams memory simParams = IMinimalPositionManager.CollectParams({
            tokenId: tokenId, recipient: owner, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        (record.fee0, record.fee1) = manager.collect(simParams);
        vm.stopPrank();
        require(vm.revertTo(snapshotId), "Snapshot rollback failed");

        record.feeTotalBase = getTotalValueBase(record.fee0, record.fee1, sqrtPriceX96, baseTokenIndex);

        // 1.3 Fetch Wallet Balances
        uint256 wallet0 = IERC20Metadata(token0).balanceOf(owner);
        uint256 wallet1 = IERC20Metadata(token1).balanceOf(owner);
        uint256 walletTotalBase = getTotalValueBase(wallet0, wallet1, sqrtPriceX96, baseTokenIndex);
        
        // Calculate Total Capital Breakdowns
        uint256 totalInvestableBase = record.feeTotalBase + walletTotalBase;
        uint256 total0 = wallet0 + record.fee0;
        uint256 total1 = wallet1 + record.fee1;

        // 1.4 Calculate R* Threshold
        uint256 optimalThresholdBase;
        uint256 ethPriceInBase = getEthPriceInBase(baseTokenAddress, decBase);
        uint256 costCInBase; // keep in function scope for empty-position Zap fallback
        bool isAutoCalc = false; 

        if (targetMinX10000 == 0) {
            uint256 estimatedGas = allowZap ? 380000 : 250000;
            costCInBase = (tx.gasprice * estimatedGas * ethPriceInBase) / 1e18;
            optimalThresholdBase = Math.sqrt(2 * record.principalTotalBase * costCInBase);
            isAutoCalc = true;
        } else {
            optimalThresholdBase = (targetMinX10000 * (10**uint256(decBase))) / 10000;
        }
        
        console.log("\n--- Asset & Threshold Analysis ---");
        // [Detailed] Pending Fee breakdown
        console.log(string.concat(" Pending Fee    : ", formatDecimals(record.feeTotalBase, decBase), " ", symBase,
            string.concat(" ( ", formatDecimals(record.fee0, dec0), " ", sym0, " / ", formatDecimals(record.fee1, dec1), " ", sym1, " )")
        ));
        
        // [Detailed] Wallet breakdown
        console.log(string.concat(" Wallet Balance : ", formatDecimals(walletTotalBase, decBase), " ", symBase, 
            string.concat(" ( ", formatDecimals(wallet0, dec0), " ", sym0, " / ", formatDecimals(wallet1, dec1), " ", sym1, " )")
        ));
        
        // [Detailed] Total Capital breakdown
        console.log(string.concat(" Total Capital  : ", formatDecimals(totalInvestableBase, decBase), " ", symBase,
            string.concat(" ( ", formatDecimals(total0, dec0), " ", sym0, " / ", formatDecimals(total1, dec1), " ", sym1, " )")
        ));

        if (isAutoCalc) {
            console.log(string.concat(" Optimal R* : ", formatDecimals(optimalThresholdBase, decBase), " ", symBase, " (Auto-Dynamic)"));
        } else {
            console.log(string.concat(" Optimal R* : ", formatDecimals(optimalThresholdBase, decBase), " ", symBase, " (Manual-Fixed)"));
        }

        // 1.5 Fuel Check & Net Asset Calculation
        uint256 currentEth = owner.balance; 
        
        // ----------------------------------------------------
        // [PRODUCTION PARAMS]
        // ----------------------------------------------------
        uint256 minEth = 0.001 ether;     
        uint256 targetEth = 0.004 ether;  
        uint256 minRefuelChunk = 0.001 ether; 
        
	// [TEST PARAMS]
        // uint256 minEth = 10.007 ether;     
        // uint256 targetEth = 10.008 ether;  
        // uint256 minRefuelChunk = 10.001 ether; 
        
        bool needRefuel = false;
        uint256 refuelAmount = 0;

        // 初始化 projectedBal (基础值 = 钱包余额 + 待收Fee)
        uint256 projectedBal0 = wallet0 + record.fee0;
        uint256 projectedBal1 = wallet1 + record.fee1;

        if (currentEth < minEth) {
            uint256 deficit = targetEth - currentEth;
            uint256 availableWeth = 0;
            
            if (WETH == token0) availableWeth = projectedBal0;
            else if (WETH == token1) availableWeth = projectedBal1;
            else console.log("[WARN] No WETH in this pair to refuel!");

            if (availableWeth >= deficit) {
                refuelAmount = deficit;
                needRefuel = true;
                console.log(string.concat("\n[Fuel Check] LOW GAS! Will Refuel Full Amount: ", formatDecimals(refuelAmount, 18), " ETH"));
            } else if (availableWeth >= minRefuelChunk) {
                refuelAmount = availableWeth;
                needRefuel = true;
                console.log(string.concat("\n[Fuel Check] LOW GAS! Partial Refuel (Best Effort): ", formatDecimals(refuelAmount, 18), " ETH"));
            } else {
                console.log("\n[ALARM] CRITICAL: LOW GAS & INSUFFICIENT WETH TO REFUEL!");
                console.log(string.concat(" -> Current Gas    : ", formatDecimals(currentEth, 18), " ETH (Min Required: ", formatDecimals(minEth, 18), ")"));
                console.log(string.concat(" -> WETH Available : ", formatDecimals(availableWeth, 18), " ETH"));
                console.log(string.concat(" -> Min Refuel Chunk: ", formatDecimals(minRefuelChunk, 18), " ETH"));
                console.log("[STOP] Execution Aborted to prevent gas exhaustion.");
                return; // ⛔️ 强制退出
            }
        }

        if (needRefuel) {
            if (WETH == token0) {
                projectedBal0 -= refuelAmount; 
            } else if (WETH == token1) {
                projectedBal1 -= refuelAmount;
            }
        }

        uint256 netInvestableBase = getTotalValueBase(projectedBal0, projectedBal1, sqrtPriceX96, baseTokenIndex);
        
        bool shouldExecute = netInvestableBase >= optimalThresholdBase;
        if (needRefuel && netInvestableBase > 0) shouldExecute = true;

        if (shouldExecute) {
             console.log(string.concat(" -> [DECISION] Status: Capital > R*. EXECUTE (Collect + ", needRefuel ? "Refuel + " : "", "Invest)"));
        } else {
            console.log(" -> [DECISION] Status: Capital < R*. WAIT.");
            console.log("[zZZ] Going back to sleep.");
            return; 
        }

        // ====================================================
        // 🚀 PHASE 2: ATOMIC EXECUTION (Write)
        // ====================================================
        console.log(unicode"\n[🚀] Firing up the execution pipeline...");
        vm.startBroadcast();

        // 2.1 Action: Collect
        (uint256 col0, uint256 col1) = manager.collect(simParams); 
        console.log(string.concat(" -> [Action] Collect Executed. Got: ", formatDecimals(col0, dec0), " ", sym0, " / ", formatDecimals(col1, dec1), " ", sym1));

        // 2.2 Action: Refuel
        if (needRefuel && refuelAmount > 0) {
            IWETH9(WETH).withdraw(refuelAmount);
            console.log(string.concat(" -> [Action] Refuel Executed. Unwrapped ", formatDecimals(refuelAmount, 18), " WETH."));
        }

        // 2.3 Action: Zap & Invest
        uint256 finalBal0 = IERC20Metadata(token0).balanceOf(owner);
        uint256 finalBal1 = IERC20Metadata(token1).balanceOf(owner);

        // Zap 模块
        if (allowZap) {
             console.log("\n--- V3 Dynamic Curve Zap Engine ---");
             uint256 val0 = getTotalValueBase(finalBal0, 0, sqrtPriceX96, baseTokenIndex);
             uint256 val1 = getTotalValueBase(0, finalBal1, sqrtPriceX96, baseTokenIndex);
             uint256 walletTotalVal = val0 + val1;

             (uint256 req0, uint256 req1) = getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, 1e18);
             uint256 reqVal0 = getTotalValueBase(req0, 0, sqrtPriceX96, baseTokenIndex);
             uint256 reqVal1 = getTotalValueBase(0, req1, sqrtPriceX96, baseTokenIndex);
             uint256 reqTotalVal = reqVal0 + reqVal1;

             if (reqTotalVal > 0) {
                uint256 targetVal0 = (walletTotalVal * reqVal0) / reqTotalVal;
                uint256 targetVal1 = (walletTotalVal * reqVal1) / reqTotalVal;

                bool is0Dominant = val0 > targetVal0;
                uint256 excessVal = is0Dominant ? (val0 - targetVal0) : (val1 - targetVal1);
                uint256 totalIdleCapital = is0Dominant ? (excessVal * reqTotalVal) / reqVal1 : (excessVal * reqTotalVal) / reqVal0;

                uint256 feeRateHalfX1e6 = fee / 2; 
                uint256 expectedYieldRateX1e6;
                if (record.principalTotalBase > 0) {
                    expectedYieldRateX1e6 = (optimalThresholdBase * 1e6) / record.principalTotalBase;
                } else if (walletTotalVal > 0) {
                    // Empty-position fallback: preserve the original yield model,
                    // but use current wallet capital as the temporary principal.
                    uint256 fallbackThresholdBase = isAutoCalc
                        ? Math.sqrt(2 * walletTotalVal * costCInBase)
                        : optimalThresholdBase;
                    expectedYieldRateX1e6 = (fallbackThresholdBase * 1e6) / walletTotalVal;
                }
                uint256 expectedGain = (totalIdleCapital * expectedYieldRateX1e6) / 1e6;
                uint256 swapFeeCost = (excessVal * feeRateHalfX1e6) / 1e6;
                uint256 zapGasCostBase = (tx.gasprice * 150000 * ethPriceInBase) / 1e18;
                
                console.log(string.concat(" -> Target Ratio     : ", is0Dominant ? sym0 : sym1, " needs to be swapped."));
                console.log(string.concat(" -> Cycle Yield Rate : ", vm.toString(expectedYieldRateX1e6), " ppm"));
                console.log(string.concat(" -> Swap Fee Hurdle  : ", vm.toString(feeRateHalfX1e6), " ppm"));
                console.log(string.concat(" -> True Excess Cap. : ", formatDecimals(excessVal, decBase), " ", symBase));
                console.log(string.concat(" -> Zap Gain vs Cost : ", formatDecimals(expectedGain, decBase), " vs ", formatDecimals(zapGasCostBase + swapFeeCost, decBase)));

                if (expectedGain > (zapGasCostBase + swapFeeCost)) {
                    // console.log(" -> [Zap] Executing Precision Swap...");
                    if (is0Dominant) {
                        uint256 swapAmount0 = (finalBal0 * excessVal) / val0;
                        if (IERC20Metadata(token0).allowance(owner, SWAP_ROUTER) < swapAmount0) IERC20Metadata(token0).approve(SWAP_ROUTER, type(uint256).max);
                        ISwapRouter(SWAP_ROUTER).exactInputSingle(ISwapRouter.ExactInputSingleParams({
                            tokenIn: token0, tokenOut: token1, fee: fee, recipient: owner,
                            deadline: block.timestamp + 1200, amountIn: swapAmount0, amountOutMinimum: 0, sqrtPriceLimitX96: 0
                        }));
                    } else {
                        uint256 swapAmount1 = (finalBal1 * excessVal) / val1;
                        if (IERC20Metadata(token1).allowance(owner, SWAP_ROUTER) < swapAmount1) IERC20Metadata(token1).approve(SWAP_ROUTER, type(uint256).max);
                        ISwapRouter(SWAP_ROUTER).exactInputSingle(ISwapRouter.ExactInputSingleParams({
                            tokenIn: token1, tokenOut: token0, fee: fee, recipient: owner,
                            deadline: block.timestamp + 1200, amountIn: swapAmount1, amountOutMinimum: 0, sqrtPriceLimitX96: 0
                        }));
                    }
                    finalBal0 = IERC20Metadata(token0).balanceOf(owner);
                    finalBal1 = IERC20Metadata(token1).balanceOf(owner);
                } else {
                    console.log(" -> [BYPASS] Gain < Cost. Mathematically unprofitable to Zap.");
                }
             }
        }

        // 2.4 Final Inject
        if (finalBal0 > 0 && finalBal1 > 0) { 
            if (IERC20Metadata(token0).allowance(owner, POSITION_MANAGER) < finalBal0) IERC20Metadata(token0).approve(POSITION_MANAGER, type(uint256).max);
            if (IERC20Metadata(token1).allowance(owner, POSITION_MANAGER) < finalBal1) IERC20Metadata(token1).approve(POSITION_MANAGER, type(uint256).max);

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
        } else {
            console.log("\n[SKIP] Final Check: One asset is 0. Cannot invest into In-Range position.");
            if (finalBal0 == 0) console.log(string.concat(" -> ", sym0, " balance is 0"));
            if (finalBal1 == 0) console.log(string.concat(" -> ", sym1, " balance is 0"));
        }
        vm.stopBroadcast();
        console.log("====================================================");
    }
}
