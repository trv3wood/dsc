---
name: lsp-navigation
description: >
  Use clangd (C model) and slang-server (SystemVerilog RTL) LSP for cross-file
  navigation, definition/usage lookup, hover type info, and read-time lint.
---

# LSP 代码导航（clangd + slang-server）

本 skill 是**可移植的操作纪律**，绑定到本仓库的 `LSP` 工具用法：RTL 跨文件跳转/引用、
C 参考模型的跳转/类型查询，以及打开文件时自动流出的 lint 诊断。具体工具版本、blocked
判据、已知限制一律以 `tests/verilator/README.md` 的"外部工具总结"表为**单一事实来源**，
使用前先 probe。

## 双服务器映射

| 扩展名 | LSP 服务器 | 数据来源 |
|---|---|---|
| `.sv` `.svh` `.v` `.vh` | slang-server（systemverilog-lsp 插件） | `.slang/server.json`（`flags: -f tests/verilator/rtl.f`，索引 `verilog_dsc/` + `tests/verilator/`） |
| `.c` `.h` | clangd（clangd-lsp 插件） | `compile_commands.json`（gitignored，`make model-compile-commands` 用 bear 生成） |

## 使用前准备（工具纪律）

- **slang-server**：配置 `.slang/server.json` 指向 `tests/verilator/rtl.f`，与 `make rtl-slang`
  同一 filelist。改 filelist / 新增 RTL 文件后，`make rtl-slang` 可作 CLI 对照确认 hierarchy 完整。
- **clangd**：依赖 `compile_commands.json`。该文件被 gitignore，首次使用前或改动
  `model/src` 构建选项/文件清单后，先运行 `make model-compile-commands`
  （`bear -- make -C model/src clean dsc`），否则 clangd 索引不到 C 符号。
- 工具缺失 = blocked：probe 失败如实标 blocked，换 grep/文本搜索路径，不得假装可用。

## 核心操作模式（本仓库均已验证）

| 操作 | 用途 | 备注 |
|---|---|---|
| `hover` | 类型别名→解析后类型+位宽；C 函数→签名+参数+doc | 定位最便宜，先读码用 |
| `goToDefinition` | 跳到定义（RTL 信号/端口/typedef，C 函数） | 跨文件优先 |
| `findReferences` | 找全部引用，返回 `file:line:col` | **跨文件导航首选**（比 workspaceSymbol 稳） |
| `documentSymbol` | 看单文件符号结构 | 快速建立文件地图 |
| `goToImplementation` | 找接口/抽象的实现 | 少见 |
| `workspaceSymbol` | 跨文件按名搜索 | ⚠️ 前端有解析 bug，见下 |
| `prepareCallHierarchy`/`incomingCalls`/`outgoingCalls` | 调用关系 | C 模型偶用 |

### 位置参数纪律（最容易踩的坑）

`LSP` 工具的位置是 **1-based 行号 + 1-based 字符列号**。符号定位前先 `Read` 该文件数准列：
- 缩进 4 空格 + `typedef logic signed [16:0] ` 后，`tDSC_RESIDUAL` 起始列 = 33。
- 无法一眼数清时，用 `awk '/symbol/{print NR": "index($0,"symbol")}' file` 拿到
  `行:列`；列号即 1-based 字符偏移，直接给 `character`。
- 光标不在符号上会返回 `No hover/definition found`——**这是正常现象**，换到符号上重试，
  不代表服务器没起来。

## 验证过的实例（2026-08-18）

- slang-server：`hover` `tDSC_RESIDUAL`（`dsce_defs_pkg.sv:307:33`）→
  `TypeAlias`，解析类型 `logic signed[16:0]`、宽度 17 + 定义源码片段。
- slang-server：`findReferences` `tDSC_RESIDUAL` → 50 处引用、9 个文件，
  逐条 `file:line:col`。
- clangd：`hover` `rgb2ycocg`（`dsc_utils.h:56:6`）→ 函数签名、参数展开为
  `struct pic_s *` 别名、doc 注释。
- 打开文件自动流出诊断：slang lint 警告（`sign-conversion`/`width-trunc`/`unused-port`…）
  与 clangd（`unused-includes`）随文件打开出现在 diagnostics 里。

## 已知限制与坑

- **`workspaceSymbol` 跨文件搜索在前端有解析 bug**（`l.location.range.start undefined`）。
  跨文件导航用 `findReferences`/`goToDefinition`；按名字跨文件搜用 grep 兜底。
- **C 源码是 CRLF + 非 ASCII 版权头**，grep 默认当二进制返回空。搜索用 `grep -a`
  （或 awk/`rg -a`）。clangd 对 CRLF 处理正常，不影响 LSP。
- **诊断 = read-time lint，不等于功能正确**。诊断流是读码时的低成本 lint 线索；
  验收仍以 `make rtl-e2e` golden 逐字节一致为准（见 rtl-debugging 硬约束）。
- RTL 里部分符号（如 `dsce_quant.sv`，不在顶层 filelist）可能不在索引内；
  slang 侧找不到定义时用 grep 查包/归档，别默认是 LSP 坏了。

## 与调试 skill 的配合

LSP 用于**定位**（信号定义/引用点、类型、跨模块连接）；定位完成后按
`rtl-debugging` 的纪律收敛首差异并修复。LSP 跳转找到的 `file:line` 只作
证据索引，不作功能正确性的证明——`只读代码不算验证`。
