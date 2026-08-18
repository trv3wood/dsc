# Verilator RTL Verification

## 已验证范围

`make rtl-lint` 对 `dsc_encoder` 顶层执行完整 elaboration 和 lint。归档中的 `dsce_quant.sv` 未被顶层引用，并依赖未定义类型，因此不在有效设计 filelist 中。

`make rtl-smoke` 构建并运行顶层自检 testbench，覆盖：

- 异步复位和三个时钟域的复位释放；
- APB 默认寄存器、只读能力寄存器和写后读回；
- 编码器关闭时的 192-bit bypass 数据一致性；
- AXI 输出 backpressure 期间 `valid` 和数据保持。

`make rtl-e2e` 使用固定 seed `0x445343` 生成 96×108、RGB 8bpc、12bpp 的
可复现伪随机输入，用 C model
产生 PPS 和 golden payload，再通过 APB 配置 RTL、送入整帧像素并逐字节比较输出。
生成物位于忽略的 `tests/verilator/generated/`，不应提交。

用 `python3 tests/verilator/generate_golden.py --seed 0x1234` 可覆盖默认 seed；
通过 Makefile 运行完整对拍时使用 `make rtl-e2e GOLDEN_SEED=0x1234`。

当前该测试预期失败，用于复现待修 RTL。修正测试平台的逐行输入节流和 PPS posted
write 间隔后，RTL 能处理完整的 3456 groups，且正确加载 DSC 1.2 PPS。当前首个
payload 差异位于 byte 256，期望 `15`、实际 `16`；RTL 输出 15024 bytes，C model
输出 15552 bytes。

## 缺陷定位记录

从早期基线 `4b1ebbc` 到 HEAD 的完整 RTL 修复清单见
[`rtl_fix_log.md`](rtl_fix_log.md)。

固定配置为 96×108、RGB 8bpc、12bpp、seed `0x445343`。C model 通过环境变量
`DSC_GROUP_TRACE`、`DSC_RATE_TRACE`、`DSC_VLC_TRACE` 和 `DSC_MUX_TRACE` 输出边界
事务；golden 生成器将三路 SSP muxword/VLC trace 转换成 RTL testbench 可直接比较
的十六进制数据。

排查过程得到以下结论：

1. 原 testbench 连续写入各行，但 `dsce_slice_buffer` 每行复用写地址，导致下一行
   覆盖尚未编码的数据。现在每行写完后等待该行从 slice buffer 读完。
2. PPS table index 是 posted write。索引写入后立即发送首字节会丢失 `0x12`，使 RTL
   错误运行在 DSC 1.x 分支；在索引写和 commit 前加入落地等待后，PPS 版本恢复为
   1.2，前期 rate-control 状态与 C model 对齐。
3. 异步、一拍和两拍 line-memory 读延迟均不移动修正后首差异，且未发生同地址冲突。
   format RAM 写入前后的首差异相同，排除这些 support/搬运路径为首因。
4. 新基线中，前 32 groups 的 QP、coded size、RC size 和 buffer fullness 与 C model
   对齐。首差异出现在 C model 开始发送 flatness 语法的位置。
5. `dsce_flat_flags.sv` 在有效输出时仍把 `dsc_vlc_flat_flags_out` 赋为初始化值；运行中
   3349 个有效事务的非零 flag 数量为 0。`dsce_slice.sv` 又把 rate/format flatness
   输入常量绑零，且 `dsce_vlc.sv` 声明但未使用 `dsc_flatness_in`。

因此当前已定位的 RTL 缺陷是 flatness 的生成、流水对齐和 VLC 编码路径未完成，而
不是 `dsce_rate` 算法、support RAM 或输出 CDC。修复时应先为 `dsce_flat_flags` 建立
独立 replay/A-B harness，再把真实 flatness 事务接入 rate 和 format，最后恢复完整
RTL 运行端到端、多 seed 和随机 backpressure 回归。禁止以 golden 数据注入作为最终
实现。

### Flatness 子模块 replay

`make rtl-flatness-replay` 使用 `flatness` 图案单独实例化 `dsce_flatness`。生成器按
RTL 相同的 RGB→YCoCg 变换，从原始像素和 C model 边界 QP 独立计算 4/6 像素窗口、
flatness 状态及期望 flags；C group trace 只交叉检查坐标和状态移植，不作为 DUT 输入。
QP 按输出事务序号驱动，输入 valid 每三个处理周期出现一次。该 adapter 不经过预测器、
码控、VLC 或绝对周期 golden 注入。

