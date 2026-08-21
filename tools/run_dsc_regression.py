#!/usr/bin/env python3
"""C model quick/full 编解码回归，覆盖图案、几何、位深和采样格式。"""

from __future__ import annotations

import argparse
import dataclasses
import math
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DSC_BIN = REPO / "model/src/dsc"
CONFIG_DIR = REPO / "model/config"
ROOT = Path("/tmp/dsc_regression")
SEED = 20260815
FOCUSED_PATTERNS = {"flat_mix", "noise"}

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_test_images as gti  # noqa: E402


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    width: int
    height: int
    slice_width: int
    slice_height: int
    bpc: int = 8
    bpp: int = 12
    pixel_format: str = "rgb"
    all_patterns: bool = False

    @property
    def rc_file(self) -> Path:
        suffix = "" if self.pixel_format == "rgb" else f"_{self.pixel_format}"
        return CONFIG_DIR / f"rc_{self.bpc}bpc_{self.bpp}bpp{suffix}.cfg"


QUICK_CASES = (
    Case("small_rgb", 96, 108, 96, 108, all_patterns=True),
    Case("small_2slice", 192, 108, 96, 108),
)
GEOMETRY_CASES = (
    Case("1080p_row", 1920, 1080, 0, 108),
    Case("1080p_2x1", 1920, 1080, 960, 108),
    Case("1440p_2x1", 2560, 1440, 1280, 144),
    Case("1440p_4x1", 2560, 1440, 640, 144),
    Case("2k_2x1", 2048, 1080, 1024, 108),
    Case("4k_4x1", 3840, 2160, 960, 108),
    Case("4k_dci_4x1", 4096, 2160, 1024, 108),
    Case("4k_4x1_sh8", 3840, 2160, 960, 8),
    Case("5k_4x1", 5120, 2880, 1280, 144),
    Case("8k_4x1", 7680, 4320, 1920, 108),
)
DEPTH_CASES = tuple(Case(f"depth_{bpc}bpc", 192, 112, 96, 112, bpc=bpc)
                    for bpc in (10, 12, 14, 16))
BPP_CASES = tuple(Case(f"rate_{bpp}bpp", 192, 112, 96, 112, bpp=bpp)
                  for bpp in (6, 8, 10, 15))
SUBSAMPLE_CASES = tuple(
    Case(f"native_{fmt}_{bpc}bpc", 192, 112, 96, 112,
         bpc=bpc, bpp=8, pixel_format=fmt)
    for fmt in ("422", "420") for bpc in (8, 10, 12, 16)
)


