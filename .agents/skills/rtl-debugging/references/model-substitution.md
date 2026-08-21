# Trusted model 替换实验

仅当替换模型的 transaction、reset、handshake 和 latency policy 已定义时使用。先以原 hierarchy
稳定复现，再一次只替换一个边界并运行完全相同的 case。

- 仍为同一 FAIL：该替换没有消除当前失效。
- PASS：模块或 wrapper/boundary interaction 成为主要嫌疑，不是单模块有错的证明。
- DIFFERENT FAILURE：先检查接口、事件顺序、latency、reset 和保持语义，不能继续下结论。

比较顺序是 transaction semantics、event index、event order、timing，最后才是内部 state。模型与 RTL
内部结构不等价时，不强迫 cycle-by-cycle probe 对齐。实验后恢复真实 RTL；若结论有价值，将边界契约
转成 replay/assertion。替换 adapter 使用独立 target 和 filelist，不得混入默认 `rtl.f`。
