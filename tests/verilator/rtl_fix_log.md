# RTL 修复记录（4b1ebbc → HEAD）

本文件记录 `verilog_dsc/` 从早期基线提交
`4b1ebbc dc36bb74017dbbf8f024bd9b4ac4f390`（第 4 个提交，
"model: add deterministic test image generation"）到当前 `HEAD`
（`525b9f8 rtl: fix line-end QP rollback, pass seed 0x1234 e2e`）之间
的全部 RTL 改动与对应缺陷。此区间跨越 18 个提交、23 个文件、
+1451/−544 行，目标是让 RTL 与 C reference model 在固定用例上逐字节一致。

验证基线可对照 `tests/verilator/README.md` 的缺陷定位记录；本文件按
子系统给出与早期版本对比的修复清单，不再逐提交复述排查经过。

## 基线说明

- 早期版本（`4b1ebbc`）：flatness 只有左窗口、BP 未实装、码控/打包/VLC
  存在多处语义偏差，端到端无法对拍。
- 当前版本（`HEAD`）：96×108、RGB 8bpc、12bpp、单 slice、4 pixel/cycle、
  48-bit、无 backpressure 用例下，完整 RTL（不替换任何子模块）与 C model
  输出 15552 字节逐字节一致；flatness replay、bp replay 0 失配。

## 1. Flatness 生成与流水

文件：`dsce_flat_check.sv`、`dsce_flat_flags.sv`

- **`flat_check` 整块重写**。原实现把 Check 1/2 错算成目标 group
  左侧窗口，缺少 C model 要求的向右两组 look-ahead；现按
  「目标组末像素 + 下一组」和「后续两个完整组」计算双窗口，
  并修复行尾 padding 状态跨行残留。
- **`flat_flags` 流水与型别修复**：
  - stage 0 的 `last` 被 stage 3 清零覆盖、提前 flush；
  - `valid` 与 group/check-diff 必须走同一级流水（原在 stage 3
    采样当拍实时输入，连续 valid 时读到变化后的数据）；
  - `group_flatness_type` 改用包定义 `kDSC_VERY_FLAT`/`kDSC_SOMEWHAT_FLAT`
    （编 2/3）而非字面 `1/2`；
  - 有效输出不再赋初始化值，真正发出非零 flags（原 3349 个有效事务
    非零 flag 数为 0）；
  - 行末 flush 强制 very-flat **只作用于当前组**（供码控的 flat QP），
    不泄漏成下一行的 next/send flatness 状态。

## 2. Block prediction

文件：`dsce_bpvector.sv`、`dsce_sad.sv`

- **`bpvector` 完整实装 `BlockPredSearch`**。原实现无条件清零
  `dsc_use_bp`、vector 不接入预测器（residual 固定取上一行固定偏移），
  是首个端到端首差（group 37）的根因。重写内容：
  - 前一行重建改绝对像素位置数组 `i_prev_arr`（原 6 像素移位寄存器
    窗口重复/错位，无法提供 x-6..x+2 的正确 9 像素窗口）；
  - SAD 窗口 `max(0,x-6)..x+2` 截断，`p<=candidate` 用中点
    （luma=`1<<(bpc-1)`，chroma=`1<<bpc`）；
  - 候选扫描运行最小值、平局保留小索引（`i_bpsad[0]` 为 MAP 基线），
    替代原决策树（平局偏好大索引）；
  - `use_bp=n` 门控 `line>0 && bpCount>=3 && lastEdgeCount<3`，
    行尾清零在 use_bp 之后，行尾组仍能使用更新后的计数；
  - 当前组 x 用 `i_cur_x`（`i_hpos` 已推进到下一组），修正 SAD/edge
    使用错误 x；
  - 残差符号修正（`dsce_compute_residual` 参数序为 predict, orig）。
- **`dsce_sad`**：每个分量位移 `cpntBitDepth-7`（YCoCg 下色度位深
  `bpc+1`），修复 `abs_diff>>shift` 被 6 位截断为 0、SAD 恒 0。

## 3. 码控

文件：`dsce_rate.sv`、`dsce_rate_adjust.sv`

