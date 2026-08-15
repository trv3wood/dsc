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

当前该测试预期失败，用于复现待修 RTL：原生 muxword 流在 byte 110 首次不同，
期望 `84`、实际 `85`；RTL 共输出 4380 bytes，而 C model 的固定 chunk payload
为 15552 bytes。前 110 bytes 在 bypass 前后均一致，说明首差异位于编码路径，
并且仍需独立检查 chunk 填充或结束控制。

## 仿真假设

原始 RTL 包不含 `gprim_sync_stage`、`gprim_sync2_stage` 和 `gram_bist_1r1w`。`support/` 提供仅用于仿真的模型：同步器保留一拍/两拍延迟，RAM 使用同步读写，BIST 不建模。这些模型不能替代工艺库 CDC、冲突语义或 BIST 签核。

`make rtl-slang` 已能完整 elaborate 顶层，说明 support 端口宽度和连接匹配。RAM
读延迟敏感性测试中，异步读和两拍读都会在 PPS 加载阶段立即失败，只有一拍同步读
符合现有 RTL 状态机。默认用例中 line memory 没有发生同地址读写冲突；并且 payload
在写入 format buffer RAM 前已经于 byte 110 出错，因此该 RAM 和后续输出路径不是
首差异来源。缺少原厂 primitive 定义，尚不能把所有工艺相关行为视为签核完成。

## 尚未验证

当前端到端用例仅覆盖单 slice processor、4 pixel/cycle 和 48-bit 输出。后续应在
修复首差异后加入随机 backpressure、输入空泡、多 slice 以及 RGB/YUV 配置，并确认
归档缺失 SRAM 的真实读延迟和冲突语义。

不要将 lint 或 smoke 通过表述为完整 DSC 功能签核。
