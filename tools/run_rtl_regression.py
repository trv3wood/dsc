#!/usr/bin/env python3
"""运行确定性的 RTL 端到端 quick/full 回归矩阵。"""

from __future__ import annotations

import argparse
import dataclasses
import subprocess
import sys
import time
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
ROOT = Path("/tmp/dsc_rtl_regression")
DEFAULT_SEED = 0x445343


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    width: int = 96
    height: int = 108
    slice_width: int = 96
    slice_height: int = 108
    pattern: str = "random"
    pixel_seed: int = DEFAULT_SEED
    block_pred: int = 1
    input_gap_pct: int = 0
    output_stall_pct: int = 0
    flow_seed: int | None = None
    input_ppm: Path | None = None

    @property
    def effective_flow_seed(self) -> int:
        return self.flow_seed if self.flow_seed is not None else self.pixel_seed ^ 0x9E3779B9


QUICK_CASES = (
    Case("baseline"),
    Case("seed_1234", pixel_seed=0x1234),
    Case("seed_0", pixel_seed=0),
    Case("flat_bp_off", pattern="flat", pixel_seed=0, block_pred=0,
         input_gap_pct=20, output_stall_pct=35),
)

FULL_EXTRA_CASES = (
    Case("flatness", pattern="flatness"),
    Case("seed_1234_flow", pixel_seed=0x1234, input_gap_pct=15, output_stall_pct=20),
    Case("flatness_flow", pattern="flatness", input_gap_pct=10, output_stall_pct=25),
    Case("seed_0_bp_on", pixel_seed=0),
    Case("seed_1_bp_off", pixel_seed=1, block_pred=0, output_stall_pct=25),
    Case("seed_ffffffff", pixel_seed=0xFFFFFFFF, input_gap_pct=25, output_stall_pct=40),
    Case("two_slice", width=192, slice_width=96, pixel_seed=0x10203),
    Case("two_slice_flow", width=192, slice_width=96, pixel_seed=0x445344,
         input_gap_pct=15, output_stall_pct=30),
    Case("four_slice_burst", width=384, height=16, slice_width=96, slice_height=16,
         pixel_seed=0x556677, input_gap_pct=30, output_stall_pct=45),
    Case("two_by_two_slice", width=192, height=216, slice_width=96, slice_height=108,
         pattern="flatness", pixel_seed=0x89ABC, output_stall_pct=20),
)


def official_cases(images: dict[str, Path]) -> tuple[Case, ...]:
    cases = tuple(
        Case(f"vesa_{name[2:-3].lower()}", width=200, height=300,
             slice_width=200, slice_height=20, input_ppm=path)
        for name, path in images.items()
    )
    noise = images["t_1280x768_Noise_128_x0"]
    return cases + (
        Case("vesa_noise_bp_off", width=200, height=300, slice_width=200,
             slice_height=20, block_pred=0, input_ppm=noise),
    )


def run(command: list[str], *, log: Path | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=REPO, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if log is not None:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(result.stdout, encoding="utf-8")
    return result


def generate(case: Case) -> None:
    command = [
        sys.executable, "tests/verilator/generate_golden.py",
        "--case", case.name,
        "--width", str(case.width),
        "--height", str(case.height),
        "--slice-width", str(case.slice_width),
        "--slice-height", str(case.slice_height),
        "--pattern", case.pattern,
        "--seed", hex(case.pixel_seed),
        "--block-pred", str(case.block_pred),
    ]
    if case.input_ppm is not None:
        command += ["--input-ppm", str(case.input_ppm)]
    result = run(command, log=ROOT / "logs" / f"{case.name}.golden.log")
    if result.returncode:
        raise RuntimeError(f"{case.name}: golden 生成失败")


def build() -> Path:
    binary = ROOT / "obj" / "Vtb_dsc_e2e_multi"
    command = [
        "verilator", "--binary", "--timing", "--assert", "-Wall", "-Wno-fatal",
        "-Wno-WIDTH", "-Wno-UNUSED", "-Wno-IMPORTSTAR", "-Wno-PINCONNECTEMPTY",
        "-Wno-BLKSEQ", "-Wno-DECLFILENAME", "-Wno-GENUNNAMED", "-Wno-MULTIDRIVEN",
        "-Wno-TIMESCALEMOD", "--top-module", "tb_dsc_e2e_multi",
        "-f", "tests/verilator/rtl.f", "tests/verilator/tb_dsc_e2e_multi.sv",
        "--Mdir", str(ROOT / "obj"),
    ]
    result = run(command, log=ROOT / "logs" / "build.log")
    if result.returncode:
        raise RuntimeError("Verilator 构建失败")
    return binary


def execute(binary: Path, case: Case) -> tuple[bool, float, str]:
    command = [
        str(binary), f"+case={case.name}",
        f"+flow_seed={case.effective_flow_seed}",
        f"+input_gap_pct={case.input_gap_pct}",
        f"+output_stall_pct={case.output_stall_pct}",
    ]
    started = time.monotonic()
    result = run(command, log=ROOT / "logs" / f"{case.name}.rtl.log")
    elapsed = time.monotonic() - started
    ok = result.returncode == 0 and "PASS: RTL payload matches C model" in result.stdout
    reproduce = " ".join(command)
    return ok, elapsed, reproduce


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("quick", "full", "official"), default="quick")
    parser.add_argument("--cases", help="只运行逗号分隔的 case 名")
    parser.add_argument("--official-archive", type=Path,
                        help="VESA 官方测试结果 ZIP；official profile 使用")
    args = parser.parse_args()

    if args.profile == "official":
        from prepare_official_dsc_images import prepare, DEFAULT_ARCHIVE, DEFAULT_OUTPUT
        archive = args.official_archive or DEFAULT_ARCHIVE
        cases = official_cases(prepare(archive, DEFAULT_OUTPUT))
    else:
        cases = QUICK_CASES + (FULL_EXTRA_CASES if args.profile == "full" else ())
    if args.cases:
        selected = set(args.cases.split(","))
        cases = tuple(case for case in cases if case.name in selected)
        unknown = selected - {case.name for case in cases}
        if unknown:
            parser.error(f"未知 case：{','.join(sorted(unknown))}")

    ROOT.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []
    for case in cases:
        try:
            generate(case)
        except RuntimeError as error:
            print(f"FAIL {error}")
            failures.append(case.name)

    runnable = tuple(case for case in cases if case.name not in failures)
    binary = build() if runnable else ROOT / "obj" / "Vtb_dsc_e2e_multi"
    report_rows = []
    for case in runnable:
        ok, elapsed, reproduce = execute(binary, case)
        status = "PASS" if ok else "FAIL"
        print(f"{status:4} {case.name:<20} {elapsed:6.1f}s seed={case.pixel_seed:#x} "
              f"flow={case.effective_flow_seed:#x}")
        report_rows.append(f"{status} {case.name} {elapsed:.1f}s reproduce: {reproduce}")
        if not ok:
            failures.append(case.name)

    report = ROOT / "report.txt"
    report.write_text("\n".join(report_rows) + "\n", encoding="utf-8")
    print(f"报告：{report}")
    if failures:
        print(f"失败：{', '.join(failures)}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