- **bit-save 分支漏 `min_qp` 下界**：`7'b????100` 原为
  `dsce_min_qp(+2, adj_max)`，现为 `dsce_clamp_qp(+2, min, adj_max)`；
  当 prevQp=1、min_qp=5 时原输出 3 而非 5。
- **暴露 next-QP 供 flatness 同沿对齐**：新增 `dsc_qp_valid_next`、
  `dsc_primary_qp_next`，`dsce_rate_adjust` 成对选择，修复 flatness
  group 35 在沿前只能看到旧 QP 的问题。
- **行末 QP 回退一级**（seed `0x1234` 的关键修复）：
  - C model 中 `primaryQp(G)=RateControl(G-1) 提交后的 stQp(G-1)`，
    prevQp 滞后 stQp 一组；
  - 行末 flush 使下一行首组 fd 延后到行末组提交之后，读到 `stQp(L-1)`，
    而 C model 期望 `stQp(L-2)`；
  - `dsce_rate` 新增 `dsc_primary_qp_prev`（提交沿保留上一次值），
    `dsce_rate_adjust` 在 `i_orig_is_flat` 且行末 QP 未达 range 上限时
    回退 primary/prev QP。A/B 验证：还原三个 RTL 文件后 seed `0x1234`
    失配 5647/15552 字节，带修复则逐字节一致。
- **行末强制 flat QP 门控**：C model 用
  `primaryQp < rc_range_parameters[14].range_max_qp` 门控行末强制 flat
  QP；RTL 新增 `cfg_rc_range_max_qp_14`（正确取 `[10:6]`）成条件应用，
  不再无条件压到 very_flat_qp。

## 4. 打包链

文件：`dsce_muxword.sv`、`dsce_format_buffer.sv`、`dsce_format.sv`、
`dsce_stream_fifo.sv`

- **`muxword` 丢弃 `size>=10` 的片段**：RTL luma 把 C 的 1+4+5 位片段
  合并为单个 10 位片段，而两个 case 只处理移位量 1-9，`default` 丢弃数据
  （首差在 bit 6833 / word 142）；移位量上限扩展到 16。
- **muxword slice 结束不发射尾部部分字**：最后一行部分字留在 buffer 未
  flush，且直接 byte-swap 的填充位在头部、与 reference shifter 语义相反。
  新增 `dsc_slice_last_in`（`dsce_format` 按行尾计数检测最后一行），部分
  字/余量左移对齐到高 48 位后按整字字节序输出，使填充位位于末字节末尾。
- **`format_buffer` 缺最后 chunk 零填充**：输出停在 2583 个 muxword
  （15498 字节），与 `chunk_size×slice_height`=15552 差 54 字节。新增
  目标字数跨时钟域同步 + `kRS_DATA_PAD` 状态，AXI 域写计数连续 64 拍
  稳定判定编码完成后再补零。
- **`format` 接入真实 flatness 语法**：原把 rate/format flatness 输入
  常量绑零；现接受 `dsc_flatness_in` 并检测 slice 最后一个 group。
- **`stream_fifo`**：FIFO 满时若本拍消费者取走旧条目，写端可安全复用
  该槽位（消除 bubble 期的多余节拍）。

## 5. VLC

文件：`dsce_vlc.sv`

- 接入真实 `dsc_flatness_in`（原声明但未使用，flat flags 全 0 导致
  flatness 语法不可见）。
- **PipeS3 误用实时组合 `dsc_ich_selected_in`**：PipeS0-S2 在 valid 拍
  及之后 1-2 拍求值，PipeS3 在 valid 后 3 拍；真实 ICH 的组合输出在
  `dsc_predict_valid_in` 回落后立即归零，导致 ICH 组第三个残差不被抑制、
  产生多余片段并错位 fragment/muxword 计数。PipeS3 改用与 PipeS1/S2
  一致的寄存 `i_ich_selected_in`。
- PipeS0 完整语法，ICH 时与 index 合并，保证无 ready 接口的突发吞吐；
  零长度 valid 边界语义与四拍调度契约（回退实验中验证）。

## 6. ICH / MPP / 决策链

文件：`dsce_ich.sv`、`dsce_ich_candidate.sv`、`dsce_ich_decision.sv`、
`dsce_decision.sv`、`dsce_mpp.sv`、`dsce_predict.sv`

