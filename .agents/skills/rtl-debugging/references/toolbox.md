# OSS CAD Suite 调试工具箱

## 快速路由

| 问题 | 首选手段 | 产物 |
|---|---|---|
| 编译、位宽、未驱动、latch | `make rtl-lint`、`make rtl-slang` | elaboration 诊断 |
| payload 错误 | 最小 e2e scoreboard + 首 mismatch | 事务序号和边界 |
| 时序/握手错误 | `RTL_TRACE=1`，查看局部 VCD | 首分歧附近波形 |
| FIFO/CDC/状态机契约 | SVA + 小模块 SymbiYosys | proof 或最短 counterexample |
| 算法边界错误 | 独立 replay TB | 输入事务、期望输出、边界断言 |
| 可达性不明 | `FORMAL_TASK=cover` | witness trace |
| 死代码/覆盖盲区 | Verilator line/toggle coverage | 未覆盖区域，不是正确性证明 |

## 首分歧定位

比较同一语义事件的第 N 笔事务，不直接比较绝对周期。推荐边界依次为：顶层 payload、slice mux、
formatter muxword、VLC group、decision/rate transaction。每次只向上游移动一个稳定边界。

波形保留该事件前后的最小窗口，并包含：clock/reset、valid/ready/last、事务计数、FSM、读写指针、
边界配置和实际数据。跨时钟域要分别标记 source accept、synchronizer、destination commit。

## Formal 适用范围

优先证明局部契约：稳定 backpressure、FIFO 不溢出/不下溢、顺序保持、last 与 data 同事务、reset 后
状态、配置提交原子性。约束只描述环境协议，不能约束掉已知失败。先 `cover` 关键路径可达，再 `prove`；
失败时阅读最短反例并转成 simulation assertion 或 testcase。

复杂 C 算法不适合直接等价证明。把算法输入输出边界抽成小状态空间，或以冻结 trace 做 replay；
trace 只能提供输入/期望事务，不能注入 DUT 内部状态。

## 仓库约定

默认 `tests/verilator/rtl.f` 只含真实 RTL。临时产物放 `/tmp/dsc_*` 或忽略目录。标准 e2e TB 只保留
配置、激励、scoreboard、timeout 和结果摘要；一次性探针在实验结束后删除或转成独立 harness。