def write_cfg(path: Path, function: int, src_list: str, case: Case) -> None:
    lines = [
        "DSC_VERSION_MINOR 2", f"FUNCTION {function}", f"SRC_LIST {src_list}",
        "OUT_DIR .",
        f"SLICE_WIDTH {case.slice_width}" if case.slice_width else "//SLICE_WIDTH 0",
        f"SLICE_HEIGHT {case.slice_height}", "BLOCK_PRED_ENABLE 1", "VBR_ENABLE 0",
        "LINE_BUFFER_BPC 16", f"USE_YUV_INPUT {int(case.pixel_format != 'rgb')}",
        "SIMPLE_422 0", f"NATIVE_422 {int(case.pixel_format == '422')}",
        f"NATIVE_420 {int(case.pixel_format == '420')}", "FULL_ICH_ERR_PRECISION 0",
        f"INCLUDE {case.rc_file}", "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def run_dsc(cfg: Path, cwd: Path) -> tuple[int, str]:
    result = subprocess.run([str(DSC_BIN), "-F", str(cfg)], cwd=cwd,
                            capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def slice_total_from_log(log: str) -> int | None:
    counts = [int(match) for match in re.findall(r"Processing slice \d+ / (\d+)", log)]
    return max(counts) if counts else None


def psnr_sampled(ref_path: Path, out_path: Path, stride: int = 8) -> float:
    reference = ref_path.read_bytes()[8192::stride]
    output = out_path.read_bytes()[8192::stride]
    if not reference or len(reference) != len(output):
        return float("nan")
    mse = sum((a - b) ** 2 for a, b in zip(reference, output)) / len(reference)
    return 10 * math.log10(255 * 255 / mse) if mse else float("inf")


def expected_dsc_size(path: Path, case: Case) -> int | None:
    stream = path.read_bytes()
    if len(stream) < 132 or stream[:4] != b"DSCF":
        return None
    pps = stream[4:132]
    chunk_size = (pps[14] << 8) | pps[15]
    slices_per_line = case.width // case.slice_width if case.slice_width else 1
    return 132 + chunk_size * case.height * slices_per_line


def run_case(case: Case) -> dict[str, object]:
    case_dir = ROOT / case.name
    if case_dir.exists():
        shutil.rmtree(case_dir)
    case_dir.mkdir(parents=True)
    started = time.monotonic()
    failures: list[str] = []
    if not case.rc_file.exists():
        return {"case": case, "failures": [f"missing_rc={case.rc_file.name}"],
                "elapsed": 0.0}

    patterns = None if case.all_patterns else FOCUSED_PATTERNS
    generated = gti.generate(case_dir, case_dir / "src_list.txt", case.width, case.height,
                             case.bpc, SEED, patterns)
    stems = sorted(path.stem for path in generated)
    write_cfg(case_dir / "encode.cfg", 1, "src_list.txt", case)
    encode_rc, encode_log = run_dsc(case_dir / "encode.cfg", case_dir)
    (case_dir / "encode.log").write_text(encode_log, encoding="utf-8")
    if encode_rc:
        failures.append("encode")

    dsc_files = sorted(case_dir.glob("*.dsc"))
    if [path.stem for path in dsc_files] != stems:
        failures.append("dsc_set")
    for path in dsc_files:
        expected = expected_dsc_size(path, case)
        if expected is None or path.stat().st_size != expected:
            failures.append(f"size:{path.stem}")

    expected_slices = (case.width // case.slice_width if case.slice_width else 1) * (
        case.height // case.slice_height)
    if slice_total_from_log(encode_log) != expected_slices:
        failures.append("slice_log")

    if encode_rc == 0 and dsc_files:
        (case_dir / "decode_list.txt").write_text(
            "".join(f"{stem}.dsc\n" for stem in stems), encoding="utf-8")
        write_cfg(case_dir / "decode.cfg", 2, "decode_list.txt", case)
        decode_rc, decode_log = run_dsc(case_dir / "decode.cfg", case_dir)
        (case_dir / "decode.log").write_text(decode_log, encoding="utf-8")
        if decode_rc:
            failures.append("decode")
        for stem in stems:
            reference = case_dir / f"{stem}.ref.dpx"
            output = case_dir / f"{stem}.out.dpx"
            if not reference.exists() or not output.exists():
                failures.append(f"decode_file:{stem}")
            elif math.isnan(psnr_sampled(reference, output)):
                failures.append(f"psnr:{stem}")

    return {"case": case, "failures": failures,
            "elapsed": time.monotonic() - started}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("quick", "full"), default="quick")
    parser.add_argument("--parallel", type=int, default=2)
    parser.add_argument("--cases", help="只运行逗号分隔的 case 名")
    parser.add_argument("--quick", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.parallel <= 0:
        parser.error("--parallel 必须大于 0")

    cases = QUICK_CASES if args.profile == "quick" else (
        QUICK_CASES + GEOMETRY_CASES + DEPTH_CASES + BPP_CASES + SUBSAMPLE_CASES)
    if args.cases:
        requested = set(args.cases.split(","))
        known = {case.name for case in cases}
        if requested - known:
            parser.error(f"未知 case：{','.join(sorted(requested - known))}")
        cases = tuple(case for case in cases if case.name in requested)

    ROOT.mkdir(parents=True, exist_ok=True)
    # 重活在独立 dsc 子进程中，线程即可并发，且兼容禁用 fork 的沙箱/CI。
    with ThreadPoolExecutor(max_workers=args.parallel) as pool:
        results = list(pool.map(run_case, cases))

    rows, failed = [], False
    for result in results:
        case = result["case"]
        failures = result["failures"]
        status = "PASS" if not failures else "FAIL"
        failed |= bool(failures)
        row = (f"{status:4} {case.name:<22} {case.width}x{case.height} "
               f"{case.bpc}bpc/{case.bpp}bpp/{case.pixel_format} "
               f"{result['elapsed']:.1f}s failures={','.join(failures) or '-'}")
        print(row)
        rows.append(row)
    report = ROOT / "report.txt"
    report.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"报告：{report}")
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
