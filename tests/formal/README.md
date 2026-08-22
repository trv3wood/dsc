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
make rtl-formal FORMAL_SUITE=ich_decision_history FORMAL_TASK=prove
```

`ich_decision_history` 直接实例化 `dsce_ich_decision`，证明空泡期间输入即使抖动也
不会污染事务历史，并检查 start-of-slice 对历史状态的清零；当前执行 12 拍有界证明。

产物默认放在 `/tmp/dsc_formal/`
