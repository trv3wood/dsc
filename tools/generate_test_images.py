#!/usr/bin/env python3
"""生成用于 DSC 编解码验证的确定性 PPM 测试图（支持 8/10/12/14/16 bpc）。

输出位深由 --bpc 决定：P6 头 maxval=(1<<bpc)-1，bpc>8 时每分量按大端写 2 字节，
与 model/src/utl.c 的 readppm 语义一致（maxval<=1023→10bpc，<=4095→12bpc…）。

默认参数保持 8bpc 1920×1080，与 model/config/test.cfg（SLICE_HEIGHT=108）匹配，
兼容 `make model-run`。4K 用例建议 --width 3840 --height 2160 单独输出目录 + 配套 cfg。
"""

from __future__ import annotations

import argparse
import os
import random
from pathlib import Path
from typing import Callable


Pixel = tuple[int, int, int]
Pattern = Callable[[int, int, int, int, int], Pixel]


def color_bars(x: int, _y: int, width: int, _height: int, maxval: int) -> Pixel:
    """生成八阶 RGB 色条，值域 0..maxval。"""
    colors = (
        (maxval, maxval, maxval),
        (maxval, maxval, 0),
        (0, maxval, maxval),
        (0, maxval, 0),
        (maxval, 0, maxval),
        (maxval, 0, 0),
        (0, 0, maxval),
        (0, 0, 0),
    )
    return colors[min(x * len(colors) // width, len(colors) - 1)]


def horizontal_gradient(x: int, _y: int, width: int, _height: int, maxval: int) -> Pixel:
    """生成覆盖完整码值范围的灰阶渐变。"""
    value = x * maxval // max(width - 1, 1)
    return value, value, value


def ramp_rgb(x: int, y: int, width: int, height: int, maxval: int) -> Pixel:
    """RGB 三分量各走独立斜率，完整覆盖动态范围并强制色度平面活跃。"""
    red = x * maxval // max(width - 1, 1)
    green = y * maxval // max(height - 1, 1)
    blue = maxval - red
    return red, green, blue


def checkerboard(x: int, y: int, _width: int, _height: int, maxval: int) -> Pixel:
    """生成 8×8 黑白棋盘格，用于刺激高频边缘。"""
    value = maxval if ((x // 8) + (y // 8)) % 2 else 0
    return value, value, value


def fine_lines(x: int, y: int, _width: int, height: int, maxval: int) -> Pixel:
    """交替生成单像素横线和竖线。"""
    if y < height // 2:
        value = maxval if x % 2 else 0
    else:
        value = maxval if y % 2 else 0
    return value, value, value


def make_flat_mix(rng: random.Random) -> Pattern:
    """flatness 混合图案：每行左 1/4 彩色噪声、右 3/4 平坦色。

    与 tests/verilator/generate_golden.py 的 `--pattern flatness` 分区方式对齐，
    用于覆盖 flatness 决策边界（噪声区触发 check、平坦区触发 flat QP）。
    """
    state = {"row": -1, "color": (0, 0, 0)}

    def flat_mix(x: int, y: int, width: int, _height: int, maxval: int) -> Pixel:
        if state["row"] != y:
            state["row"] = y
            state["color"] = tuple(
                rng.getrandbits(maxval.bit_length() - 1) for _ in range(3)
            )
        if x < max(width // 4, 1):
            return (
                rng.getrandbits(maxval.bit_length() - 1),
                rng.getrandbits(maxval.bit_length() - 1),
                rng.getrandbits(maxval.bit_length() - 1),
            )
        return state["color"]

    return flat_mix


def write_pattern(path: Path, width: int, height: int, maxval: int, pattern: Pattern) -> None:
    """逐行写入 P6 PPM，bpc>8 时每分量大端 2 字节，避免整帧常驻内存。"""
    components = 6 if maxval > 255 else 3
    two_bytes = maxval > 255
    with path.open("wb") as output:
        output.write(f"P6\n{width} {height}\n{maxval}\n".encode("ascii"))
        for y in range(height):
            row = bytearray()
            row.extend(
                byte for x in range(width)
                for pixel in (pattern(x, y, width, height, maxval),)
                for byte in _pack_sample(pixel, two_bytes)
            )
            output.write(row)


def _pack_sample(sample: Pixel, two_bytes: bool) -> tuple[int, ...]:
    if two_bytes:
        return (
            sample[0] >> 8, sample[0] & 0xFF,
            sample[1] >> 8, sample[1] & 0xFF,
            sample[2] >> 8, sample[2] & 0xFF,
        )
    return sample


def write_noise(path: Path, width: int, height: int, seed: int, bpc: int) -> None:
    """写入固定种子的随机噪声，保证可复现。

    8bpc 每分量 1 字节；bpc>8 每分量大端 2 字节。对 10/12/14bpc，用
    16-bit 随机值的低 N 位（2^bpc 整除 2^16，mask 后均匀无偏）。
    """
    generator = random.Random(seed)
    maxval = (1 << bpc) - 1
    with path.open("wb") as output:
        output.write(f"P6\n{width} {height}\n{maxval}\n".encode("ascii"))
        line_bytes = width * 3
        if bpc <= 8:
            for _ in range(height):
                output.write(generator.randbytes(line_bytes))
            return
        if bpc == 16:
            for _ in range(height):
                output.write(generator.randbytes(line_bytes * 2))
            return
        hi_trans = bytes(v & (maxval >> 8) for v in range(256))
        for _ in range(height):
            raw = generator.randbytes(line_bytes * 2)
            row = bytearray(line_bytes * 2)
            row[0::2] = raw[0::2].translate(hi_trans)
            row[1::2] = raw[1::2]
            output.write(row)


def parse_args() -> argparse.Namespace:
    repository = Path(__file__).resolve().parents[1]
    default_output = repository / "model" / "testdata"
    default_list = repository / "model" / "config" / "test_list.txt"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=default_output, help="输出目录")
    parser.add_argument("--list-output", type=Path, default=default_list, help="输入列表路径")
    parser.add_argument("--width", type=int, default=1920, help="图像宽度")
    parser.add_argument("--height", type=int, default=1080, help="图像高度")
    parser.add_argument("--bpc", type=int, choices=(8, 10, 12, 14, 16), default=8,
                        help="每分量位深（PPM maxval=(1<<bpc)-1，默认 8）")
    parser.add_argument("--seed", type=int, default=20260815, help="噪声随机种子")
    parser.add_argument(
        "--patterns",
        default="all",
        help="逗号分隔图案名（不含 .ppm）或 all",
    )
    args = parser.parse_args()
    if args.width <= 0 or args.height <= 0:
        parser.error("宽度和高度必须大于 0")
    return args


def generate(output_dir: Path, list_path: Path, width: int, height: int,
             bpc: int, seed: int, pattern_names: set[str] | None = None) -> list[Path]:
    """生成全部测试图并写出输入列表，返回生成的 PPM 路径列表。"""
    output_dir = output_dir.expanduser().resolve()
    list_path = list_path.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    list_path.parent.mkdir(parents=True, exist_ok=True)
    maxval = (1 << bpc) - 1

    noise_rng = random.Random(seed)
    patterns: dict[str, Pattern] = {
        "black.ppm": lambda _x, _y, _w, _h, mv: (0, 0, 0),
        "white.ppm": lambda _x, _y, _w, _h, mv: (mv, mv, mv),
        "gradient.ppm": horizontal_gradient,
        "ramp_rgb.ppm": ramp_rgb,
        "color_bars.ppm": color_bars,
        "checkerboard.ppm": checkerboard,
        "fine_lines.ppm": fine_lines,
        "flat_mix.ppm": make_flat_mix(noise_rng),
    }
    generated: list[Path] = []
    for filename, pattern in patterns.items():
        if pattern_names is not None and Path(filename).stem not in pattern_names:
            continue
        path = output_dir / filename
        write_pattern(path, width, height, maxval, pattern)
        generated.append(path)

    if pattern_names is None or "noise" in pattern_names:
        noise_path = output_dir / "noise.ppm"
        write_noise(noise_path, width, height, seed, bpc)
        generated.append(noise_path)

    available = {Path(name).stem for name in patterns} | {"noise"}
    if pattern_names is not None and pattern_names - available:
        raise ValueError(f"未知图案：{','.join(sorted(pattern_names - available))}")
    if not generated:
        raise ValueError("至少选择一个测试图案")

    relative_paths = (os.path.relpath(path, list_path.parent) for path in generated)
    list_path.write_text("".join(f"{path}\n" for path in relative_paths), encoding="utf-8")
    print(f"已生成 {len(generated)} 张 {width}×{height} {bpc}bpc PPM：{output_dir}")
    print(f"输入列表：{list_path}")
    return generated


def main() -> None:
    args = parse_args()
    selected = None if args.patterns == "all" else set(args.patterns.split(","))
    generate(args.output, args.list_output, args.width, args.height, args.bpc, args.seed,
             selected)


if __name__ == "__main__":
    main()