边界 trace 证明原 RTL 把 Check 1/2 错算成目标 group 左侧窗口，缺少 C model 要求的
向右两组 look-ahead。`dsce_flat_check` 现按“目标组末像素+下一组”和“后续两个完整组”
计算窗口，并修复了行尾 padding 状态跨行残留。`dsce_flat_flags` 同时修复了 stage 0 的
last 被 stage 3 清零覆盖、提前 flush 以及 `group_flatness_type` 使用 `1/2` 而非包定义
`2/3` 的问题。

当前 replay 连续覆盖完整 108 行、3456 groups；逐事务检查原始像素、两个 check-diff、
完整 flags 和 last，seed `0x445343` 下通过，单行 replay 在 seed `0x1234` 及 valid
周期 3/4 下也通过。该结果只验证 flatness 模块边界，不代表端到端编码正确。

### VLC function-model 替换

`make rtl-e2e-vlc-model GOLDEN_PATTERN=flatness GOLDEN_SEED=0x445343` 在
`dsce_format.gen_vlc` 的实例边界，将三个完整 `dsce_vlc` 替换为端口等价的
`dsce_vlc_function_model`。原 RTL 内部不含 DPI override。SystemVerilog adapter 只负责
打包公开输入和寄存输出；C++ 模型独立维护 `previous_qlevel`、`previous_ich`、
`predicted_size`、supergroup index 和 fragment 队列，并同时生成 VLC、coded-unit-size
及 RC-size 全部输出。默认构建仍实例化真实 RTL。

黑盒模型修正 valid 低时保持 size 寄存器的边界语义后，前四组 coded/RC size
恢复为 `105/81`、`82/81`、`82/81`、`78/72`，与基线一致。完整替换消除了
早期 ICH 调度差异和 FIFO overflow，将可信首差异稳定到 SSP0 fragment 94
(`010001`/`010000`) 及 payload byte 152 (`a9`/`29`)。最终仅输出
9354/15552 bytes 并超时，因此不能宣称端到端通过。下一步应捕获完整
`dsce_vlc` 公开输入的逐 group replay，区分 flatness 事务关联错误与模型算法错误。

### VLC replay 与 QP 反馈边界

`make rtl-vlc-capture` 从真实顶层捕获 96 个 `dsce_vlc` 公开输入事务；
`make rtl-vlc-replay` 用同一 trace 并行驱动三个完整 RTL VLC 和三个完整 function
model。trace 不含 golden 输出。初始逐 fragment 比较显示 RTL 色度在 fragment 36
出现 `size=0` 事务，而 C model 的 `AddBits(0)` 不产生 fragment；禁止该事务会破坏
formatter 的 group 节拍并导致 syntax FIFO overflow，因此它不是可删除的普通空输出，
replay 后续必须按有效 bitstream 而非 fragment 数量比较。luma fragment 94 同样是 RTL
把 C model 的 1-bit 与 2-bit 片段合并为一个 3-bit 片段，不能据此归因算法错误。

顶层边界检查发现 flatness group 35 需要的 QP=4 与 `dsce_rate` 的寄存输出在同一沿
提交，`dsce_flat_flags` 在沿前只能看到旧 QP=0。`dsce_rate.i_st_qp` 和
`i_valid_pipe[2]` 在沿前已经稳定，因此现显式导出 `dsc_primary_qp_next` 与
`dsc_qp_valid_next`，由 `dsce_rate_adjust` 成对选择。修复后前 48 个顶层 flatness
源端及 prediction 对齐端事务全部匹配 golden。曾尝试给 flatness 增加两级 pending
延迟，但延迟会沿 rate-feedback 环传播并改变吞吐；该实验已撤回，原 flatness 时序配合
next-QP 即可通过边界检查。

当前全 RTL 在 byte 113 首次失配，随后真实 VLC 路径触发 syntax FIFO overflow；完整
VLC 替换不会在该点 overflow，但仍在 byte 172 起失配并最终超时。强证据因此把下一步
定位在 VLC 的无 ready 四拍调度/formatter 契约及 function model 尚未覆盖的共同输入
状态，而不是 flatness 算法或 support RAM。最终修复仍须恢复真实 VLC 并通过端到端。

