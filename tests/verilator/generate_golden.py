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


def rgb_to_ycocg(pixel: tuple[int, int, int]) -> tuple[int, int, int]:
    """与 dsce_convert 的 8bpc 可逆 RGB->YCoCg 变换保持一致。"""
    red, green, blue = pixel
    co = red - blue
    temporary = blue + (co >> 1)
    cg = green - temporary
    return temporary + (cg >> 1), co + 256, cg + 256


def write_flatness_replay(
    generated: Path,
    pixels: list[tuple[int, int, int]],
    group_trace: Path,
) -> None:
    """生成独立 flatness function model 的逐组 replay 向量。"""
    groups_per_line = WIDTH // 3
    converted = [rgb_to_ycocg(pixel) for pixel in pixels]
    trace_rows = []
    for line in group_trace.read_text(encoding="ascii").splitlines():
        fields = dict(field.split("=", 1) for field in line.split())
        trace_rows.append({name: int(value) for name, value in fields.items() if name in {
            "line", "group", "qp", "first_flat", "flat_type", "orig_flat", "next_first_flat"
        }})

    if len(trace_rows) != HEIGHT * groups_per_line:
        raise RuntimeError("C group trace 长度与输入图像不一致")

    pixel_words: list[int] = []
    check_1_words: list[int] = []
    check_2_words: list[int] = []
    qps: list[int] = []
    flags: list[int] = []
    for line_index in range(HEIGHT):
        line_pixels = converted[line_index * WIDTH:(line_index + 1) * WIDTH]
        first_flat = -1
        flatness_type = 0
        previous_first_flat = -1
        previous_flatness_type = 0
        previous_is_flat = False

        def flatness_at(position: int, qp: int) -> int:
            if position + 1 >= WIDTH:
                return 0
            adjusted_qp = max(qp - 4, 0)
            qlevel_y = (0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 5, 6, 7)[adjusted_qp]
            qlevel_c = (0, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 8, 8, 8)[adjusted_qp]
            thresholds = (max(2, 1 << qlevel_y), max(2, 1 << qlevel_c), max(2, 1 << qlevel_c))
            for start, end in ((0, 4), (1, 7)):
                if start == 1 and position + 2 >= WIDTH:
                    return 0
                samples = line_pixels[position + start:min(position + end, WIDTH)]
                differences = tuple(max(sample[c] for sample in samples) - min(sample[c] for sample in samples) for c in range(3))
                if all(difference <= 2 for difference in differences):
                    return 2
                if all(difference <= thresholds[c] for c, difference in enumerate(differences)):
                    return 1
            return 0

        for group_index in range(groups_per_line):
            row = trace_rows[line_index * groups_per_line + group_index]
            qp = row["qp"]
            hpos = group_index * 3 + 2
            if group_index % 4 == 3:
                previous_is_flat = first_flat >= 0
                previous_first_flat = -1
                if 3 <= qp <= 12:
                    for candidate in range(4):
                        candidate_type = flatness_at(hpos + (candidate + 1) * 3, qp)
                        if not previous_is_flat and candidate_type:
                            previous_first_flat = candidate
                            previous_flatness_type = candidate_type - 1
                            break
                        previous_is_flat = bool(candidate_type)
            elif group_index % 4 == 0:
                first_flat = previous_first_flat
                flatness_type = previous_flatness_type

            original_flat = first_flat >= 0 and group_index % 4 == first_flat
            if group_index == groups_per_line - 1:
                original_flat = True
                flatness_type = 1

            # packed tDSC_FLAT_FLAGS: next, send, first[1:0], type, group_type[1:0], ICH
            next_flag = group_index % 4 == 3 and previous_first_flat >= 0
            send = group_index % 4 == 0 and first_flat >= 0
            group_type = (flatness_type + 2) if original_flat else 0
            packed_flags = (next_flag << 7) | (send << 6) | (group_type << 1)
            if send:
                packed_flags |= (first_flat << 4) | (flatness_type << 3)

            # 用 C trace 交叉验证模型移植，但 replay 期望来自上面的独立算法。
            # VLC 编码 group 0 时会清除 C state.flatnessType，故该字段不能作为
            # 检测模型的边界 oracle；其余状态仍可用于坐标和状态机交叉检查。
            if (first_flat, int(original_flat), previous_first_flat) != (
                row["first_flat"], row["orig_flat"], row["next_first_flat"]
            ):
                raise RuntimeError(
                    f"flatness model 与 C trace 不一致: line={line_index} group={group_index} "
                    f"model={(first_flat, int(original_flat), previous_first_flat)} "
                    f"c={(row['first_flat'], row['orig_flat'], row['next_first_flat'])}"
                )

            word = 0
            for lane, sample in enumerate(line_pixels[group_index * 3:group_index * 3 + 3]):
                word |= ((sample[0] << 32) | (sample[1] << 16) | sample[2]) << (lane * 48)
            pixel_words.append(word)
            group_start = group_index * 3
            check_1_samples = line_pixels[group_start + 2:min(group_start + 6, WIDTH)]
            check_2_samples = line_pixels[group_start + 3:min(group_start + 9, WIDTH)]
            check_1_samples += [line_pixels[-1]] * (4 - len(check_1_samples))
            check_2_samples += [line_pixels[-1]] * (6 - len(check_2_samples))
            differences = []
            for samples in (check_1_samples, check_2_samples):
                differences.append(tuple(
                    max(sample[component] for sample in samples) - min(sample[component] for sample in samples)
                    for component in range(3)
                ))
            check_1_words.append((differences[0][0] << 32) | (differences[0][1] << 16) | differences[0][2])
            check_2_words.append((differences[1][0] << 32) | (differences[1][1] << 16) | differences[1][2])
            qps.append(qp)
            flags.append(packed_flags)

    (generated / "flatness_pixels.hex").write_text("".join(f"{word:036x}\n" for word in pixel_words), encoding="ascii")
    (generated / "flatness_check1.hex").write_text("".join(f"{word:012x}\n" for word in check_1_words), encoding="ascii")
    (generated / "flatness_check2.hex").write_text("".join(f"{word:012x}\n" for word in check_2_words), encoding="ascii")
    (generated / "flatness_qp.hex").write_text("".join(f"{qp:02x}\n" for qp in qps), encoding="ascii")
    (generated / "flatness_expected.hex").write_text("".join(f"{flag:02x}\n" for flag in flags), encoding="ascii")


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
    write_flatness_replay(generated, pixels, group_trace)
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
