#!/usr/bin/env python3
"""C model 多分辨率回归：覆盖常用分辨率与 slice 划分组合。

对每个用例：生成确定性测试图 -> 写 encode/decode cfg -> 跑 dsc -> 校验
.dsc 尺寸是否精确等于 132 + pix*bpp/8 -> （默认子集）解码回读计算 PSNR。
全部产出置于 /tmp/dsc_regression/<case>/，汇总报告写 /tmp/dsc_regression/report.txt。

PSNR 采用步进采样（stride=8）以加速大图计算；噪声/混合图案值仅作回归快照，
不设硬阈值（DSC 为有损编码）。
"""

from __future__ import annotations

import argparse
import math
import re
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DSC_BIN = REPO / "model/src/dsc"
RC_FILE = REPO / "model/config/rc_8bpc_12bpp.cfg"
ROOT = Path("/tmp/dsc_regression")
SEED = 20260815

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_test_images as gti  # noqa: E402

# (name, width, height, slice_width(0=每行整幅), slice_height, bpc)
CASES = [
    ("1080p_row",    1920, 1080,   0,    108, 8),  # 1080p 每行 1 slice（等价 test.cfg）
    ("1080p_2x1",    1920, 1080,   960,  108, 8),  # 1080p 每行 2 slice
    ("1440p_2x1",    2560, 1440,   1280, 144, 8),  # WQHD 每行 2
    ("1440p_4x1",    2560, 1440,   640,  144, 8),  # WQHD 每行 4
    ("2k_2x1",       2048, 1080,   1024, 108, 8),  # DCI 2K 每行 2
    ("4k_4x1",       3840, 2160,   960,  108, 8),  # UHD 每行 4
    ("4k_dci_4x1",   4096, 2160,   1024, 108, 8),  # DCI 4K 每行 4
    ("4k_4x1_sh8",   3840, 2160,   960,  8,    8),  # UHD slice height 8（典型实机）
    ("5k_4x1",       5120, 2880,   1280, 144, 8),  # 5K 每行 4
    ("8k_4x1",       7680, 4320,   1920, 108, 8),  # 8K 每行 4
]

DECODE_SUBSET = ("flat_mix", "noise")  # 默认回读的子集（含高动态 + 混合）
BPP = 12  # rc_8bpc_12bpp.cfg