replay 后续增加 MSB-first bit queue，与 `dsce_muxword` 的整段左移追加语义一致，可跨越
RTL 的零长度节拍以及合并 fragment。正确位序下，RTL 与 function model 对 96 groups
均输出 `1065/950/942` bits，三路首差异和 mismatch 总数完全相同：luma bit 523、
chroma bit 470/470。这排除了 `dsce_vlc` 为剩余首因；曾基于错误 LSB-first checker
提出的 flatness packing 修改已撤回。

修正 C group trace，使 MPP 时记录实际编码的 `quantizedResidualMid` 后，VLC 输入边界
在 groups 0--36 全部匹配。首差异精确位于全局 group 37（line 1 group 5）：QP=5、
ICH=0 均一致，C predicted size 为 `6/4/4`，RTL 为 `6/3/5`。将 RTL 的 MMAP 公开输入
代入 C `SamplePredict(PT_MAP)` 得到与 RTL 完全一致的 predictor，排除了 MMAP 算法。
C trace 在该 group 不调用 PT_MAP，证明 C 选择 BP；RTL 则输出 `use_bp=0`。

`dsce_bpvector` 当前无条件把 `dsc_use_bp` 清零，且已计算的 vector 没有用于 predictor：
`dsc_predict_out` 直接取当前原像素，residual 固定使用 `dsc_prev_line_in[0:2]`。同时缺少
C model 的 `bpCount>=3` 与 recent-edge 门控。该模块不是可通过拉高 enable 修复的完整
BP 实现。下一步必须以整个 `dsce_bpvector` 为黑盒移植 BP search/predict function model，
替换进顶层验证 group 37 和端到端，再据此重构真实 RTL。

### Flatness 节拍、MPP 与后续边界

固定周期 replay 曾掩盖 `dsce_flat_flags` 在 valid 延迟三拍后仍读取实时 group/check-diff
的问题。加入连续 valid 后可稳定复现，现已把 group、check-diff 与 valid 同步流水，并禁止
行末候选泄漏到下一行。独立 replay 在 `VALID_PERIOD=1` 下通过全部 3456 groups。

flatness 行尾 flush 会突发输出，而 prediction、重建反馈及 MMAP 实际要求每四拍一个 group。
`dsce_slice` 现用深度 16 FIFO 缓存完整 flatness 事务，并以四拍间隔发送；无 overflow，首行
全部 32 groups 的 rate 状态与 C model 对齐，原 group 25 差异消失。这属于恢复已有下游
事务契约，不注入 golden 数据。

`make rtl-e2e-bp-model` 用完整 BP DPI 模型替换 `dsce_bpvector` 后，首个预测边界差异由
group 37 推进到 group 39。追踪发现 group 37 的 Co 选择 MPP 时，真实 `dsce_mpp` 延迟后
读取了变化后的实时 right/group 输入，使 predictor 从应有的 258 变为 262。新增
`make rtl-e2e-bp-mpp-model` 完整替换三个 MPP 实例，首 payload 差异由 byte 305 推进到
byte 2255。真实 MPP 改为在 valid 当拍锁存计算结果并随 valid 流水后，获得相同推进效果。

之后 group 385 暴露 line-last bit-save 状态差异：C model 的 DSC 1.2 行末强制 flat QP
发生在 RateControl 之后，不应清除当前行 bit-save；RTL 却把行末强制
`group_flatness_type` 当作普通 flat group。排除 `i_last_pd` 后，QP 序列恢复为 `3/5/7`，
首 VLC 输入差异推进到 group 504 的 ICH 误选。

在该可信上游上，完整 VLC 替换把首 payload 差异从 byte 2316 推进到 byte 2849。
512-group replay 表明 RTL 会发送 `valid=1,size=0`，function model 不会。四拍事务适配
已消除旧实验中的 overflow；真实 VLC 禁止零长度 valid 后也推进到 byte 2849，确认该
边界语义修复。当前下一目标是完整替换 `dsce_ich`，验证并递归定位 group 504 误选。

### ICH function model、码控与 muxword 链路

在 BP+ICH 完整替换基线上验证并修复了五个独立缺陷，`make rtl-e2e-bp-ich-model`
现对 seed `0x445343` 端到端 PASS（15552 bytes 逐字节一致，SSP muxword 0 失配）。

