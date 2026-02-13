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

contract AutoCompound is Script {
    // ==========================================
    // Fixed Internal Configurations
    // ==========================================
    uint256 constant APPROVE_MULTIPLIER = 28;
    uint256 constant MAX_BASE_FEE_WEI = 2 * 1e8; // 0.2 Gwei

    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

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
        
        bool meetsThreshold;
    }

    // ==========================================
    // Math & Conversion Modules
    // ==========================================
    
    // Calculates value of amount0 in terms of token1 natively
    function getValueOf0In1(uint256 amount0, uint160 sqrtRatioX96) internal pure returns (uint256) {
        uint256 temp = (amount0 * uint256(sqrtRatioX96)) >> 96;
        return (temp * uint256(sqrtRatioX96)) >> 96;
    }

    // Calculates value of amount1 in terms of token0 natively
    function getValueOf1In0(uint256 amount1, uint160 sqrtRatioX96) internal pure returns (uint256) {
        uint256 temp = (amount1 << 96) / uint256(sqrtRatioX96);
        return (temp << 96) / uint256(sqrtRatioX96);
    }

    function getTotalValueBase(uint256 amt0, uint256 amt1, uint160 sqrtRatioX96, uint8 baseIdx) internal pure returns (uint256) {
        if (baseIdx == 0) {
            return amt0 + getValueOf1In0(amt1, sqrtRatioX96);
        } else {
            return getValueOf0In1(amt0, sqrtRatioX96) + amt1;
        }
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

    function formatDecimals(uint256 value, uint8 decimals) internal pure returns (string memory) {
        if (decimals == 0) return vm.toString(value);
        uint256 base = 10**decimals;
        uint256 intPart = value / base;
        uint256 fracPart = value % base;
        string memory fracString = vm.toString(fracPart);
        uint256 padding = decimals - bytes(fracString).length;
        string memory zeros = "";
        for (uint256 i = 0; i < padding; i++) { zeros = string.concat(zeros, "0"); }
        return string.concat(vm.toString(intPart), ".", zeros, fracString);
    }

    function getBeijingTime(uint256 timestamp) internal pure returns (string memory) {
        uint256 ts = timestamp + 8 hours;
        int256 __days = int256(ts / 86400);

        int256 L = __days + 68569 + 2440588;
        int256 N = 4 * L / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 _year = 4000 * (L + 1) / 1461001;
        L = L - 1461 * _year / 4 + 31;
        int256 _month = 80 * L / 2447;
        int256 _day = L - 2447 * _month / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;

        uint256 year = uint256(_year);
        uint256 month = uint256(_month);
        uint256 day = uint256(_day);
        
        uint256 hrs = (ts / 3600) % 24;
        uint256 mins = (ts / 60) % 60;
        uint256 secs = ts % 60;

        return string.concat(
            vm.toString(year), "-",
            month < 10 ? string.concat("0", vm.toString(month)) : vm.toString(month), "-",
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
        uint256 minFeeBaseThreshold = (targetMinX10000 * (10**uint256(decBase))) / 10000;
        
        address poolAddress = IUniswapV3Factory(FACTORY).getPool(token0, token1, fee);
        (, int24 currentTick, , , , , ) = IUniswapV3Pool(poolAddress).slot0();

        record.currentTick = currentTick;
        record.inRange = (currentTick >= tickLower && currentTick < tickUpper);

        uint160 sqrtPriceX96 = getSqrtRatioAtTick(currentTick);
        uint160 sqrtPriceAX96 = getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceBX96 = getSqrtRatioAtTick(tickUpper);

        // Price of 1 unit of Token0 in terms of Token1
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

        // GATE 0: Gas Throttling Check
        if (record.baseFee > MAX_BASE_FEE_WEI) {
            console.log("\n[!] SKIP: Network congested. BaseFee exceeds threshold.");
            console.log("====================================================");
            return;
        }

        // GATE 1: Out-of-Range Check
        if (!record.inRange) {
            console.log("\n[!] FATAL ERROR: Position is OUT OF RANGE!");
            console.log("====================================================");
            return; 
        }

        // 2. Calculate Principal
        (record.principal0, record.principal1) = getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
        record.principalTotalBase = getTotalValueBase(record.principal0, record.principal1, sqrtPriceX96, baseTokenIndex);

        console.log("\n--- Principal Liquidity ---");
        console.log(string.concat("  -> ", sym0, "      : ", formatDecimals(record.principal0, dec0)));
        console.log(string.concat("  -> ", sym1, "      : ", formatDecimals(record.principal1, dec1)));
        console.log(string.concat("  Total Value  : ", formatDecimals(record.principalTotalBase, decBase), " ", symBase));

        // 3. Predictive Dry-Run (Snapshot & Rollback to prevent state pollution)
        uint256 snapshotId = vm.snapshot();

        vm.startPrank(owner);
        IMinimalPositionManager.CollectParams memory simParams = IMinimalPositionManager.CollectParams({
            tokenId: tokenId, recipient: owner, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        (record.fee0, record.fee1) = manager.collect(simParams);
        vm.stopPrank();

        // Rollback state immediately to ensure no destructive read occurred
        require(vm.revertTo(snapshotId), "Snapshot rollback failed");

        record.feeTotalBase = getTotalValueBase(record.fee0, record.fee1, sqrtPriceX96, baseTokenIndex);
        record.meetsThreshold = (record.feeTotalBase >= minFeeBaseThreshold);

        console.log("\n--- Pending Fees ---");
        console.log(string.concat("  -> ", sym0, "      : ", formatDecimals(record.fee0, dec0)));
        console.log(string.concat("  -> ", sym1, "      : ", formatDecimals(record.fee1, dec1)));
        console.log(string.concat("  Total Value  : ", formatDecimals(record.feeTotalBase, decBase), " ", symBase));

        // GATE 2: Fee Threshold Check
        if (!record.meetsThreshold) {
            console.log(string.concat("\n[!] SKIP: Total Fee (", formatDecimals(record.feeTotalBase, decBase), " ", symBase, ") below Target."));
            console.log("====================================================");
            return; 
        }

        console.log("\n[OK] Gate check passed. Proceeding to reinvest...");

        // ==========================================
        // 🚨 ENTERING REAL ON-CHAIN MUTATION PHASE 🚨
        // ==========================================
        
        // Start actual cryptographic broadcast only after passing all gates
        vm.startBroadcast();

        // 4. Real Collect operation
        manager.collect(simParams);

        // 5. Prefetch Allowances Check (PoLP: Strict 28x Multiplier)
        uint256 bal0 = IERC20Metadata(token0).balanceOf(owner);
        uint256 bal1 = IERC20Metadata(token1).balanceOf(owner);

        uint256 allowance0 = IERC20Metadata(token0).allowance(owner, POSITION_MANAGER);
        uint256 allowance1 = IERC20Metadata(token1).allowance(owner, POSITION_MANAGER);

        console.log("\n--- Allowances & Prefetch ---");
        
        console.log(string.concat("Current ", sym0, " Allowance: ", formatDecimals(allowance0, dec0)));
        if (allowance0 >= bal0) {
            console.log(string.concat("  -> [OK] ", sym0, " Allowance sufficient."));
        } else {
            uint256 approveAmount0 = bal0 * APPROVE_MULTIPLIER;
            IERC20Metadata(token0).approve(POSITION_MANAGER, approveAmount0);
            console.log(string.concat("  -> [Prefetch] Approving ", sym0, ": ", formatDecimals(approveAmount0, dec0)));
        }

        console.log(string.concat("Current ", sym1, " Allowance: ", formatDecimals(allowance1, dec1)));
        if (allowance1 >= bal1) {
            console.log(string.concat("  -> [OK] ", sym1, " Allowance sufficient."));
        } else {
            uint256 approveAmount1 = bal1 * APPROVE_MULTIPLIER;
            IERC20Metadata(token1).approve(POSITION_MANAGER, approveAmount1);
            console.log(string.concat("  -> [Prefetch] Approving ", sym1, ": ", formatDecimals(approveAmount1, dec1)));
        }

        // 6. Reinvest
        IMinimalPositionManager.IncreaseLiquidityParams memory incParams = IMinimalPositionManager.IncreaseLiquidityParams({
            tokenId: tokenId,
            amount0Desired: bal0, amount1Desired: bal1,
            amount0Min: 0, amount1Min: 0,
            deadline: block.timestamp + 60 
        });

        (uint128 addedLiquidity, uint256 used0, uint256 used1) = manager.increaseLiquidity(incParams);
        vm.stopBroadcast();

        uint256 totalUsedBase = getTotalValueBase(used0, used1, sqrtPriceX96, baseTokenIndex);
        uint256 finalTotalBase = record.principalTotalBase + totalUsedBase;

        console.log("\n--- Reinvestment Successful ---");
        console.log(string.concat(sym0, " Reinvested: ", formatDecimals(used0, dec0)));
        console.log(string.concat(sym1, " Reinvested: ", formatDecimals(used1, dec1)));
        console.log(string.concat("Invested Value : +", formatDecimals(totalUsedBase, decBase), " ", symBase));
        console.log(string.concat("Liquidity (L)  : +", vm.toString(addedLiquidity), " (Math Unit)"));
        console.log(string.concat("New Total Value: ", formatDecimals(finalTotalBase, decBase), " ", symBase));
        console.log("====================================================");
    }
}
