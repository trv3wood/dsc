#!/usr/bin/env python3
"""从 VESA 官方发布包提取固定 cropped BMP，并转换为 C model 可读的 PPM。"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import shutil
import subprocess
import zipfile
from pathlib import Path


DEFAULT_ARCHIVE = Path.home() / "Work/dsc/Display Stream Compression (DSC) Test Results-selected.zip"
DEFAULT_OUTPUT = Path("/tmp/dsc_official_images")
SELECTED_IMAGES = (
    "t_1280x768_Noise_128_x0",
    "t_CircularPatterns26_x0",
    "t_FineTextRendering14_x0",
    "t_Boats_x0",
    "t_s1_peacock_x0",
)


def ppm_dimensions(data: bytes) -> tuple[int, int]:
    """读取 bmptoppm 生成的 P6/P3 头部尺寸。"""
    tokens: list[bytes] = []
    for line in data.splitlines():
        line = line.split(b"#", 1)[0]
        tokens.extend(line.split())
        if len(tokens) >= 4:
            break
    if len(tokens) < 4 or tokens[0] not in (b"P6", b"P3"):
        raise RuntimeError("bmptoppm 未生成有效 PPM")
    return int(tokens[1]), int(tokens[2])


def prepare(archive: Path, output: Path) -> dict[str, Path]:
    converter = shutil.which("bmptoppm")
    if converter is None:
        raise RuntimeError("缺少 bmptoppm，请安装 apt 包 netpbm")
    archive = archive.expanduser().resolve()
    if not archive.is_file():
        raise FileNotFoundError(f"未找到 VESA 官方发布包：{archive}")
    output.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(archive) as outer:
        nested_data = outer.read("cropped_images.zip")
    converted: dict[str, Path] = {}
    with zipfile.ZipFile(io.BytesIO(nested_data)) as cropped:
        names = set(cropped.namelist())
        for stem in SELECTED_IMAGES:
            member = f"cropped_images/{stem}.bmp"
            if member not in names:
                raise RuntimeError(f"官方包缺少固定测试图：{member}")
            result = subprocess.run(
                [converter], input=cropped.read(member), capture_output=True, check=True
            )
            width, height = ppm_dimensions(result.stdout)
            if (width, height) != (200, 300):
                raise RuntimeError(f"{member} 尺寸异常：{width}x{height}")
            path = output / f"{stem}.ppm"
            path.write_bytes(result.stdout)
            converted[stem] = path

    manifest = {
        "source": str(archive),
        "source_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "converter": converter,
        "images": {name: str(path) for name, path in converted.items()},
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return converted


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    images = prepare(args.archive, args.output)
    print(f"已准备 {len(images)} 张 VESA 官方 cropped 图：{args.output}")


if __name__ == "__main__":
    main()