1. **ICH function model 的 `ceil_log2` 位宽语义**。C model (`dsc_utils.c`) 返回
   二进制位宽（精确 2 的幂如 8 返回 4），function model 用数学上界（8→3）少 1。
   该 bug 使 group 591（`maxIchError=35/8/54`）的 `log_ich` 算成 15 而非 16，
   `cost_ich=76` 误判小于 `cost_p=79` 而选错 ICH。这是模型 bug，不是 RTL。
2. **`dsce_rate` bit-save 分支缺少 min_qp 下界**。DSC 1.2 行尾连续 all-MPP 触发
   `bitsave_mode==2` 时，C model 先 `stQp=prevQp+2` 再统一 `CLAMP(stQp, min, max)`；
   RTL 的 `7'b????100` 分支只做上界 `dsce_min_qp(current+2, adj_max)`，在
   prevQp=1、min_qp=5 时输出 3 而非 5。修复为 `dsce_clamp_qp(..., min, adj_max)`。
3. **`dsce_muxword` 丢弃 size>=10 的片段**。RTL luma 把 C 的 1+4+5 位片段合并为
   单个 10 位片段（C model 无 size>=10 的 luma 片段），而两个 case 只处理移位量
   1-9，`default` 丢弃数据，首差异在 bit 6833（muxword word 142）。扩展到 16。
4. **muxword slice 结束不发射尾部部分字**。最后一行部分字（45 位）留在 buffer 里
   未被 flush，且直接 byte-swap 的部分字填充位在头部、与 reference shifter 语义
   相反。新增 `dsc_slice_last_in`（dsce_format 按行尾计数检测最后一行），把部分字
   左移对齐到高 48 位后按整字字节序输出；余量同理。
5. **`dsce_format_buffer` 缺少最后 chunk 的零填充**。输出停在 2583 个 muxword
   （15498 字节），与 chunk_size×slice_height=15552 相差 54 字节。新增目标字数
   同步与 `kRS_DATA_PAD` 状态，AXI 域写计数稳定 64 拍判定编码完成后再补零。

完整 RTL（不替换任何子模块）首差异仍锁定在全局 group 37，由 `dsce_bpvector`
无条件清零 `dsc_use_bp` 且未接入预测器所致；在真实 RTL 实现 BP search/predict
之前，`rtl-e2e-bp-model` 系基线仍是可信上游。修复 BP 后应恢复真实 ICH 与 VLC，
再跑端到端、flatness replay 和多 seed 回归。

### 真实 BP vector 实现

重写 `dsce_bpvector` 使其与参考模型 `BlockPredSearch` 及已验证的 function model 完全一致。
`make rtl-e2e-ich-model`（真实 BP + ICH function model）端到端 PASS；独立
`make rtl-bp-replay` 对 3456 groups 的 use_bp/vector/predict/residual 全部 0 失配。
修复要点：

1. 前一行重建改用绝对像素位置数组 `i_prev_arr`，替代原 6 像素移位寄存器
   （后者窗口重复/错位，无法提供 x-6..x+2 的正确 9 像素窗口）。
2. SAD 窗口按 `max(0,x-6)..x+2` 截断，`p<=candidate` 时用中点
   （luma=1<<(bpc-1)，chroma=1<<bpc，注意 chroma 不是 bpc+1）。
3. `modified_abs_diff` 移位量按分量 = cpntBitDepth-7（8bpc 下 luma=1,chroma=2），
   修复 `abs_diff>>shift` 结果被 6 位截断为 0 的问题（`dsce_sad` 同病）。
4. 候选选择改为运行最小值扫描（`i_bpsad[0]` 为 MAP 基线，平局保留小索引），
   替代原决策树（平局偏好大索引）；`dsc_bpvector` 输出=selected（0 或 2..9）。
5. use_bp 决策含 line>0、bp_count>=3、last_edge<3；bp_count/edge 行尾清零在
   use_bp 之后，行尾组仍能使用更新后的计数（原实现把行尾 next_bpcount 清 0）。
6. 当前组 x 用 `i_cur_x` 捕获（`i_hpos` 已推进到下一组），修正 SAD/edge 使用错误 x。
7. 残差符号修正（`dsce_compute_residual` 参数顺序为 predict, orig）。

