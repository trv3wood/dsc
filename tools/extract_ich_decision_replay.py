#!/usr/bin/env python3
"""把 e2e ICH decision 边界 trace 转成独立 replay 向量。"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


INPUT_RE = re.compile(
    r"ICH_INPUT tx=(?P<tx>\d+) cfg=(?P<bpc>\d+)/(?P<convert>[01])/(?P<version>\d+)/(?P<align>[01]{3}) "
    r"sos=(?P<sos>[01]) last=(?P<last>[01]) group=(?P<group>[0-9a-f]+/[0-9a-f]+/[0-9a-f]+) "
    r"flat=(?P<flat>[01]) vlc=(?P<vlc>\d+/\d+/\d+) ql=(?P<qy>\d+)/(?P<qc>\d+) "
    r"force=(?P<force>[01]) pvalid=(?P<pvalid>[01]) predict=(?P<predict>[0-9a-f]+/[0-9a-f]+/[0-9a-f]+) "
    r"residual=(?P<residual>\d+/\d+/\d+) hit=(?P<hit>[01]{3}) index=(?P<index>\d+/\d+/\d+) "
    r"pixel=(?P<pixel>[0-9a-f]+/[0-9a-f]+/[0-9a-f]+)$"
)
ICH_RE = re.compile(r"line=\d+ group=\d+ qp=\d+ ich=(?P<ich>[01])")


def append(value: int, width: int, field: int) -> tuple[int, int]:
    if field < 0 or field >= 1 << width:
        raise ValueError(f"字段 {field} 超出 {width} bit")
    return (value << width) | field, width


def integers(text: str, base: int = 10) -> list[int]:
    return [int(item, base) for item in text.split("/")]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("c_group_trace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--end-tx", type=int, default=None)
    args = parser.parse_args()

    expected = []
    for line in args.c_group_trace.read_text(encoding="ascii").splitlines():
        match = ICH_RE.match(line)
        if match:
            expected.append(int(match["ich"]))

    rows: list[tuple[int, int]] = []
    for line in args.trace.read_text(encoding="ascii").splitlines():
        match = INPUT_RE.match(line)
        if not match:
            continue
        fields = match.groupdict()
        tx = int(fields["tx"])
        if args.end_tx is not None and tx > args.end_tx:
            continue
        if tx != len(rows):
            raise ValueError(f"事务不连续：期望 tx={len(rows)}，实际 tx={tx}")
        if tx >= len(expected):
            raise ValueError(f"C trace 缺少 tx={tx} 的期望值")

        value = 0
        width = 0
        packed_fields = [
            (int(fields["bpc"]), 4),
            (int(fields["convert"]), 1),
            (int(fields["version"]), 4),
            (int(fields["align"], 2), 3),
            (int(fields["sos"]), 1),
            (int(fields["last"]), 1),
        ]
        packed_fields += [(item, 48) for item in integers(fields["group"], 16)]
        packed_fields += [(int(fields["flat"]), 1)]
        packed_fields += [(item, 5) for item in integers(fields["vlc"])]
        packed_fields += [(int(fields["qy"]), 5), (int(fields["qc"]), 5)]
        packed_fields += [(int(fields["force"]), 1), (int(fields["pvalid"]), 1)]
        packed_fields += [(item, 48) for item in integers(fields["predict"], 16)]
        packed_fields += [(item, 5) for item in integers(fields["residual"])]
        packed_fields += [(int(fields["hit"], 2), 3)]
        packed_fields += [(item, 5) for item in integers(fields["index"])]
        packed_fields += [(item, 48) for item in integers(fields["pixel"], 16)]
        packed_fields += [(expected[tx], 1)]
        for field, field_width in packed_fields:
            value, added = append(value, field_width, field)
            width += added
        if width != 508:
            raise AssertionError(f"replay 向量宽度错误：{width}")
        rows.append((tx, value))

    if not rows:
        raise ValueError("trace 中没有 ICH_INPUT 事务")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "".join(f"{value:0127x} // tx={tx}\n" for tx, value in rows),
        encoding="ascii",
    )
    print(f"WROTE {args.output} transactions={len(rows)} width=508")


if __name__ == "__main__":
    main()
