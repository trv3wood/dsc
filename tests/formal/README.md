# Flatness FIFO formal

`flatness_transaction_fifo_formal.sv` 抽取了 `dsce_slice.sv` 中
`FlatnessTransactionFifo` 的控制状态。它不验证 DSC 算法或 payload，只验证
slice 边界、push/pop 与本地事务计数之间的契约。

- `prove`：假设 slice 边界前预测流水已经排空，证明 FIFO 不会上溢、下溢，
  且本地计数始终等于流水中的未完成事务数。
- `cover`：允许 slice 边界到来时仍有未完成事务，寻找“清空 FIFO 后旧事务
  返回”的最短轨迹。该任务成功覆盖目标并生成 VCD，说明当前清空策略需要
  更强的上游排空保证，或者 RTL 不能在边界直接丢弃事务状态。

运行：

```sh
make rtl-formal
```

产物默认放在 `/tmp/dsc_formal/`
