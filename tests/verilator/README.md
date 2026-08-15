# Verilator RTL Verification

## 已验证范围

`make rtl-lint` 对 `dsc_encoder` 顶层执行完整 elaboration 和 lint。归档中的 `dsce_quant.sv` 未被顶层引用，并依赖未定义类型，因此不在有效设计 filelist 中。

`make rtl-smoke` 构建并运行顶层自检 testbench，覆盖：

- 异步复位和三个时钟域的复位释放；
- APB 默认寄存器、只读能力寄存器和写后读回；
- 编码器关闭时的 192-bit bypass 数据一致性；
- AXI 输出 backpressure 期间 `valid` 和数据保持。

## 仿真假设

原始 RTL 包不含 `gprim_sync_stage`、`gprim_sync2_stage` 和 `gram_bist_1r1w`。`support/` 提供仅用于仿真的模型：同步器保留一拍/两拍延迟，RAM 使用同步读写，BIST 不建模。这些模型不能替代工艺库 CDC、冲突语义或 BIST 签核。

## 尚未验证

当前 smoke test 不配置 PPS，也不启动 DSC 编码核心，因此尚未覆盖预测、量化、码率控制、slice 调度和压缩 bitstream。完成算法级验证需要：

1. 从 C reference model 导出 128-byte PPS 和期望 DSC payload；
2. 根据用户指南确认 192-bit 输入像素排列、`tframe`/`tline` 语义；
3. 通过 APB 写入 PPS 和运行参数；
4. 收集每次 AXI 握手的有效输出字节，与 C model 逐字节比较；
5. 加入输出随机 backpressure、输入空泡及多种 RGB/YUV 配置。

不要将 lint 或 smoke 通过表述为完整 DSC 功能签核。