完整 RTL（不替换任何子模块）首差异推进到全局 group 671：`dsc_ich_next_is_very_flat`
在真实 ICH 决策点为 1，而 function model 在同样事务看到 0，导致真实 ICH 以
`log_ich>log_p` 拒绝 ICH，C model 却选 ICH。该信号 = `i_vlc_flat_flags_aligned.group_flatness_type
== kDSC_VERY_FLAT`。

### ICH 行末、VLC 时序与码控门控修复

在完整 RTL 基线上验证并修复了三个独立缺陷，`make rtl-e2e` 现对 seed `0x445343`
端到端 PASS（15552 bytes 逐字节一致，SSP muxword 0 失配），且 `rtl-flatness-replay`
与 `rtl-bp-replay` 均 0 失配。

1. **ICH 决策误用行末强制 flatness**。`dsce_flat_flags` 在行末 flush 时把
   `group_flatness_type` 强制为 `kDSC_VERY_FLAT`（供码控的行末 flat QP 使用），但
   C model 的 `IchDecision` 调 `IsOrigFlatHIndex(dsc_state->hPos)`，行末因
   `hPos+1>=sliceWidth` 提前返回非 flat。该强制值经 `i_vlc_flat_flags_aligned`
   流入 ICH 的 `dsc_ich_next_is_very_flat`，导致行末组用 `log_ich<=log_p` 判据
   错误拒绝 ICH。全量比对确认 108 处 `sent_vf != ich_flat` 全部是行末组。修复为
   ICH 连接加 `!i_last_pd` 门控，与 `dsce_rate_adjust` 的 `dsc_flatness_flag`
   先例一致。
2. **`dsce_vlc` PipeS3 误用实时 `dsc_ich_selected_in`**。PipeS0-S2 分别在 valid 拍
   与 valid 后 1-2 拍求值，PipeS3 在 valid 后 3 拍求值；真实 ICH 的组合
   `dsc_ich_select_out` 在 `dsc_predict_valid_in` 回落后立即归零，PipeS3 因此
   不会抑制 ICH 组的第三个残差，产生多余片段并错位 fragment/muxword 计数（首个
   ICH 组 395 之前无 ICH 组故未暴露）。PipeS1/S2 已用寄存的 `i_ich_selected_in`，
   修复为 PipeS3 同样使用。
3. **`dsce_rate_adjust` 无条件应用行末 flat QP**。C model 用
   `primaryQp < rc_range_parameters[14].range_max_qp`（8bpc 12bpp 下为 11）门控
   行末强制 flat QP；RTL 原实现无条件把 `dsc_primary_qp_out`/`dsc_prev_qp_out`
   置为 flat QP。seed `0x1234` 行末组 primaryQp=11 时被错误压到 very_flat_qp=1。
   新增 `cfg_rc_range_max_qp_14` 输入（取 `rc_range_parameters[14][10:6]`），用
   `i_last_used_qp_in_slice_line < i_range_max_qp_14` 门控。

`dsce_flatness` 的 `cfg_rc_range_max_qp_14` 连接使用 `[9:5]`，但 `tDSC_RC_RANGE_PARAMETERS`
中 `range_max_qp` 实际位于 `[10:6]`（`dsce_rate` 正确）；该信号在 `dsce_flat_flags`
中未使用，属死信号，未改。

### seed `0x1234` 剩余差异与行末 QP 回退修复

`make rtl-e2e GOLDEN_SEED=0x1234` 全 RTL 现端到端 PASS（15552 bytes 逐字节一致，
仅 ssp0 前 4 个 VLC fragment 与 C model 的片段粒度假失配，不影响打包后的 byte
流，与 seed `0x445343` 的 muxword 0 失配同类）。`rtl-e2e`（默认 seed）、
`rtl-flatness-replay` 与 `rtl-bp-replay` 均 0 失配。

此前首个 VLC 输入差异在 group 1889/2048 附近，根因是码控 QP 边界，不是 ICH
history 重建累积精度：

- C model 中 `primaryQp(G) = RateControl(G-1) 提交后的 stQp(G-1)`，即 prevQp 滞后
  stQp 一组。`dsce_rate` 在 `i_valid_pipe[2]` 把 `i_st_qp` 提交进 `dsc_primary_qp`，
  普通行 fd(G+1) 在提交(G) 前读到最近提交的 stQp(G-1)，与 C model 一致。
