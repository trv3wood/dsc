# Verilator RTL 验证

这里的测试以冻结的官方 C model 为 golden，比较 RTL 编码 payload。C model 不随 RTL
修复修改；测试失败表示 RTL、配置桥接或 testbench 仍有问题，不能用更新 golden 消除失败。

## 常用入口

- `make rtl-lint`：展开并 lint `dsc_encoder` 的真实 RTL hierarchy。
- `make rtl-smoke`：验证 reset、APB、bypass 和 AXI backpressure，不比较 DSC bitstream。
- `make rtl-top`：生成默认向量并运行单 slice e2e 对拍。
- `make rtl-regression REGRESSION_PROFILE=quick`：运行快速 RTL case 矩阵。
- `make rtl-regression REGRESSION_PROFILE=full`：增加多 seed、多 slice、流控、位深和格式组合。
- `make rtl-regression REGRESSION_PROFILE=official`：从官方归档提取固定图像，运行官方向量回归。
- `make test REGRESSION_PROFILE=full`：运行 lint、smoke、RTL 和 C model 回归。

单独复现 case：

```sh
python3 tools/run_rtl_regression.py --profile full --cases two_slice_flow
```

RTL 日志位于 `/tmp/dsc_rtl_regression/`，C model 产物位于 `/tmp/dsc_regression/`。
`tests/verilator/generated/` 是忽略的临时目录，不应提交。

## Seed 与流控

`GOLDEN_SEED` 控制像素内容；`flow_seed` 控制输入空泡和输出背压。回归脚本默认从像素
seed 派生不同的流控 seed，避免数据模式和握手模式固定耦合。复现时必须同时记录 case、
像素 seed、流控 seed、输入空泡比例和输出停顿比例。

```sh
make rtl-top GOLDEN_SEED=0x1234 \
    RTL_RUN_ARGS='+flow_seed=17 +input_gap_pct=20 +output_stall_pct=30'
```

单个固定 seed 只用于稳定复现，不构成通过依据。合入 RTL 修复前至少运行 quick；涉及
跨 slice、CDC、FIFO 或 ready/valid 的修改应运行 full。

## Filelist 边界

`rtl.f` 只包含真实 RTL。`dsce_*_function_model.sv` 和 `tests/verilator/model/*.cpp` 是早期
DPI A/B 实验材料，不属于基线 hierarchy，也不由默认目标编译。若重新启用替换模型，
应建立独立目标和独立 filelist，不能把 adapter 混回 `rtl.f`。

## 当前状态

官方 RTL 回归尚未通过。已修复的子模块 replay 或较早 byte 的一致，只能缩小首分歧范围，
不能宣称 e2e 通过。当前重点是 normal flatness 对 QP 的调整和后续 syntax 流；观察到的
syntax FIFO overflow 可能是上游事务错误的次生现象。

不要在文档中长期维护逐提交修复流水账。已确认的行为应固化为 assertion、replay 或回归
case；短期调查结论放在 issue/commit message，避免与当前代码状态漂移。

## 定位方法

标准 e2e TB 只负责配置、激励、scoreboard、超时和结果摘要。需要波形时使用：

```sh
make rtl-top RTL_TRACE=1
```

VCD 生成到 `tests/verilator/generated/rtl_e2e_trace.vcd`。深层层级探针受
`DSC_E2E_DEBUG` 控制，默认回归不展开、不打印且不写定位日志。新的内部边界检查优先写成
独立 `tb_<module>_replay.sv` 或 formal property，不继续向 e2e TB 堆叠一次性探针。

已有 flatness replay：

```sh
make rtl-flatness-replay
```

Formal 默认验证 flatness transaction FIFO：

```sh
make rtl-formal FORMAL_SUITE=flatness_transaction_fifo FORMAL_TASK=prove
make rtl-formal FORMAL_SUITE=flatness_transaction_fifo FORMAL_TASK=cover
```

## PASS 标准

e2e PASS 必须同时满足：输入事务完整接受、mux 和顶层输出长度正确、payload 零 mismatch、
无 excess byte、无 timeout/overflow/assertion。function model 替换、golden 注入或只比较前缀
均不能作为 RTL 通过结论。
