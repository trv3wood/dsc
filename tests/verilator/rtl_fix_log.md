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