# DSC 参考模型

这是 VESA DSC 1.2b 软件参考模型的整理版本。原始发行说明未改写，位于 `docs/`。

## 目录

- `src/`：可在 Linux 上用 GCC 编译的 C 源码及原始 Makefile。
- `config/`：当前 DSC 1.1/1.2 示例和 rate-control（RC）参数。
- `config/legacy/`：归档附带的旧版 pre-SCR 配置，仅供对照。
- `docs/`：原始使用说明和变更记录。
- `windows/`：原始 Visual Studio 工程及预编译 Windows x64 程序。

## cfg 文件含义

`test.cfg` 是一次编解码任务的主配置，指定 DSC 版本、输入列表、像素格式、切片参数和所选 RC 配置。`test_dsc_1_1.cfg` 是对应的 DSC 1.1 示例。

`rc_<bpc>bpc_<bpp>bpp[_420|_422].cfg` 是可被主配置通过 `INCLUDE` 引用的码率控制参数组：

- `bpc`：每个颜色分量的位深，如 8、10、12、14、16。
- `bpp`：目标压缩位率（bits per pixel）。
- `_420` / `_422`：原生色度采样模式；无后缀通常用于 RGB/4:4:4 或 simple 4:2:2。

这些文件包含量化范围、RC buffer 阈值、初始延迟等算法参数，不是测试图像。切换格式时，应同时调整主配置中的 `USE_YUV_INPUT`、`NATIVE_420`/`NATIVE_422` 和 `INCLUDE`。

## Linux 构建与运行

从仓库根目录执行：

```sh
make images
make model
make model-run
make model-clean
```

`make images` 默认在仓库的 `model/testdata/` 中生成 1920×1080 的 RGB PPM 规格图，包括纯黑、纯白、灰阶渐变、色条、棋盘格、单像素细线和固定种子噪声，并更新 `model/config/test_list.txt`。测试图是确定性生成的可再生产物，已被 Git 忽略；`make model-run` 会自动生成它们。列表使用相对路径，因此整个仓库可作为自包含测试 bundle 移动。也可自定义尺寸和目录：

```sh
python3 tools/generate_test_images.py --width 1280 --height 720 \
  --output /tmp/dsc-images --list-output /tmp/dsc-images.txt
```

`model-run` 会在 `model/config/` 中运行，以保持 `INCLUDE` 和 `SRC_LIST` 的原始相对路径语义。附带的 `test_list.txt` 只含占位图片名；运行前需换成实际 DPX/YUV/PPM 输入路径。Windows 工程不是 Linux 构建依赖。
