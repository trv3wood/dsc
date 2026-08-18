---
name: debug-rtl-by-model-substitution
description: >
  Agentic discipline for localizing and fixing RTL-vs-reference-model divergences by
  reusing the project's existing golden end-to-end scoreboard and boundary traces to find
  the first mismatch, escalating to value or cycle functional-model substitution only when
  algorithm-vs-boundary-timing isolation is required. Use when RTL differs from a reference
  model at output bytes, pipeline boundary, or upstream decision level, or when the first
  differing transaction must be localized and the fix re-verified under a different
  configuration. Reject predictors that consume golden output, absolute-cycle or
  configuration specialization, force injection, declaring a fix from a substituted baseline
  without restoring the real module, and treating lint/reset-smoke as functional correctness.
---

# RTL↔参考模型差分调试（agentic 纪律）

本 skill 是**可移植的调试纪律**，不定义任何项目专用格式。核心思想：复用项目已有的 golden
scoreboard 与边界打点定位首差异，而不是新建观察点或 harness。具体命令、打点、工具动词在各
项目的绑定文档里，见文末"项目绑定"。

## 调试回路（推荐顺序，可自由裁剪/重排）

每步都是资源不是门禁；模型可根据手头证据直接跳步（例如打点已指明模块时可跳过上溯步骤）。

1. **跑基线**：用项目的端到端 golden harness 生成参考结果并对拍 RTL。可换 seed/图案/配置。
   golden 输出逐字节一致是唯一端到端通过标准（具体字节数见项目绑定）。
2. **读首差异**：从仿真 stdout 抓 harness 的**第一条**失配（字节/事务级），记录 expected/actual，
   不要只看最终失配总数。
3. **上溯到边界**：用项目提供的"首个边界失配即停"开关，定位第一个失配的事务/group 序号与类型。
4. **对照参考 trace**：用参考模型导出的中间 trace（按事务记录）与 RTL 打点收敛到第一个差异层。
5. **读源码 → 假设 → 修 → 重验**：定位模块，读源码形成可证伪假设，修改，重跑。最终验收须换
   至少一个不同 seed/配置 + 随机 backpressure。
6. **记录证据**：每轮保留复现命令、seed/config、首差异位置、源码 file:line、EDA 工具交叉验证
   结果与结论强度。

可选检查：lint/elaborate 确认端口与 filelist；reset smoke 确认可复位。它们只证明可编译可复位，
**不等于**功能正确。

## 升级路径：function-model 替换（仅当需要）

当现有打点无法区分"算法实现错"还是"边界时序/握手错"、或需要可信上游/下游基线时，才用替换做
A/B。这是升级路径，不是默认流程。

- **value (function) model**：只复现算法输出的值 + 边界契约（经 adapter 补延迟），**折叠模块内部
  时序**。只能回答"值/算法对不对"，回答不了"时序对不对"。
- **cycle model**：逐周期复现 reset、状态、流水深度、valid/ready、仲裁与协议时序。
- **关键规则**：不要用 value model 替换你正在调时序的模块——那会消掉你要抓的时序 bug，替换后
  "通过"是假象。要么替换它的**邻居**建立可信上下游基线，要么给它建 cycle model。
- FIFO、RAM、仲裁、CDC 只能用 cycle model 或保留 RTL，不要用无时序函数替换。

### 四情形判定表（解释替换结果）

| 情形 | 结论 |
|---|---|
| RTL 子模块 replay 错、模型 replay 对、系统替换后通过 | 强证据指向该模块 RTL |
| 两个 replay 都对、系统替换后通过 | 优先检查 adapter、边界时序或上游激励差异——adapter 时序不对会伪装成修复 |
| 两个 replay 都错 | 检查模型、golden 映射和输入 trace，**不得归因 RTL** |
| 替换后仍错 | 沿首差异边界向上游移动或检查并行分支 |

"替换后通过"只能定位到模块/边界。继续比较内部状态或子模块，直到区分算法计算、bit packing、
状态更新和握手错位。

### adapter 纪律

- 显式处理 reset、state、latency、valid/ready、backpressure；不构造依赖预期输出的预测器。
- 对无 ready 的算法流水线，可由 adapter 缓存模型结果并按约定延迟输出。
- 生成 wrapper（Verilator `--sc`）是仿真 adapter，**不是** function model，不得混称。
- 时序保真度只需覆盖失败用例本身 + valid 密度扫描（连续事务/插空拍/边界），验证用 cycle-aligned
  边界事务比较，不是比值序列相同。

## 不变量（任何时候都不得违反）

- **根判据**：golden 输出逐字节一致是端到端通过的唯一标准；lint、elaborate、reset-smoke、部分
  前缀匹配都不是功能正确。
- **首差异**：始终收敛第一个失配（字节/事务/层），不用累计失配总数或前缀匹配代替。
- **工具缺失 = blocked**：任何工具未验证或缺失时如实标 blocked；不得假装可用，不得静默降级为
  文本搜索。
- **不得**构造依赖预期输出的预测器；**不得** force 内部信号；**不得**绝对周期/固定节拍特化；
  **不得** seed/pattern 特化；**不得**把 golden 数据注入 DUT 作为实现。
- **替换结论边界**：替换通过只能定位到模块/边界，不得宣称修复。
- **最终验收**：修后恢复真实模块，换至少一个不同 seed/配置 + 随机 backpressure 重验；结果不得
  依赖 force、绝对周期或 golden 注入。
- **证据纪律**：关键语义结论要有源码 `file:line` 依据 + EDA 工具交叉验证（仿真打点/trace/replay
  至少一种）。"只读代码不算验证"。

## 工具纪律

- 使用前先 `which`/版本 probe 验证工具存在与可用；缺失或未验证标 **blocked**，不得假装可用。
- 能力→工具映射、每个工具在本项目怎么调用，见项目绑定文档。
- 工具的 lint/elaborate/smoke 通过不等于功能正确。

## 项目绑定

各项目在各自文档里记录等价的具体命令、打点与工具动词，并在本节点名。

- **本项目（DSC 编码器）**：具体命令、RTL 打点词典、C trace 字段对照、function-model 替换
  target 表、工具与 blocked 判据，全部见 `tests/verilator/README.md` 的"调试操作手册"节；
  仓库 make 目标与规范见 `AGENTS.md`。
- **其他项目**：把 golden harness 命令、边界停表开关、打点/参考 trace 说明、工具动词写入对应
  项目文档，并在本节点名，即可复用本 skill 的纪律。
