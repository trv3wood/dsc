---
name: debug-rtl-by-model-substitution
description: Debug large SystemVerilog RTL designs by combining end-to-end golden comparison, hierarchical boundary traces, Verilator or Verilator --sc submodule simulation, and selective replacement with C/SystemC functional models. Use when an RTL design differs from a reference model, when the failing module must be isolated quickly, or when validating a research workflow based on recursively replacing RTL children with trusted models.
---

# RTL 分层模型替换调试

以端到端 golden 结果为根判据，先用边界 trace 找到第一个错误层级，再用 function model 替换可疑子模块做 A/B 验证。保持输入驱动、状态和握手真实，不构造依赖预期输出的预测器。

## 建立可信基线

1. 固定输入、配置、seed、时钟和复位，保存可重复运行的端到端失败用例。
2. 记录首差异位置、期望值、实际值和输出长度；不要只记录 pass/fail。
3. 用 slang 或等价编译器完整 elaborate 层级，确认端口宽度、参数和 filelist。
4. 盘点缺失的 RAM、FIFO、CDC、BIST 和 vendor primitive。验证其延迟、位序、读写冲突和 enable 语义。
5. 对 support 模型做敏感性测试。若改变合理语义会移动首差异，先解决适配不确定性。

不得把 lint、reset smoke 或部分前缀匹配表述为功能正确。

## 用 trace 缩小范围

从顶层输出向输入方向逐级增加观察点。每个观察点同时保存：

- 数据、有效位、ready/last/frame/line；
- 配置和影响状态转移的控制量；
- 事务序号、group/line/slice 序号；
- 首差异，而非仅最终累计差异。

优先选择算法边界和 support primitive 两侧。若 RAM 写入前后首差异相同，可排除该 RAM 及其后续纯传输路径；若上游正确而下游首次错误，则锁定两点之间的逻辑。

## 构建子模块 A/B Harness

1. 选择最靠近首差异且接口较小的子模块，不要一开始为所有顶层子模块建模。
2. 从完整 RTL 运行捕获该模块输入 trace，作为 replay stimulus。
3. 用 Verilator 单独编译 RTL 子模块；需要 SystemC 组合时使用 `--sc`，但不要把生成的 wrapper误称为 function model。
4. 为 C/SystemC function model提供与 RTL 相同的 adapter。显式处理 reset、状态、latency、valid/ready 和 backpressure。
5. 对同一输入 trace分别运行 RTL 和模型，比较边界事务。
6. 再把模型替换回完整系统，运行原端到端用例。

对无 ready 的算法流水线，可由 adapter缓存模型结果并按约定延迟输出。对 FIFO、RAM、仲裁和 CDC，优先保留 RTL或使用周期精确模型，不要用无时序函数替换。

## 解释替换结果

- RTL 子模块 replay 已错、模型 replay 正确、系统替换后通过：强证据指向该模块 RTL。
- 两个 replay 都正确、系统替换后通过：优先检查 adapter、边界时序或上游激励差异。
- 两个 replay 都错：检查模型、golden 映射和输入 trace，不得归因 RTL。
- 替换后仍错：继续沿首差异边界向上游移动或检查并行分支。

“替换后通过”只能先定位到模块行为或模块边界。继续比较内部状态或子模块，直到区分算法计算、bit packing、状态更新和握手错位。

## 递归拆分与交付

若可疑模块仍较大，对其子模块重复 trace、replay、替换流程。每轮保留：复现命令、seed/config、首差异、被替换层级、adapter 时序契约和结论强度。修复 RTL 后必须恢复真实子模块，重新运行端到端、子模块 replay、随机 backpressure 和至少一个不同 seed；最终结果不得依赖 force、绝对周期或 golden 数据注入 DUT。
