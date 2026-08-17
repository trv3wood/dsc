# DSC RTL Encoder

VESA DSC 1.2 编码器的 SystemVerilog RTL 实现（`verilog_dsc/`），
与 `model/` 下的 C 参考模型逐字节对拍验证。

## 目录

| 路径 | 说明 |
|---|---|
| `verilog_dsc/` | DSC 编码器 RTL，顶层 `dsc_encoder.sv`，模块 `dsce_*.sv` |
| `model/` | VESA DSC 1.2b C 参考模型（Linux 可编译） |
| `tests/verilator/` | Verilator 端到端对拍、flatness/bp replay 与验证文档 |
| `dsc_spec/`、`DSC v1.2b.pdf` | 规范参考 |

## 关键文档

- `tests/verilator/README.md` — RTL 验证范围与缺陷定位过程
- `tests/verilator/rtl_fix_log.md` — 从早期基线到 HEAD 的 RTL 修复清单

## 常用命令

```sh
make model               # 构建 C 参考模型
make rtl-lint            # Verilator lint/elaboration
make rtl-e2e             # 端到端 payload 逐字节对拍（默认 seed 0x445343）
make rtl-e2e GOLDEN_SEED=0x1234
make rtl-flatness-replay # flatness 边界 replay
make rtl-bp-replay       # BP vector replay
```

## 现状

固定用例（96×108、RGB 8bpc、12bpp、单 slice）下完整 RTL 与 C model
输出逐字节一致，flatness/bp replay 0 失配。尚未覆盖：随机
backpressure、输入空泡、多 slice 以及 YUV/其他位深配置。