def write_cfg(path: Path, function: int, src_list: str, out_dir: str, case) -> None:
    _name, _w, _h, slice_width, slice_height, _bpc = case
    lines = [
        "DSC_VERSION_MINOR\t2",
        f"FUNCTION\t{function}",
        f"SRC_LIST\t{src_list}",
        f"OUT_DIR\t{out_dir}",
    ]
    if slice_width:
        lines.append(f"SLICE_WIDTH\t{slice_width}")
    else:
        lines.append("//SLICE_WIDTH\t0\t// 每行 1 slice")
    lines += [
        f"SLICE_HEIGHT\t{slice_height}",
        "BLOCK_PRED_ENABLE\t1",
        "VBR_ENABLE\t0",
        "LINE_BUFFER_BPC\t16",
        "USE_YUV_INPUT\t0",
        "SIMPLE_422\t0",
        "NATIVE_422\t0",
        "NATIVE_420\t0",
        "FULL_ICH_ERR_PRECISION\t0",
        f"INCLUDE\t{RC_FILE}",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def run_dsc(cfg: Path, cwd: Path) -> tuple[int, str]:
    result = subprocess.run(
        [str(DSC_BIN), "-F", str(cfg)], cwd=cwd,
        capture_output=True, text=True,
    )
    return result.returncode, result.stdout + result.stderr


def slice_total_from_log(log: str) -> int | None:
    counts = [int(m) for m in re.findall(r"Processing slice \d+ / (\d+)", log)]
    return max(counts) if counts else None


def psnr_sampled(ref_path: Path, out_path: Path, stride: int = 8) -> tuple[float, float]:
    """DPX 参考/重建 PSNR（步进采样，stride 用于加速大图）。"""
    r = ref_path.read_bytes()[8192::stride]
    o = out_path.read_bytes()[8192::stride]
    n = min(len(r), len(o))
    mse = sum((a - b) * (a - b) for a, b in zip(r, o)) / n
    return (10 * math.log10(255 * 255 / mse), mse) if mse else (float("inf"), 0.0)


def run_case(case, quick: bool) -> dict:
    name, width, height, sw, sh, bpc = case
    case_dir = ROOT / name
    case_dir.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    gti.generate(case_dir, case_dir / "src_list.txt", width, height, bpc, SEED)

    enc_cfg = case_dir / "encode.cfg"
    write_cfg(enc_cfg, 1, "src_list.txt", ".", case)
    rc, log = run_dsc(enc_cfg, case_dir)
    enc_ok = rc == 0

    expected = width * height * BPP // 8 + 132
    dsc_files = sorted(case_dir.glob("*.dsc"))
    bad_size = {p.stem: p.stat().st_size for p in dsc_files if p.stat().st_size != expected}
    slices_log = slice_total_from_log(log)
    slices_expect = (width // sw if sw else 1) * (height // sh)
    slices_ok = slices_log is None or slices_log == slices_expect

    psnrs: dict[str, str] = {}
    dec_ok = False
    if enc_ok:
        stems = DECODE_SUBSET if quick else sorted(p.stem for p in dsc_files)
        dec_list = case_dir / "dec_list.txt"
        dec_list.write_text("".join(f"{s}.dsc\n" for s in stems), encoding="utf-8")
        write_cfg(case_dir / "decode.cfg", 2, "dec_list.txt", ".", case)
        rc_d, log_d = run_dsc(case_dir / "decode.cfg", case_dir)
        dec_ok = rc_d == 0
        if dec_ok:
            for s in stems:
                ref, out = case_dir / f"{s}.ref.dpx", case_dir / f"{s}.out.dpx"
                if ref.exists() and out.exists():
                    p, mse = psnr_sampled(ref, out)
                    psnrs[s] = f"{p:.2f}dB" if math.isfinite(p) else f"inf(mse={mse:.1f})"
                else:
                    psnrs[s] = "missing"

    elapsed = time.time() - t0
    return {
        "name": name, "w": width, "h": height, "sw": sw or width, "sh": sh,
        "slices": slices_expect, "enc_ok": enc_ok, "size_ok": not bad_size,
        "bad_size": bad_size, "slices_ok": slices_ok, "dec_ok": dec_ok,
        "psnrs": psnrs, "elapsed": elapsed,
    }


def format_row(r: dict) -> str:
    ok = all((r["enc_ok"], r["size_ok"], r["slices_ok"], r["dec_ok"]))
    psnr_tags = ",".join(f"{k}={v}" for k, v in r["psnrs"].items()) or "-"
    fails = []
    if not r["enc_ok"]:
        fails.append("enc")
    for s, size in (r["bad_size"] or {}).items():
        fails.append(f"{s}size")
    if not r["slices_ok"]:
        fails.append("slice")
    if not r["dec_ok"]:
        fails.append("dec")
    status = "OK " if ok else f"FAIL[{' '.join(fails)}]"
    return (f"{r['name']:<14} {r['w']:>5}x{r['h']:<5} slc={r['sw']}x{r['sh']}"
            f" nSl={r['slices']:>6} {status} psnr=({psnr_tags}) {r['elapsed']:>6.1f}s")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", default="all",
                        help="逗号分隔的用例名或 all（默认 all）")
    parser.add_argument("--parallel", type=int, default=2, help="并行用例数")
    parser.add_argument("--quick", action="store_true",
                        help="快速子集：解码回读只做 flat_mix+noise")
    args = parser.parse_args()

    selected = [c for c in CASES if args.cases == "all" or c[0] in args.cases.split(",")]
    if not selected:
        parser.error(f"没有匹配的用例，可选：{','.join(c[0] for c in CASES)}")

    ROOT.mkdir(parents=True, exist_ok=True)
    with ProcessPoolExecutor(max_workers=args.parallel) as pool:
        futures = [pool.submit(run_case, c, args.quick) for c in selected]
        results = [f.result() for f in futures]

    report = ROOT / "report.txt"
    lines_ = []
    for r in results:
        row = format_row(r)
        print(row)
        lines_.append(row)
    report.write_text("\n".join(lines_) + "\n", encoding="utf-8")
    all_ok = all(r["enc_ok"] and r["size_ok"] and r["slices_ok"] and r["dec_ok"] for r in results)
    print(f"\n总计 {len(results)} 用例，{'全部通过' if all_ok else '存在失败'}。"
          f"报告：{report}")


if __name__ == "__main__":
    main()