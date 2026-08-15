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