- **`dsce_mpp` 输入未与 valid 同拍锁存**：延迟后读取实时 right/group，
  使 predictor 从应有的 258 变为 262（group 37 的首个预测边界差异）；
  改为在 valid 当拍锁存计算结果并随 valid 流水。
- **`dsce_ich_candidate`**：新增组合 `dsc_ich_hit_current`（当前事务命中，
  供 mode decision），代价在预测结果到达后组合计算，结果寄存一级对齐
  历史表反馈；避免寄存输出在同一事务内仍保留上一组的 hit。
- **`dsce_decision`**：右像素组合计算与行末锁存值分离；重建反馈不反向
  参与当前 ICH 候选代价；行末间隙用 pd 沿锁存的末像素输出稳定值；
  ICH 只影响最终模式标志，不参与预测像素/残差生成。
- **`dsce_ich` / `dsce_ich_decision`**：用连续赋值跨模块直连 ICH 选择，
  消除组合块之间的 delta 延迟。
- **`dsce_predict`**：穿线上一组重建反馈。

## 7. 切片与 support

文件：`dsce_slice.sv`、`dsce_linemem.sv`

- **`dsce_slice` flatness 行尾突发节拍恢复**：行尾 flush 会突发输出，
  而 prediction/重建反馈/MMAP 要求每四拍一个 group；用深度 16 FIFO 缓存
  完整 flatness 事务并按四拍间隔发送，无 overflow，恢复下游事务契约。
- **flatness 与 prediction 按 valid 对齐**：不依赖 group 间固定空拍数
  （原固定周期 replay 掩盖了问题）。
- **ICH 连接加 `!i_last_pd` 门控**：行末强制 VERY_FLAT 不流入
  `dsc_ich_next_is_very_flat`（C model 的 `IchDecision` 对行末组因
  `hPos+1>=sliceWidth` 提前返回非 flat）。
- **行末强制 flat QP 不破坏 bit-save**：DSC 1.2 行末强制 flat 发生在
  RateControl 之后，不应清除当前行已建立的 bit-save 状态。
- **`dsce_linemem`**：读延迟参数化（默认 1 拍，`DSC_LINEMEM_ASYNC_READ`/
  `DSC_LINEMEM_TWO_CYCLE_READ` 宏切换 0/2 拍），仅用于排除 support
  RAM 假设，非默认实现。

## 8. A/B 用 function-model 包装（不参与综合）

新增端口等价替换件，DPI 对接 `tests/verilator/model/*.cpp`，支撑
`rtl-e2e-*-model` 系列做模块级隔离定位：

- `dsce_bpvector_function_model.sv`（BP search/predict 黑盒）
- `dsce_ich_function_model.sv`（ICH history/candidate/decision）
- `dsce_mpp_function_model.sv`（midpoint predictor）
- `dsce_vlc_function_model.sv`（完整 VLC 发射链）

## 关键提交映射

| 提交 | 主题 |
|---|---|
| `d6f8913` | flatness lookahead 修复与 VLC 隔离 |
| `55f48b1` | rate bit-save QP clamp、muxword 大片段、slice 末 flush |
| `0255421` | next-QP 与 flatness 事务对齐 |
| `d12aad4` | 真实 `dsce_bpvector` block prediction |
| `4a512cf` | ICH 行末、VLC PipeS3 时序、rate flat-QP 门控 |
| `86ab05b` | right pixel 计算 |
| `525b9f8` | 行末 QP 回退（seed 0x1234 端到端 PASS） |

## 验证状态

- `make rtl-e2e`（seed `0x445343`）：15552 字节逐字节一致。
- `make rtl-e2e GOLDEN_SEED=0x1234`：15552 字节逐字节一致；
  仅 ssp0 的 VLC fragment 粒度差异（`010000`+`030001`→`040001` 等，
  等价位流，不影响打包字节）。
- `rtl-flatness-replay`：3456 groups 逐事务 0 失配。
- `rtl-bp-replay`：use_bp/vector/predict/residual 全 0 失配。
- 未覆盖：随机 backpressure、输入空泡、RGB/YUV 其他位深/采样、
  DSC 1.1、真实 SRAM 延迟签核。

## 多 slice 交织压测（未收敛，已知缺陷）

