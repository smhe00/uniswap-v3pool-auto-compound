---------------- MODULE UniSwapV3RightSideStrategy ----------------

EXTENDS Naturals, Sequences

(* --- 系统常量 --- *)
CONSTANTS 
    T_DELAY,      (* 出界等待容忍时间 *)
    T_COOLDOWN    (* 警报解除后的观察时间 *)

(* --- 系统变量 --- *)
VARIABLES 
    state,          (* 当前主状态 *)
    price,          (* ETH 现货价格 *)
    tick_range,     (* 当前做市区间 [lower, upper] *)
    radar_signal,   (* 雷达传感器: "NORMAL", "DANGER", "UNKNOWN" *)
    tx_status,      (* 链上交易状态: "IDLE", "PENDING", "SUCCESS", "FAILED" *)
    balances,       (* 当前持仓: 记录 [WETH, USDC, NFT_Active] *)
    timer_oor,      (* OOR 倒计时记录 *)
    timer_cooldown  (* 冷静期倒计时记录 *)

vars == <<state, price, tick_range, radar_signal, tx_status, balances, timer_oor, timer_cooldown>>

(* --- 辅助宏定义 (Macros) --- *)
PriceInRange == price >= tick_range[1] /\ price <= tick_range[2]

(* --- 初始化状态 (Initial State) --- *)
Init ==
    /\ state = "S_COMPOUNDING"
    /\ radar_signal = "NORMAL"
    /\ tx_status = "IDLE"
    /\ price = 2000                  \* 【修改 1】给 TLC 一个具体的初始价格
    /\ tick_range = <<1900, 2400>>   \* 【修改 2】给 TLC 一个具体的初始区间
    /\ balances = [WETH |-> 0, USDC |-> 0, NFT_Active |-> TRUE] \* 【修改 3】完整初始化 Record (字典)
    /\ timer_oor = 0
    /\ timer_cooldown = 0

(* --- 环境模拟器 (Environment Stimulus) --- *)

\* 模拟市场价格的暴力波动 (让价格在几个关键的边界点反复横跳)
\* 动态价格探测器：永远在当前区间的内部、边缘和外部进行随机试探
Market_Move ==
    LET candidates == { 
          tick_range[1] - 100,  \* 永远试探跌破下界
          tick_range[1],        \* 永远试探踩在下界边缘
          (tick_range[1] + tick_range[2]) \div 2, \* 永远试探区间正中心
          tick_range[2],        \* 永远试探踩在上界边缘
          tick_range[2] + 100   \* 永远试探涨破上界
       } 
    IN
    \* 【极其关键的结界】：只允许价格在 1000 到 4000 之间漂移！
    /\ price' \in {p \in candidates : p >= 1000 /\ p <= 4000} 
    /\ UNCHANGED <<state, tick_range, radar_signal, tx_status, balances, timer_oor, timer_cooldown>>

\* 模拟雷达预警信号的随时突变
Radar_Change ==
    /\ radar_signal' \in {"NORMAL", "DANGER"}
    /\ UNCHANGED <<state, price, tick_range, tx_status, balances, timer_oor, timer_cooldown>>

\* 模拟时间的流逝 (Clock Tick)
Time_Tick ==
    /\ timer_oor' = IF state = "S_OOR_WAITING" /\ timer_oor <= T_DELAY THEN timer_oor + 1 ELSE timer_oor
    /\ timer_cooldown' = IF state = "S_COOLING_DOWN" /\ timer_cooldown <= T_COOLDOWN THEN timer_cooldown + 1 ELSE timer_cooldown
    /\ UNCHANGED <<state, price, tick_range, radar_signal, tx_status, balances>>
    
(* --- 动作定义 (Actions) --- *)

\* 动作 1: 环境异动 (传感器失效)
API_Failure ==
    /\ radar_signal' = "UNKNOWN"
    /\ state' = "S_API_UNKNOWN"
    /\ UNCHANGED <<price, tick_range, tx_status, balances, timer_oor, timer_cooldown>>

