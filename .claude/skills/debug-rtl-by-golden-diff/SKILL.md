---
name: debug-rtl-by-golden-diff
description: >
  Agentic discipline for localizing and fixing RTL-vs-reference-model divergences.
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

## 推荐工具

下表是**通用推荐**（工具→能力→何时用），不是门禁；缺失或未验证的工具按"工具纪律"标
**blocked**，换用其他路径即可。各工具的具体版本、在本项目的调用动词与 blocked 判据，一律以
各项目绑定文档的"外部工具总结"表为**单一事实来源**——该表是快照、状态会漂移，使用前先 probe。

| 工具 | 能力 | 推荐场景 |
|---|---|---|
| verilator | 编译/仿真/波形 | 主仿真器：跑端到端基线、lint、smoke、出 VCD trace |
| verilator_coverage | line/toggle 覆盖率分析、annotate、合并 | 定位盲区、量化哪些路径未被触发；达标≠正确 |
| slang | SV elaborate/lint | 改端口/连接后快速确认 hierarchy 完整、可复位 |
| slang-server | `.sv/.svh/.v/.vh` LSP | 跨文件跳转/引用 RTL 信号，定位定义与使用点 |
| clangd | C 模型 LSP | 参考模型与 function model 的跳转/引用 |
| gtkwave | VCD 波形查看 | 时序/握手类差异；配 `--trace` 产物观察对齐 |
| gcc/g++ | C 模型 + function model DPI | 构建参考模型与替换基线 |
| make | 构建 | 统一入口；不要绕过 target 手搓编译命令 |
| python3 | golden 向量生成、回归、trace 解析 | 换 seed/图案、批量回归、把 C trace 转测试向量 |
| verdi（可选） | 商业波形/调试 | 若本机可用可替代 gtkwave；未装如实标 blocked，不阻塞调试 |

> 定位盲区用覆盖率、看时序用波形、改结构后先 lint/elaborate——但三者只证明"可编译/可触发/
> 可复位"，功能正确仍以 golden 逐字节一致为准（见"硬约束"）。


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

- 显式处理 reset、state、latency、valid/ready、backpressure；不构造依赖预期输出的预测器
  （见"硬约束"）。
- 对无 ready 的算法流水线，可由 adapter 缓存模型结果并按约定延迟输出。
- 生成 wrapper（Verilator `--sc`）是仿真 adapter，**不是** function model，不得混称。
- 时序保真度只需覆盖失败用例本身 + valid 密度扫描（连续事务/插空拍/边界），验证用 cycle-aligned
  边界事务比较，不是比值序列相同。

## 硬约束（违反则调试结论无效，任何时候不得触碰）

以下任何一条都不能违反；违反后的"修复/结论"一律视为无效，不得宣称通过：

- **验收唯一标准 = golden 逐字节一致**。lint、elaborate、reset-smoke、覆盖率达标、部分前缀
  匹配都不是功能正确。
- **首差异**：始终收敛第一个失配（字节/事务/层），不用累计失配总数或前缀匹配代替。
- **不得构造依赖预期输出的预测器**；**不得**把 golden 数据注入 DUT 作为实现；**不得**用
  force 内部信号作为修复。
- **不得用特化作验收**：修复/结论不得依赖特定 seed/pattern、绝对周期或固定节拍，也不得依赖
  替换模块未恢复。
- **替换结论只到边界**：替换后的"通过"只能定位到模块/边界，不得宣称修复。
- **最终验收**：恢复真实模块后，换至少一个不同 seed/配置 + 随机 backpressure 重验。
- **工具缺失 = blocked**：工具未验证或缺失时如实标 blocked，不得假装可用、不得静默降级为
  文本搜索。
- **证据纪律**：关键语义结论要有源码 `file:line` 依据 + EDA 工具交叉验证（仿真打点/trace/replay
  至少一种）。"只读代码不算验证"。

## 诊断纪律（默认遵循；只作定位手段，不作验收标准）

- **固定节拍/seed 的 replay 是合法诊断手段**：固定 `VALID_PERIOD`、固定 seed 的单模块 replay、
  边界 trace 对拍等，用于定位差异层，可以用。规则是**不得以它作验收**、不得让修复依赖固定节拍
  或特定 seed。
- **覆盖率用于定位盲区**：量化哪些路径未被触发、为向量设计提供证据；覆盖率达标不等于功能
  正确。
- **lint/elaborate/smoke**：只证明可编译可复位，不等于功能正确。

## 工具纪律

- 使用前先 `which`/版本 probe 验证工具存在与可用；缺失或未验证标 **blocked**，不得假装可用。
- 能力→工具映射、每个工具在本项目怎么调用、工具缺失判定，见项目绑定文档的"外部工具总结"节。
- 覆盖率/lint/elaborate/smoke 的定位用法与边界见"诊断纪律"。
