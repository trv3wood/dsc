#!/usr/bin/env python3
"""生成最小 RGB DSC 文件式对拍向量。"""

from __future__ import annotations

import argparse
import random
import subprocess
from pathlib import Path


WIDTH = 96
HEIGHT = 108
DEFAULT_SEED = 0x445343


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="生成可复现的 DSC 端到端测试向量")
    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=DEFAULT_SEED,
        help="伪随机 seed，支持十进制或 0x 十六进制（默认：0x445343）",
    )
    args = parser.parse_args()
    if args.seed < 0:
        parser.error("--seed 必须是非负整数")
    return args


def write_ppm(path: Path, seed: int) -> list[tuple[int, int, int]]:
    """使用固定 seed 生成可复现的伪随机 RGB 像素。"""
    generator = random.Random(seed)
    pixels = [
        (generator.randrange(256), generator.randrange(256), generator.randrange(256))
        for _ in range(WIDTH * HEIGHT)
    ]
    with path.open("wb") as output:
        output.write(f"P6\n{WIDTH} {HEIGHT}\n255\n".encode("ascii"))
        output.write(bytes(component for sample in pixels for component in sample))
    return pixels


def write_pixels(path: Path, pixels: list[tuple[int, int, int]]) -> None:
    """每行写一个 192-bit beat；8bpc 输入位于每个 16-bit 分量高字节。"""
    with path.open("w", encoding="ascii") as output:
        for index in range(0, len(pixels), 4):
            word = 0
            for lane, (red, green, blue) in enumerate(pixels[index:index + 4]):
                packed_pixel = (red << 40) | (green << 24) | (blue << 8)
                word |= packed_pixel << (lane * 48)
            output.write(f"{word:048x}\n")


def write_hex(path: Path, data: bytes) -> None:
    path.write_text("".join(f"{value:02x}\n" for value in data), encoding="ascii")


def main() -> None:
    args = parse_args()
    repository = Path(__file__).resolve().parents[2]
    generated = repository / "tests" / "verilator" / "generated"
    generated.mkdir(parents=True, exist_ok=True)
    source = generated / "rgb_96x108.ppm"
    pixels = write_ppm(source, args.seed)
    write_pixels(generated / "pixels.hex", pixels)

    config = generated / "golden.cfg"
    config.write_text(
        "\n".join(
            (
                "DSC_VERSION_MINOR 2",
                "FUNCTION 1",
                f"SRC_LIST {generated / 'source_list.txt'}",
                f"OUT_DIR {generated}",
                "SLICE_WIDTH 96",
                "SLICE_HEIGHT 108",
                "BLOCK_PRED_ENABLE 1",
                "VBR_ENABLE 0",
                "LINE_BUFFER_BPC 16",
                "USE_YUV_INPUT 0",
                "SIMPLE_422 0",
                "NATIVE_422 0",
                "NATIVE_420 0",
                "FULL_ICH_ERR_PRECISION 0",
                f"INCLUDE {repository / 'model/config/rc_8bpc_12bpp.cfg'}",
                "",
            )
        ),
        encoding="ascii",
    )
    (generated / "source_list.txt").write_text(f"{source}\n", encoding="ascii")

    subprocess.run(["make", "model"], cwd=repository, check=True)
    subprocess.run(
        [str(repository / "model/src/dsc"), "-F", str(config)],
        cwd=generated,
        check=True,
    )

    stream = (generated / "rgb_96x108.dsc").read_bytes()
    if stream[:4] != b"DSCF":
        raise RuntimeError("参考模型输出缺少 DSCF 文件头")
    pps = stream[4:132]
    payload = stream[132:]
    write_hex(generated / "pps.hex", pps)
    write_hex(generated / "expected_payload.hex", payload)
    (generated / "metadata.txt").write_text(
        f"width={WIDTH}\nheight={HEIGHT}\nbeats={len(pixels) // 4}\n"
        f"payload_bytes={len(payload)}\nseed=0x{args.seed:x}\n",
        encoding="ascii",
    )
    print(
        f"golden vector: PPS={len(pps)} bytes, payload={len(payload)} bytes, "
        f"seed=0x{args.seed:x}"
    )


if __name__ == "__main__":
    main()
