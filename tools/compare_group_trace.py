#!/usr/bin/env python3
"""比较官方 C 与 RTL group trace，报告首个编码语义字段分歧。"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


C_RE = re.compile(
    r"line=(?P<line>\d+) group=(?P<group>\d+) qp=(?P<qp>\d+) ich=(?P<ich>[01]).*? "
    r"u0=(?P<u0>-?\d+,-?\d+,-?\d+).*? "
    r"u1=(?P<u1>-?\d+,-?\d+,-?\d+).*? "
    r"u2=(?P<u2>-?\d+,-?\d+,-?\d+)"
)
RTL_RE = re.compile(
    r"g=(?P<tx>\d+) qp=(?P<qp>\d+) ich=(?P<ich>[01]) "
    r"r=(?P<r0>[0-9a-fA-F]+)/(?P<r1>[0-9a-fA-F]+)/(?P<r2>[0-9a-fA-F]+)"
)


def decode_pixel(word: str) -> tuple[int, int, int]:
    value = int(word, 16)
    result = []
    for shift in (34, 17, 0):
        field = (value >> shift) & 0x1FFFF
        result.append(field - 0x20000 if field & 0x10000 else field)
    return tuple(result)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("c_trace", type=Path)
    parser.add_argument("rtl_trace", type=Path)
    args = parser.parse_args()

    c_rows = []
    for line in args.c_trace.read_text(encoding="ascii").splitlines():
        match = C_RE.match(line)
        if not match:
            continue
        fields = match.groupdict()
        units = tuple(
            tuple(int(value) for value in fields[f"u{unit}"].split(","))
            for unit in range(3)
        )
        c_rows.append((
            int(fields["line"]),
            int(fields["group"]),
            int(fields["qp"]),
            int(fields["ich"]),
            units,
        ))

    compared = 0
    for line in args.rtl_trace.read_text(encoding="ascii").splitlines():
        match = RTL_RE.match(line)
        if not match:
            continue
        fields = match.groupdict()
        tx = int(fields["tx"])
        if tx >= len(c_rows):
            raise SystemExit(f"FAIL tx={tx} 超出 C trace 长度 {len(c_rows)}")
        c_line, c_group, c_qp, c_ich, c_units = c_rows[tx]
        rtl_qp = int(fields["qp"])
        rtl_ich = int(fields["ich"])
        rtl_pixels = tuple(decode_pixel(fields[f"r{sample}"]) for sample in range(3))
        rtl_units = tuple(
            tuple(rtl_pixels[sample][unit] for sample in range(3))
            for unit in range(3)
        )

        fields_diff = []
        if rtl_qp != c_qp:
            fields_diff.append(f"qp C/RTL={c_qp}/{rtl_qp}")
        if rtl_ich != c_ich:
            fields_diff.append(f"ich C/RTL={c_ich}/{rtl_ich}")
        for unit in range(3):
            if rtl_units[unit] != c_units[unit]:
                fields_diff.append(
                    f"u{unit} C/RTL={c_units[unit]}/{rtl_units[unit]}"
                )
        if fields_diff:
            raise SystemExit(
                f"FAIL tx={tx} line={c_line} group={c_group} " + "; ".join(fields_diff)
            )
        compared += 1

    if compared == 0:
        raise SystemExit("FAIL RTL trace 中没有可比较的 group 事务")
    print(f"PASS transactions={compared}")


if __name__ == "__main__":
    main()
