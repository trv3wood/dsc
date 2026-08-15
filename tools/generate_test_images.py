#!/usr/bin/env python3
"""生成用于 DSC 编解码验证的确定性 RGB PPM 测试图。"""

from __future__ import annotations

import argparse
import os
import random
from pathlib import Path
from typing import Callable


Pixel = tuple[int, int, int]
Pattern = Callable[[int, int, int, int], Pixel]


def color_bars(x: int, _y: int, width: int, _height: int) -> Pixel:
    """生成八阶 RGB 色条。"""
    colors = (
        (255, 255, 255),
        (255, 255, 0),
        (0, 255, 255),
        (0, 255, 0),
        (255, 0, 255),
        (255, 0, 0),
        (0, 0, 255),
        (0, 0, 0),
    )
    return colors[min(x * len(colors) // width, len(colors) - 1)]


def horizontal_gradient(x: int, _y: int, width: int, _height: int) -> Pixel:
    """生成覆盖完整 8 bit 码值的灰阶渐变。"""
    value = x * 255 // max(width - 1, 1)
    return value, value, value


def checkerboard(x: int, y: int, _width: int, _height: int) -> Pixel:
    """生成 8×8 黑白棋盘格，用于刺激高频边缘。"""
    value = 255 if ((x // 8) + (y // 8)) % 2 else 0
    return value, value, value


def fine_lines(x: int, y: int, _width: int, _height: int) -> Pixel:
    """交替生成单像素横线和竖线。"""
    if y < _height // 2:
        value = 255 if x % 2 else 0
    else:
        value = 255 if y % 2 else 0
    return value, value, value


def write_pattern(path: Path, width: int, height: int, pattern: Pattern) -> None:
    """逐行写入 P6 PPM，避免保存整帧占用过多内存。"""
    with path.open("wb") as output:
        output.write(f"P6\n{width} {height}\n255\n".encode("ascii"))
        for y in range(height):
            row = bytearray()
            for x in range(width):
                row.extend(pattern(x, y, width, height))
            output.write(row)


def write_noise(path: Path, width: int, height: int, seed: int) -> None:
    """写入固定种子的随机噪声，保证测试结果可复现。"""
    generator = random.Random(seed)
    with path.open("wb") as output:
        output.write(f"P6\n{width} {height}\n255\n".encode("ascii"))
        for _ in range(height):
            output.write(generator.randbytes(width * 3))


def parse_args() -> argparse.Namespace:
    repository = Path(__file__).resolve().parents[1]
    default_output = repository / "model" / "testdata"
    default_list = repository / "model" / "config" / "test_list.txt"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=default_output, help="输出目录")
    parser.add_argument("--list-output", type=Path, default=default_list, help="输入列表路径")
    parser.add_argument("--width", type=int, default=1920, help="图像宽度")
    parser.add_argument("--height", type=int, default=1080, help="图像高度")
    parser.add_argument("--seed", type=int, default=20260815, help="噪声随机种子")
    args = parser.parse_args()
    if args.width <= 0 or args.height <= 0:
        parser.error("宽度和高度必须大于 0")
    return args


def main() -> None:
    args = parse_args()
    output_dir = args.output.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    patterns: dict[str, Pattern] = {
        "black.ppm": lambda _x, _y, _w, _h: (0, 0, 0),
        "white.ppm": lambda _x, _y, _w, _h: (255, 255, 255),
        "gradient.ppm": horizontal_gradient,
        "color_bars.ppm": color_bars,
        "checkerboard.ppm": checkerboard,
        "fine_lines.ppm": fine_lines,
    }
    generated: list[Path] = []
    for filename, pattern in patterns.items():
        path = output_dir / filename
        write_pattern(path, args.width, args.height, pattern)
        generated.append(path)

    noise_path = output_dir / "noise.ppm"
    write_noise(noise_path, args.width, args.height, args.seed)
    generated.append(noise_path)

    list_path = args.list_output.expanduser().resolve()
    list_path.parent.mkdir(parents=True, exist_ok=True)
    relative_paths = (os.path.relpath(path, list_path.parent) for path in generated)
    list_path.write_text("".join(f"{path}\n" for path in relative_paths), encoding="utf-8")
    print(f"已生成 {len(generated)} 张 {args.width}×{args.height} PPM：{output_dir}")
    print(f"输入列表：{list_path}")


if __name__ == "__main__":
    main()
