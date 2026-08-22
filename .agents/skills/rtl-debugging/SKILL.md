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

## C model 与回归分层

- 将仓库指定版本的 C model 作为冻结 oracle。除非用户明确要求审计 model，否则不修改其源码，
  也不通过改 golden、放宽比较或选择性跳过 mismatch 来迁就 RTL。
- 区分“model 算出不同结果”和“model 无法生成结果”。若 model 因 RC buffer overflow、配置约束、
  输入缺失或进程异常而退出，该 case 应记为 **无有效 golden**，不能判为 RTL PASS 或 FAIL。
- 对无 golden 的扩展 case，先检查测试生成器和配置。调整自定义 RC 参数或使用 model 支持的自动
  参数生成方式；不得仅因保护检查触发就断言冻结 model 有 bug。
- 官方图像与官方配置优先承担 bit-exact 判定。合成 case 用于覆盖握手、气泡、背压、多 slice 和
  边界状态；其配置必须先通过冻结 model，才可进入 RTL 差异统计。
- 回归报告分开列出：PASS、RTL mismatch/timeout/assertion、golden 生成失败。保留每项复现命令，
  不把三类结果合并成笼统的“case 失败”。

修复取得进展时，先跑最小失败 case；提交前至少重跑已通过的哨兵 case 和受影响 profile。用户要求
全量回归时，执行仓库定义的全部 profile/case，并如实保留预存失败和无 golden 项，而不是只报告
本次改善的用例。首分歧后移或 mismatch 数下降属于阶段性证据；只有完整输出一致才是 e2e PASS。

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
- RTL 内部 overflow 与 C model 在 golden 生成阶段报告的 RC overflow 必须分开归因；后者首先是
  case/config 有效性问题。
- 随机测试必须记录 seed；单个默认 seed 仅用于复现，不能作为充分回归。
- 调试结论应落为 testcase、assertion、cover 或 replay；不维护会漂移的逐提交修复流水账。

## 交付记录

报告最小失败命令、首分歧事务、关键证据、根因、补丁和回归结果。尚不能证明的推断明确标注，
不要把移动后的 mismatch 当作修复完成。