多分辨率/多 slice RTL 对拍（`tb_dsc_e2e_multi.sv` + `generate_golden.py` 参数化
`--slice-width/--slice-height`）暴露两个 RTL 层面缺陷，单 slice 基线程零回归
（`make rtl-e2e` 与多 slice tb 均 PASS）：

1. **`dsce_format_buffer` 不按 chunk 打 last → slice_mux 从不切换 slice**。
   原实现一次输出整个 slice 的 muxword 流，`axi_last_out` 在 chunk 边界恒低，
   `dsce_slice_mux` 的 `i_slice_select` 因此停在 slice0，多 slice 输出为
   slice 顺序而非 DSC 标准的 chunk 交替。已在 `dsce_format_buffer.sv` 加入
   **多 slice 门控的 chunk 边界 last**（`slices_per_line>1` 时每输出
   chunk_size/6 个 word 组合拉高 `axi_last_out` 并暂停等待 slice_mux 轮询；
   单 slice 时行为与原实现完全一致），slice_mux 现正常切换（ms2 实测 138 次）。
   该修复已在仓库中，单 slice 回归通过。

2. **`dsce_partition` 跨行轮换 slice→processor，processor 输出流混多个 slice 列**。
   `dsce_partition` 的 `i_slice_select` 在行末轮换且跨行延续（不随 `axi_line_in`
   重置），导致同一 processor 的连续行处理不同 slice 列，其 format 输出流与
   C 模型"每行 slice0..N 顺序"错位（ms2 首失配位于 chunk 边界后的第 7 字节）。
   尝试在行首重置 select 使 processor 固定 slice 列，但引入 line0
   slice-buffer 超时（时序敏感），已回退，**该层面修复未收敛，列为专项**。

   ms2 现状（可复现）：`partition_v=1296/1296`（像素正确分配）、
   `last_in=69/69`、`select_chg=138`（交织已切换）但 `top_mis=13337`（顺序错位）。
   修复方向：让 partition 每行将 slice 列固定映射到 processor（spl≤pSPC 时），
   spl>pSPC 时行内回绕复用，并保证行末 slice-buffer 读侧时序。
   
结论：部分缺陷确实修复了，但不能认定 `4b1ebbc → c4d0557` 已形成通用、完整的 RTL 修复。当前证据只足以证明固定的 8bpc RGB、单 slice、无 backpressure 用例正确。

主要问题按严重度如下。

- 高：多 slice 仍未修复。`dsce_partition` 的 `i_slice_select` 在 slice 结束后持续轮换，行首只清 `i_slice_count`，没有恢复 slice 列到 processor 的固定映射，见 [dsce_partition.sv](/home/zys/Project/dsc/verilog_dsc/dsce_partition.sv:106)。实测 `make rtl-e2e-multi MULTI_CASE=ms2` 在 byte 7 首差，`top_mis=13337`，输出 13440/15552 bytes。最新提交只让 `slice_mux` 轮换起来，并未修正流的归属和顺序。

- 高：新 BP 实现只对当前 8bpc RGB 用例成立。边缘阈值为 `32 << (bpc-8)`，但差值先被 `bp_mad()` 饱和到 6 bit，再与 `edge_threshold[5:0]` 比较，见 [dsce_bpvector.sv](/home/zys/Project/dsc/verilog_dsc/dsce_bpvector.sv:163)。当 bpc=9/10/12 时阈值低 6 位为 0，几乎所有非零差值都会被判为 edge。此外，非 RGB 模式下 chroma midpoint 仍固定为 `1 << bpc`，而不是对应分量位深的中点，见同文件第 110 行。现有生成器固定 8bpc RGB，因此完全覆盖不到这两个问题。

- 高：format buffer 的长度修复含配置和容量错误。`i_dsc_target_words` 在 `dsc_pps_update` 同一沿使用旧的 `i_bits_per_component`，见 [dsce_format_buffer.sv](/home/zys/Project/dsc/verilog_dsc/dsce_format_buffer.sv:213)。由于 PPS 更新是单拍脉冲，首次配置 12bpc 时仍按 6 bytes/word 计算，而实际数据路径使用 8 bytes/word。目标字数和写/输出计数又都只有 16 bit，大尺寸 slice 会溢出；因此日志中的多分辨率/4K能力不能由该实现支持。

