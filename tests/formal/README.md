# Flatness FIFO formal

`flatness_transaction_fifo_formal.sv` 抽取了 `dsce_slice.sv` 中
`FlatnessTransactionFifo` 的控制状态。它不验证 DSC 算法或 payload，只验证
slice 边界、push/pop 与本地事务计数之间的契约。

- `prove`：不要求 slice 边界前排空，证明 FIFO 不会上溢、下溢，且本地计数
  始终等于流水中的未完成事务数。
- `cover`：生成“带未完成事务跨过 slice 边界，随后旧事务安全返回”的最短轨迹。

运行：

```sh
make rtl-formal FORMAL_TASK=prove
make rtl-formal FORMAL_TASK=cover
make rtl-formal FORMAL_SUITE=flatness_window FORMAL_TASK=prove
make rtl-formal FORMAL_SUITE=stream_fifo_acceptance FORMAL_TASK=prove
make rtl-formal FORMAL_SUITE=stream_fifo_acceptance FORMAL_TASK=cover
```

产物默认放在 `/tmp/dsc_formal/`