- 行末 flush 使下一行首组 fd 延后到上一行末组提交之后，读到 `stQp(L-1)`；而 C model
  期望该组读到 `stQp(L-2)`（行末组 RateControl 后 `prevQp` 仍为行末前的 stQp）。
  `dsce_rate_adjust` 的 `i_orig_is_flat` 分支在 `i_last_used_qp_in_slice_line
  >= i_range_max_qp_14`（行末 QP 已达 range 上限、DSC 1.2 不强制 flat QP）时，
  原实现直接继承已推进的 primary QP，使下一行前几组的码控/VLC 状态偏离 golden。
- 修复：`dsce_rate` 新增输出 `dsc_primary_qp_prev`，在提交沿保留上一次提交值
  （线 754-757、872-881）；`dsce_slice` 穿线；`dsce_rate_adjust` 新增
  `dsc_rc_primary_qp_prev_in`，在 `i_orig_is_flat` 且 QP 未达 range 上限时回退
  primary/prev QP 到 `dsc_rc_primary_qp_prev_in` / `dsc_rc_prev_qp_in`
  （线 109-114）。

A/B 验证：单独还原三个 RTL 文件（HEAD 状态）重跑 seed `0x1234` 端到端失配
5647/15552 bytes；带修复则逐字节一致，证明该修复是 seed `0x1234` 通过的必要条件。
真实 ICH、VLC 与 BP 均未替换。

```sh
make rtl-e2e GOLDEN_SEED=0x1234       # PASS
make rtl-e2e                           # PASS (seed 0x445343)
make rtl-flatness-replay               # 0 失配
make rtl-bp-replay                     # 0 失配
```

## 调试操作手册

本节是 DSC 专属的操作参考；通用调试纪律见
`.claude/skills/debug-rtl-by-golden-diff/SKILL.md`。

### 快速命令

    make rtl-e2e                                  # 默认 seed 0x445343；PASS = 15552 bytes 逐字节一致
    make rtl-e2e GOLDEN_SEED=0x1234               # 换 seed
    make rtl-e2e GOLDEN_PATTERN=flatness          # 覆盖 flatness 决策
    ./obj_dir/Vtb_dsc_e2e +STOP_FIRST_BOUNDARY    # 首个 group 边界失配停表（$fatal）
    grep -E "MISMATCH|VLC_INPUT|FLAT_SOURCE" <log> # 找首差异
    make rtl-e2e-trace                            # 产出 VCD，gtkwave 打开

### RTL 打点词典（tb_dsc_e2e.sv 的 $display）

从 `./obj_dir/Vtb_dsc_e2e` 的 stdout 抓取，按流水阶段分组。配 `+STOP_FIRST_BOUNDARY` 的
`VLC_INPUT_*_MISMATCH` 是最上游的可停表入口。

**输出端（AXI 域）**

| 打点 | 内容 |
|---|---|
| `MISMATCH byte=N expected=.. actual=.. word=...` | 前 8 个**最终 payload 字节失配** |
| `MUX_MISMATCH byte=N expected=.. actual=..` | 前 8 个 **bypass 前**字节失配（区分编码错 vs 重打包错） |
| `MUX_VALID[N] ready=.. data=.. bypass_ready=..`、`MUX[N]=...` | slice mux 输出与 backpressure |
| `TOP[N]=...` | 前 24 个顶层 AXI 输出码字 |

**format / stream-builder**

| 打点 | 内容 |
|---|---|
| `SSP_MISMATCH ssp word expected actual` | 每 SSP 前 4 个 muxword 失配 |
| `VLC_MISMATCH ssp fragment expected actual` | 每 SSP 前 4 个 VLC 片段 `{size,data}` 失配 |
| `PRE_RAM_MISMATCH byte expected actual` | 前 8 个入 RAM 前字节失配 |

**VLC 输入边界（group 级；`+STOP_FIRST_BOUNDARY` 可停表）**