- 中：最新 chunk-interleave 补丁不具备完整的流控语义。`axi_last_out` 组合依赖 `axi_tready_out`，且 chunk boundary 只在 `kRS_DATA_READY` 判断，`kRS_DATA_PAD` 零填充阶段不会产生 chunk `last`，见 [dsce_format_buffer.sv](/home/zys/Project/dsc/verilog_dsc/dsce_format_buffer.sv:149)。随机 backpressure 和需要 chunk padding 的多 slice 流仍没有可信保障。

- 中：BP 验证链目前不可重复。`make rtl-bp-capture` 启用 ICH function model 后，testbench 仍直接引用真实 `dsce_ich_candidate_inst` 层级，见 [tb_dsc_e2e.sv](/home/zys/Project/dsc/tests/verilator/tb_dsc_e2e.sv:575)，导致 22 个 elaboration error。现有 `rtl-bp-replay` 能通过，是因为仓库里已有旧 capture 文件，不能证明当前 HEAD 可重新生成相同证据。

- 低：可综合 RTL 中残留了调试硬件。MPP 中有多个持续计数的 32-bit `int` 寄存器，见 [dsce_mpp.sv](/home/zys/Project/dsc/verilog_dsc/dsce_mpp.sv:74)；ICH candidate 还有 `$test$plusargs/$display` 和调试计数器，见 [dsce_ich_candidate.sv](/home/zys/Project/dsc/verilog_dsc/dsce_ich_candidate.sv:216)。此外 Verilator 对新 BP 组合逻辑报告了 inferred latch，说明尚未达到综合签核状态。

本次复跑结果：

- `make rtl-e2e`：PASS，15552 bytes 零失配。
- `make rtl-e2e GOLDEN_SEED=0x1234`：PASS，15552 bytes 零失配。
- `make rtl-flatness-replay`：PASS，3456 groups 零失配。
- `make rtl-bp-replay`：PASS，3456 groups 零失配，但使用已有 capture。
- `make rtl-bp-capture`：FAIL，层级引用导致 elaboration error。
- `make rtl-e2e-multi MULTI_CASE=ms2`：FAIL，13337 个顶层字节失配。

因此，更准确的结论是：flatness、MPP/ICH/VLC 时序、QP 对齐和 BP 的核心方向已经让两个固定单-slice用例真正通过；但 BP 多位深/非 RGB、format buffer 长度、backpressure 和多 slice 仍未修复，当前不应把 [rtl_fix_log.md](/home/zys/Project/dsc/tests/verilator/rtl_fix_log.md:1) 描述为“RTL 缺陷已整体修复”。


## 多 slice 缺陷定位修正(2026-08-18,已收敛证据)

此前把 ms2 首因列为 `dsce_partition` 列映射(上文第 2 条)。本轮用逐 processor 捕获
`i_axi_muxword_out`(tb 写 `proc0/proc1_muxwords.hex`)对拍 C model 的
`c_mux_trace.txt` per-slice 流,修正定位:

- **partition 列分配正确**:两个 processor 各收到自己的整条 slice 列
  (`part_valid=1296/1296`,像素未混),mux 切换正常(`select_chg=138`)。
- **首个差异在 `dsce_format_buffer` 的 chunk 边界多读**:
  - proc0 的 chunk0 = golden slice0 chunk0(12 字逐字一致),chunk0 后第 13 字起
    与 golden slice0 错位 1 字,且每个 chunk 边界后持续错位;
  - `fmt_boundary.log` 显示 chunk 边界拍 `raddr` 从 12 跳到 14,即同一拍
    `i_axi_ren` 驱动两次 RAM 读(多读一个已写满的 word)。
  - 根因:`i_axi_chunk_boundary` 判"本字是 chunk 尾"后转 `kRS_XMIT_DELAY` PAUSE,
    但组合 `i_axi_ren` 在该边界拍仍因 `axi_tvalid_out&&axi_tready_out` 为真而拉高,
    推进两个地址。
- 尝试收紧 `i_axi_ren` 为"仅 READY 真握手才读"时,proc0/1 的 `i_axi_out_count`
  与 72 字节/chunk 对齐,方向正确;但引入 ms2 另一处停摆(`mux` 停在
  `sel=1 kSST_STALLED`、`g1 fmt_state=4 kRS_DATA_PAD`、`fmt_raddr/waddr=106`),
  即 chunk 边界 `axi_last_out` 时机与 slice_mux 状态机配合仍未闭合。该收紧已回退,
  保持原 RTL 语义避免引入回归。

