#!/usr/bin/env python3
"""生成最小 RGB DSC 文件式对拍向量。"""

from __future__ import annotations

import argparse
import os
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
    parser.add_argument(
        "--block-pred",
        type=int,
        choices=(0, 1),
        default=1,
        help="C model BLOCK_PRED_ENABLE（默认：1）",
    )
    parser.add_argument(
        "--pattern",
        choices=("random", "flat", "flatness"),
        default="random",
        help="输入图案（flatness 混合噪声与平坦区域，用于覆盖 flatness 决策）",
    )
    args = parser.parse_args()
    if args.seed < 0:
        parser.error("--seed 必须是非负整数")
    return args


def write_ppm(path: Path, seed: int, pattern: str) -> list[tuple[int, int, int]]:
    """生成可复现的伪随机或纯色 RGB 像素。"""
    generator = random.Random(seed)
    if pattern == "flat":
        sample = tuple(generator.randrange(256) for _ in range(3))
        pixels = [sample for _ in range(WIDTH * HEIGHT)]
    elif pattern == "flatness":
        flat_sample = tuple(generator.randrange(256) for _ in range(3))
        pixels = []
        for _line in range(HEIGHT):
            pixels.extend(
                (generator.randrange(256), generator.randrange(256), generator.randrange(256))
                if column < WIDTH // 4 else flat_sample
                for column in range(WIDTH)
            )
    else:
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


def split_mux_trace(trace_path: Path, generated: Path) -> list[int]:
    """把 C model mux trace 拆成与 RTL 48-bit 数值方向一致的三个子流。"""
    muxwords: list[list[int]] = [[], [], []]
    for line in trace_path.read_text(encoding="ascii").splitlines():
        fields = dict(field.split("=", 1) for field in line.split())
        ssp = int(fields["ssp"])
        stream_bytes = bytes.fromhex(fields["data"])
        muxwords[ssp].append(int.from_bytes(stream_bytes, byteorder="little"))
    for ssp, words in enumerate(muxwords):
        (generated / f"expected_ssp{ssp}_muxwords.hex").write_text(
            "".join(f"{word:012x}\n" for word in words), encoding="ascii"
        )
    return [len(words) for words in muxwords]


def split_vlc_trace(trace_path: Path, generated: Path) -> list[int]:
    """把 C model VLC 调用序列编码为 {size[4:0], data[15:0]}。"""
    fragments: list[list[int]] = [[], [], []]
    for line in trace_path.read_text(encoding="ascii").splitlines():
        fields = dict(field.split("=", 1) for field in line.split())
        ssp = int(fields["ssp"])
        packed = (int(fields["size"]) << 16) | int(fields["data"], 16)
        fragments[ssp].append(packed)
    for ssp, values in enumerate(fragments):
        (generated / f"expected_ssp{ssp}_vlc.hex").write_text(
            "".join(f"{value:06x}\n" for value in values), encoding="ascii"
        )
    return [len(values) for values in fragments]


def main() -> None:
    args = parse_args()
    repository = Path(__file__).resolve().parents[2]
    generated = repository / "tests" / "verilator" / "generated"
    generated.mkdir(parents=True, exist_ok=True)
    source = generated / "rgb_96x108.ppm"
    pixels = write_ppm(source, args.seed, args.pattern)
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
                f"BLOCK_PRED_ENABLE {args.block_pred}",
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
    mux_trace = generated / "c_mux_trace.txt"
    vlc_trace = generated / "c_vlc_trace.txt"
    group_trace = generated / "c_group_trace.txt"
    rate_trace = generated / "c_rate_trace.txt"
    model_environment = os.environ.copy()
    model_environment["DSC_MUX_TRACE"] = str(mux_trace)
    model_environment["DSC_VLC_TRACE"] = str(vlc_trace)
    model_environment["DSC_GROUP_TRACE"] = str(group_trace)
    model_environment["DSC_RATE_TRACE"] = str(rate_trace)
    subprocess.run(
        [str(repository / "model/src/dsc"), "-F", str(config)],
        cwd=generated,
        env=model_environment,
        check=True,
    )
    muxword_counts = split_mux_trace(mux_trace, generated)
    vlc_counts = split_vlc_trace(vlc_trace, generated)

    stream = (generated / "rgb_96x108.dsc").read_bytes()
    if stream[:4] != b"DSCF":
        raise RuntimeError("参考模型输出缺少 DSCF 文件头")
    pps = stream[4:132]
    payload = stream[132:]
    write_hex(generated / "pps.hex", pps)
    write_hex(generated / "expected_payload.hex", payload)
    (generated / "metadata.txt").write_text(
        f"width={WIDTH}\nheight={HEIGHT}\nbeats={len(pixels) // 4}\n"
        f"payload_bytes={len(payload)}\nseed=0x{args.seed:x}\npattern={args.pattern}\n"
        f"block_pred={args.block_pred}\n"
        f"ssp_muxwords={','.join(str(count) for count in muxword_counts)}\n"
        f"ssp_vlc_fragments={','.join(str(count) for count in vlc_counts)}\n",
        encoding="ascii",
    )
    print(
        f"golden vector: PPS={len(pps)} bytes, payload={len(payload)} bytes, "
        f"seed=0x{args.seed:x}, pattern={args.pattern}, block_pred={args.block_pred}"
    )


if __name__ == "__main__":
    main()
