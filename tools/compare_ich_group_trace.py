#!/usr/bin/env python3
"""按语义比较 C group trace 与 RTL ICH 窗口，不比较 miss 样本的 stale index。"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


C_RE = re.compile(
    r".*? ich=(?P<select>[01]) ichidx=(?P<i0>\d+),(?P<i1>\d+),(?P<i2>\d+) "
    r"qhit=(?P<h0>[01])(?P<h1>[01])(?P<h2>[01])"
)
RTL_RE = re.compile(
    r"PRED tx=(?P<tx>\d+) qp=\d+ .*?hit=(?P<hit>[01]{3}) "
    r"idx=(?P<i0>\d+)/(?P<i1>\d+)/(?P<i2>\d+) sel=(?P<select>[01])"
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("c_trace", type=Path)
    parser.add_argument("rtl_trace", type=Path)
    args = parser.parse_args()

    c_rows = []
    for line in args.c_trace.read_text(encoding="ascii").splitlines():
        match = C_RE.match(line)
        if match:
            fields = match.groupdict()
            c_rows.append((
                int(fields["select"]),
                tuple(int(fields[f"h{index}"]) for index in range(3)),
                tuple(int(fields[f"i{index}"]) for index in range(3)),
            ))

    compared = 0
    for line in args.rtl_trace.read_text(encoding="ascii").splitlines():
        match = RTL_RE.match(line)
        if not match:
            continue
        fields = match.groupdict()
        tx = int(fields["tx"])
        rtl_hit_word = int(fields["hit"], 2)
        rtl_hits = tuple((rtl_hit_word >> index) & 1 for index in range(3))
        rtl_indices = tuple(int(fields[f"i{index}"]) for index in range(3))
        rtl_select = int(fields["select"])
        c_select, c_hits, c_indices = c_rows[tx]

        if rtl_select != c_select or rtl_hits != c_hits:
            raise SystemExit(
                f"FAIL tx={tx} select C/RTL={c_select}/{rtl_select} "
                f"hit C/RTL={c_hits}/{rtl_hits}"
            )
        for sample in range(3):
            if c_hits[sample] and rtl_indices[sample] != c_indices[sample]:
                raise SystemExit(
                    f"FAIL tx={tx} sample={sample} hit index "
                    f"C/RTL={c_indices[sample]}/{rtl_indices[sample]}"
                )
        compared += 1

    if compared == 0:
        raise SystemExit("FAIL RTL trace 中没有可比较的 PRED 事务")
    print(f"PASS transactions={compared}")


if __name__ == "__main__":
    main()