**结论**:multi-slice 收敛需把 `dsce_format_buffer` 的 chunk-last 时机与
`dsce_slice_mux` 的 PRIME/LAST 状态机齐调(单 slice 路径不受影响)。本轮新增诊断探针
(proc muxword 捕获、STALL watchdog、DET 进展、fmt_boundary/mux_stream 离线 dump)
保留在 `tb_dsc_e2e_multi.sv`。

### 本轮保留的 RTL SVA/断言资产(Phase 5,单 slice 回归零违例)

- `dsce_partition`:`assert property ($onehot(i_slice_select))`(多 slice 轮转映射
  单热不变式)。
- `dsce_rate_adjust`:primary/prev QP ≤ 31 范围断言。
- `dsce_stream_fifo`:muxword FIFO write-into-full 断言。
- `dsce_bpvector`:修复 `int candidate` 自动变量被静态初始化引用的 slang 错误
  (语义不变,纯 lint 修复,`make rtl-slang` 2 errors → 0)。
- 全部经 `rtl-e2e`(默认 + 0x1234)、`rtl-flatness-replay`、`rtl-smoke`、`rtl-slang`、
  `rtl-lint` 复跑 PASS / 0 errors。

### 多 slice 专项(2026-08-18 二次收敛:结构已通,剩内容/大 slice 容量)

**本轮结构修复(已提交 b0b4fa3,ms2 从 13440 卡死 → 15552 全帧、每 slice 1296 words):**

1. `dsce_format_buffer` 去掉 chunk 边界显式 PAUSE(原清零 tvalid 导致 1 拍 RAM
   读延迟里的下一个 word 丢失,每 chunk 丢 1 字)。改为留在 kRS_DATA_READY 靠 mux
   背压门控(ren 在 tready=0 时自然为 0、raddr 停住、RAM 保持),axi_last_out 仍通知
   mux 切换。同时 axi_last_out 不再由 transient kRS_DATA_LAST(编码器追平)触发
   (否则首字误发 last 让 mux 提前切 slice),并补 kRS_DATA_PAD 的 chunk 边界 last
   (否则某 slice 提前 pad 时 mux 卡死)。
2. `dsce_slice_mux` kSST_LAST 无条件 tvalid 重发尾字,chunk 尾字已在 NORMAL/PRIME
   本拍被接受后仍进 LAST 重发一次(每 chunk 多 1 重复字)。改为尾字已接受
   (tready_out=1)时直接进 kSST_HBLANK,仅未接受才进 LAST 保持。单 slice 因
   axi_last_out 恒 0 从不进 LAST,不受影响。

单 slice 回归保持绿(rtl-e2e / flatness-replay / smoke / slang / lint)。

**剩余两处(均为预存、与结构修复无关,已分别定位):**