| 打点 | 内容 |
|---|---|
| `VLC_INPUT_RESIDUAL_MISMATCH group=N` | 非 ICH 组残差 vs `group_residual_expected.hex` |
| `VLC_INPUT_PREDICTED_MISMATCH group=N` | `i_vlc_size_dec` vs `group_predicted_expected.hex` |
| `VLC_INPUT_QP_MISMATCH group=N expected actual` | `i_primary_qp_res` vs `group_qp_expected.hex`，全组检查 |
| `VLC_INPUT_ICH_MISMATCH` / `VLC_INPUT_ICH_INDEX_MISMATCH` | ICH 选择/index vs `group_ich_*.hex` |
| `DECISION_BOUNDARY` / `DECISION_SAMPLE` / `PD group` | decision 输出边界与逐 sample 预测残差 |
| `ICH_STABLE` / `ICH_RTL_COST` / `ICH_DBG(K)` | ICH 决策与 candidate 内部 |
| `FLAT_ALIGNED_MISMATCH` | `i_vlc_flat_flags_aligned` vs `flatness_expected.hex` |

**decision/flatness/rate 上游**

| 打点 | 内容 |
|---|---|
| `FLAT_SOURCE_MISMATCH group ...` / `FLAT_SOURCE_PIXEL_MISMATCH` | `i_vlc_flat_flags_fd` vs `flatness_expected.hex` |
| `FD group t st_qp prim_qp prev_qp ...` | rate_adjust 输入 |
| `RATE_QP` / `RATE_RAW` / `RA_DBG` / `RATE group coded rc fullness ...` | 码控全内部状态 |
| `MMAP_INPUT_Y/CO/CG` / `BP_RECON_FEEDBACK` | MMAP/BP 输入 |
| `DECISION line group ...` / `RESIDUAL ...` | 前两行逐组 |

**收尾/统计**：`PIPELINE`、`COMPARE`、`SSP words`、`VLC fragments`、`STATE`、`RESULT`、
`PASS: RTL payload matches C model (15552 bytes)`。

### C trace 字段对照（`tests/verilator/generated/c_*.txt`，`make golden` 重新生成）

| 文件 | env | 对照 |
|---|---|---|
| `c_group_trace.txt` | `DSC_GROUP_TRACE` | 每 group 进 VLC 前 line/group/qp/ich/ichidx/bp/mpp/flatness + 每 unit 残差 u0..u2、pred0..2、err。对照 `VLC_INPUT_*` |
| `c_rate_trace.txt` | `DSC_RATE_TRACE` | 码控 coded/rc/fullness/target/min/max/prev。对照 `RATE`/`RATE_QP` |
| `c_vlc_trace.txt` | `DSC_VLC_TRACE` | 每 VLC 片段 ssp/group/size/data。对照 `VLC_MISMATCH` |
| `c_mux_trace.txt` | `DSC_MUX_TRACE` | 每 muxword ssp/group/data。对照 `MUX_MISMATCH`/`SSP_MISMATCH` |
| `c_mmap_trace.txt` | `DSC_MMAP_TRACE` | 预测采样 line/group/unit/q/current/prev/right。对照 `MMAP_INPUT_*` |

### function-model 替换 target（升级路径）

替换是调试手段不是默认流程；纪律见 SKILL.md"升级路径"。**不要用 value model 替换正在调时序的
模块**（会消掉要抓的 bug）——方法论是替换可疑模块**周围**的组件、保留可疑模块本身。

早期把所有 `rtl-e2e-*-model` 替换 target（替换 BP/MPP/VLC/ICH/flatness 本身）与
`rtl-{vlc,bp}-{capture,replay}` 对比 harness 移除了：它们建模的是可疑模块本身，与上述方法论
相悖。缺陷定位记录中引用的这些历史命令不再可运行，但结论仍有效。

当前仅保留一个模块边界校验 harness：

| target | 内容 | 说明 |
|---|---|---|
| `rtl-flatness-replay` | 逐事务验证 flatness 边界 | 保持 `dsce_flat_check/flags/flatness` RTL 真实，用期望向量驱动，不经过预测器和码控 |

function model 源文件仍在 `tests/verilator/model/*.cpp`，adapter 在
`verilog_dsc/dsce_*_function_model.sv`（`ifdef` 守护），可作参考或按新方法论重建目标。
四情形判定表见 SKILL.md。

### 外部工具总结（快照 2026-08-18；状态会漂移，使用前先 probe）

