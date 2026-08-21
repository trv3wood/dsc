---
name: rtl-debugging
description: Debug SystemVerilog RTL and C-model comparison failures with OSS CAD Suite, transaction-aligned simulation, waveforms, assertions, formal checks, and focused replay. Use for RTL regression failures, first-divergence localization, handshake/CDC/FIFO bugs, or choosing an effective RTL debugging tool.
---

# RTL 调试

目标是得到可复现的失效、最早的语义分歧和可证伪的根因假设，而不是累积打印或让某个
替换模型“通过”。遵守仓库 `AGENTS.md`；C model 是冻结的官方参考，不修改 golden 来适配 RTL。

## 工作方式

1. 先运行最小失败 case，记录配置、像素 seed、流控 seed、首个 mismatch、超时和 assertion。
2. 按 accepted transaction 或 produced transaction 的序号对齐 C model 与 RTL；事件对齐后才比较周期。
3. 从稳定模块边界向上游追踪首分歧。优先看 ready/valid、last、QP、状态提交和 FIFO 边界。
4. 用波形的小时间窗验证假设；用 assertion、focused replay 或 formal property 固化边界契约。
5. 做最小根因修复，重跑原 case、相邻边界测试及与修改风险匹配的回归矩阵。

证据通常依次使用：编译/诊断、语义导航、scoreboard 首分歧、局部波形、结构查询、assertion、
formal/replay。`$display` 只适合无法由这些证据表达的短期观测，不得继续堆入标准 e2e TB。

## 工具选择

- Verilator：重现、assertion、coverage、VCD；标准入口见 `tests/verilator/README.md`。
- slang：独立 elaboration、类型和层级诊断；始终使用当前真实 RTL filelist。
- Yosys/SymbiYosys：证明局部安全/活性边界，或生成最短反例；不要直接 formal 整个 encoder。
- GTKWave/FST/VCD：只截取首分歧附近信号，不把整份波形转录进上下文。
- `rg`：可靠的文本和连接关系兜底。若环境确实提供可工作的 LSP，再用定义/引用/hover 加速。

涉及 OSS CAD Suite、formal、波形和 replay 的具体策略，读取
[references/toolbox.md](references/toolbox.md)。需要评估 trusted model 替换实验时，读取
[references/model-substitution.md](references/model-substitution.md)。

## 不变量

- function model 的 PASS 只能缩小嫌疑边界，不能证明被替换 RTL 单独有错。
- 前缀一致、子模块 replay 通过、无输出或 timeout 均不等于 e2e PASS。
- overflow 常是上游事务错误的次生现象，先找最早错误写入/提交。
- 随机测试必须记录 seed；单个默认 seed 仅用于复现，不能作为充分回归。
- 调试结论应落为 testcase、assertion、cover 或 replay；不维护会漂移的逐提交修复流水账。

## 交付记录

报告最小失败命令、首分歧事务、关键证据、根因、补丁和回归结果。尚不能证明的推断明确标注，
不要把移动后的 mismatch 当作修复完成。