- **窄 slice 的 line-end VLC 内容分歧(ms2)**:proc0 在 chunk1(line1)第 10 个
  muxword(word22)起与 golden 分歧并级联。经值搜索定位:word22 =
  `740324b16bf1` = C trace `(ssp1, group15)`,即 **line1 的最后一个 group(像素
  45-47,48 宽 slice 的末组)的 Co/Cg VLC 编码错**;line0 对应组正确、line1 其余
  组正确,唯独 line1 末组错。RTL 的 VLC 片段化与 C model 不同(README 已知 RTL 合并
  片段),片段级对比不可靠,需按 muxword 位级/group 输入(residual/qp/ich)定位
  line1 末组的预测/重建输入。疑似窄 slice 行末 group 的右缘 look-ahead/上一行重建。

  **2026-08-19 稳定证据定位(新增)**:非 VLC 编码层,而是**预测输入链路在奇数行丢一组**。
  多路独立证据交叉确认:
  1. muxword 位级:word22 低 24bit 一致、高 24bit 分歧(DSC 打包先发低位,高 24bit 为
     line1 末组 Co/Cg 的后半 VLC 片段)。
  2. `i_valid_pd` 逐行事务数统计:**16/15 交替**,奇数行(line1,line3,...)只产生 15 个
     group 事务,C model 每行固定 16 组 → RTL 预测输出链路每两行丢一组。
  3. `dsce_bpvector` 的 `i_cur_x`(当前组起点)在 line1 末组为 **42**(应为 45),偏移
     恰为 3 像素 = 一组。C 的 `prevLinePred`/BP 预测按 `hPos-7`(45→38)取重建,
     RTL 因 `i_cur_x=42` 取到像素 35 → **BP 预测像素差 3**(RTL `[90,42,210]` vs
     C `[87,42,212]`,Co 全对、Y/Cg 差,正是读偏移 3 的重建像素)。
  4. 上游替换 A/B(把 dsce_bpvector/dsce_mpp/dsce_ich/dsce_vlc 换成 function model)
     均 FAIL 不变或 DIFFERENT FAILURE,不能定罪模块本身——function model 的 DPI 状态
     是**全局单例**(`units[3]`/`State state`/`history[32]`),ms2 有 2 slice×N 实例
     共用同一状态互相污染(单 slice 场景才适用)。项目已在提交 `5c74021` 主动删除
     function-model 替换 target,该路径不宜继续。
  5. 丢组位置在 **flatness 行尾 flush → predict 输入(`i_valid_fd`)边界**:
     `dsce_flat_flags` 行尾 flush(`i_flush_count=5`,last 在 count=2)与
     `dsce_slice` 的 flatness 输出调度器(FIFO + cooldown=3 恢复四拍节拍)在行尾
     竞争,奇数行末组事务丢失。修复方向:核对 flat_flags flush 输出的事务数/时序与
     行末组数对齐,或调度器在 flush 突发时不丢事务。

  **2026-08-19 二次定位(修正)**:更深层分析把根因收敛到 **`dsce_slice_buffer`
  的 write 侧只处理 72 行(输入 108 行)**。逐级握手指数(可靠,非内部信号):
  1. `partition` 向 processor0 输出 **108 行 last**(`axi_last_out[0]`=108,axi 域握手),
     每行 12 word → slice buffer 输入握手 `in_valid=1296 / in_last=108`(正确收到 108 行)。
  2. `slice buffer` 输出仅 **`out_valid=1152 / out_last=72`**(72 行 × 16 组)。
     36 行在 write→read 之间丢失。
  3. VCD 时序:slice buffer 的 `i_axi_waddr` 在 68915000 后不再变化(write 只写到 72 行),
     但输入 `axi_tvalid_in` 持续到 108 行;无 `axi_overflow`、无 backpressure 停摆。
  4. read 侧在 72 行后 `pipeline_state=BUFFER_EMPTY`、`i_dsc_write_ready=0` 等待,
     但 write 侧未再推进 → **read 永久等待**。
  5. 之前 `i_valid_pd` 16/15 交替与 bpvector `i_cur_x=42` 均为该 72 行错位的**下游表现**:
     行数错位导致奇数行末组用错 BP 重建,line1 末组 VLC 编码错(word22 首差)。

  **修复方向(未完成)**:`dsce_slice_buffer` 的 write 侧在 72 行后停止推进 waddr,
  而输入仍有效。需定位 write 地址/ready 在 72 行后停的机制(疑似 write 侧行计数或
  `i_axi_write_ready` 跨时钟同步与 read 启动的时序竞争)。该模块内部时序分析耗时
  巨大,列为专项待续。

- **大 slice 的 format buffer 容量不足(ms2_192)**:g1(96 宽 slice)encoder 在
  ~1824/2592 words 提前停(stream_builder FIFO + format RAM 256 深,在 mux 读门控
  下无法容纳整 slice 输出 → encoder 早停 → 早进 PAD → 截断)。且 g0 先完成 PAD、
  g1 后完成时,mux 回到已完成且无数据的 g0 会卡死(两 slice 真实压缩长度不同是正常
  的)。需:a) format buffer RAM/stream FIFO 对 encoder 施加真正背压(满则停),或
  b) 增大 RAM,或 c) mux 对"已完成且无数据"的 slice 有跳转/结束机制。

- 验收仍:ms2 + ms2_192 逐字节一致 + ≥1 不同 seed + 随机背压/空泡。