| 工具 | 版本 | 能力 | 本项目调用 | 状态 |
|---|---|---|---|---|
| verilator | 5.032 | 编译/仿真/波形 | `make rtl-e2e`、`rtl-lint`、`rtl-smoke`、`rtl-e2e-trace` | ✅ 已接入 |
| verilator_coverage | 5.032 | line/toggle 覆盖率分析、annotate、合并 | `make rtl-e2e-cov`（产物 `/tmp/dsc_cov/`） | ✅ 已接入 |
| slang | 11.0.0 | SV elaborate/lint | `make rtl-slang` | ✅ 已接入 |
| slang-server | 0.2.10 | `.sv/.svh/.v/.vh` LSP（经 systemverilog-lsp 插件） | Claude Code `LSP` 工具；索引配置 `.slang/server.json` | ✅ 已接入 |
| clangd | 21.1.8 | C model LSP | `LSP` 工具；`compile_commands.json` 由 `make model-compile-commands`（bear）生成 | ✅ 已接入 |
| bear | 3.1.6 | 拦截编译生成 compile_commands.json | `make model-compile-commands` | ✅ 已接入 |
| gtkwave | 3.3.126 | VCD 波形查看 | `make rtl-e2e-trace` 后 `gtkwave tests/verilator/generated/rtl_e2e_trace.vcd` | ✅ 已接入 |
| gcc/g++ | 15.2 | C model + function model DPI | `make model` | ✅ 已接入 |
| make | 4.4.1 | 构建 | 全部 target | ✅ 已接入 |
| python3 | 3.14.4 | golden 向量生成/回归脚本 | `make golden`、`make model-regression` | ✅ 已接入 |
| verdi | — | 商业波形/调试 | — | ⛔ 未装（blocked） |

**blocked 判据**：`which` 找不到 → blocked；版本 probe 失败 → blocked；存在但项目未接通 →
not-wired，需先验证再使用。工具状态是快照、会漂移，使用前先 probe。

**LSP 已知限制**：systemverilog-lsp 的 `workspaceSymbol` 跨文件搜索在 Claude Code 前端有解析
bug（`l.location.range.start` undefined）；跨文件导航用 `findReferences`/`goToDefinition`，
跨文件搜索用 grep 兜底。`LSP` 工具位置参数是 1-based 字符偏移，symbol 定位需先 Read 数准列。

**VCD 波形**：`make rtl-e2e-trace`（`--trace --trace-depth 5`）产出
`tests/verilator/generated/rtl_e2e_trace.vcd`（已 gitignore）。层次：
`tb_dsc_e2e.dsc_encoder.dsce_engine_inst.gen_slice[*].dsce_slice_inst`。

**覆盖率**：`make rtl-e2e-cov` 全链路（golden → coverage 编译 → 仿真 → `verilator_coverage
--annotate`），产物全在 `/tmp/dsc_cov/` 不污染工作区。看盲区：
`grep '%000000' /tmp/dsc_cov/annotate/dsce_*.sv`；`COV_DIR` 可覆盖以跑多配置，再用
`verilator_coverage a.dat b.dat --write-merged merged.dat` 合并。

## 仿真假设

原始 RTL 包不含 `gprim_sync_stage`、`gprim_sync2_stage` 和 `gram_bist_1r1w`。`support/` 提供仅用于仿真的模型：同步器保留一拍/两拍延迟，RAM 使用同步读写，BIST 不建模。这些模型不能替代工艺库 CDC、冲突语义或 BIST 签核。

`make rtl-slang` 已能完整 elaborate 顶层，说明 support 端口宽度和连接匹配。RAM
PPS SRAM 的状态机要求一拍同步读。line memory 的延迟敏感性实验使用诊断宏切换
异步/两拍读；这些模式仅用于排除 support 假设，不是默认实现。默认用例没有 line
memory 同地址冲突，并且 payload 在写入 format buffer RAM 前已经出错，因此该 RAM
和后续输出路径不是首差异来源。缺少原厂 primitive 定义，尚不能把所有工艺相关行为
视为签核完成。

## 尚未验证

当前端到端用例仅覆盖单 slice processor、4 pixel/cycle 和 48-bit 输出。后续应在
修复首差异后加入随机 backpressure、输入空泡、多 slice 以及 RGB/YUV 配置，并确认
归档缺失 SRAM 的真实读延迟和冲突语义。

不要将 lint 或 smoke 通过表述为完整 DSC 功能签核。
