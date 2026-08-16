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