\* 动作 2: 出界检测 (Out of Range Trigger)
Trigger_OOR ==
    /\ state = "S_COMPOUNDING"
    /\ radar_signal = "NORMAL"
    /\ ~PriceInRange
    /\ state' = "S_OOR_WAITING"
    /\ timer_oor' = 1  \* 启动计时器
    /\ UNCHANGED <<price, tick_range, radar_signal, tx_status, balances, timer_cooldown>>

\* 动作 3: 假突破自愈 (Self-Healing) -> [修复漏洞 1]
Self_Heal ==
    /\ state = "S_OOR_WAITING"
    /\ radar_signal = "NORMAL"
    /\ PriceInRange
    /\ state' = "S_COMPOUNDING"
    /\ timer_oor' = 0  \* 清零
    /\ UNCHANGED <<price, tick_range, radar_signal, tx_status, balances, timer_cooldown>>

\* 动作 4: 触发紧急撤离 (Emergency Evacuate) -> [修复漏洞 3]
Emergency_Evacuate_Request ==
    /\ state \in {"S_COMPOUNDING", "S_OOR_WAITING"}
    /\ radar_signal = "DANGER"
    /\ tx_status = "IDLE"
    /\ tx_status' = "PENDING"
    /\ UNCHANGED <<state, price, tick_range, radar_signal, balances, timer_oor, timer_cooldown>>

\* 动作 4: 触发紧急撤离确认
Emergency_Evacuate_Confirm ==
    /\ tx_status = "PENDING"
    /\ radar_signal = "DANGER"
    /\ state' = "S_DEFENSIVE_HOLD"
    /\ balances' = [WETH |-> 1, USDC |-> 1, NFT_Active |-> FALSE]
    /\ tx_status' = "IDLE"  \* 【修复】只留这一个状态赋值，重置交易状态
    /\ UNCHANGED <<price, tick_range, radar_signal, timer_oor, timer_cooldown>>

\* 动作 5: 警报降温观察
Start_Cooldown ==
    /\ state = "S_DEFENSIVE_HOLD"
    /\ radar_signal = "NORMAL"
    /\ state' = "S_COOLING_DOWN"
    /\ timer_cooldown' = 1
    /\ UNCHANGED <<price, tick_range, radar_signal, tx_status, balances, timer_oor>>

\* 动作 6: 原子重组与再入 (坚持绝对右侧建仓原则)
Rebalance_And_Zap_Confirm ==
    /\ \/ (state = "S_OOR_WAITING" /\ timer_oor >= T_DELAY)
       \/ (state = "S_COOLING_DOWN" /\ timer_cooldown >= T_COOLDOWN)
    /\ radar_signal = "NORMAL"
    /\ tx_status = "IDLE"     
    /\ state' = "S_COMPOUNDING"
    /\ balances' = [WETH |-> 0, USDC |-> 0, NFT_Active |-> TRUE]
    \* 永远只在当前价格的右侧 (上方) 建立新区间
    /\ tick_range' = <<price + 50, price + 550>> 
    /\ timer_oor' = 0
    /\ timer_cooldown' = 0
    /\ tx_status' = "IDLE"    
    /\ UNCHANGED <<price, radar_signal>>

(* --- 状态转移步进 (Next State) --- *)
Next ==
    \/ API_Failure
    \/ Trigger_OOR
    \/ Self_Heal
    \/ Emergency_Evacuate_Request
    \/ Emergency_Evacuate_Confirm
    \/ Start_Cooldown
    \/ Rebalance_And_Zap_Confirm
    \* 还需要包含时间流逝推进 (TickTimer) 等环境变量推进，此处省略以聚焦核心业务逻辑
    \/ Time_Tick
    \/ Market_Move
    \/ Radar_Change

(* --- 安全性不变量约束 (Invariants) --- *)
\* 约束 1: 只要在做市状态，资产必定在 NFT 中
Safety_Compounding == 
    state = "S_COMPOUNDING" => balances.NFT_Active = TRUE

\* 约束 2: 在防御状态时，必须持有现货，NFT 必须销毁
Safety_Defensive == 
    state = "S_DEFENSIVE_HOLD" => balances.NFT_Active = FALSE

\* 约束 3: 只要雷达断联，绝对不允许处于交易 Pending 状态
Safety_APIDown == 
    state = "S_API_UNKNOWN" => tx_status /= "PENDING"

=============================================================================
