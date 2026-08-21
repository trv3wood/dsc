#!/usr/bin/env python3
"""重放 ICH history trace，检查 RTL 表状态是否符合官方模型的更新顺序。"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


UPDATE_RE = re.compile(
    r"UPD tx=(?P<tx>\d+) sel=(?P<sel>[01]) last=(?P<last>[01]) "
    r"recon=(?P<r0>[0-9a-f]+)/(?P<r1>[0-9a-f]+)/(?P<r2>[0-9a-f]+) "
    r"valid=(?P<valid>[0-9a-f]+) table=(?P<table>[0-9a-f,]+)$"
)


def update_history(table: list[int], valid: list[bool], recon: list[int], selected: bool) -> None:
    """实现官方 UpdateHistoryElement 对一个三像素 group 的顺序更新。"""
    for pixel in recon:
        location = 24
        for index in range(25):
            if not valid[index]:
                location = index
                break
            if selected and table[index] == pixel:
                location = index
                break
        for index in range(location, 0, -1):
            table[index] = table[index - 1]
            valid[index] = valid[index - 1]
        table[0] = pixel
        valid[0] = True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()

    expected_table = [0] * 25
    expected_valid = [False] * 25
    update_count = 0

    for line in args.trace.read_text(encoding="ascii").splitlines():
        match = UPDATE_RE.fullmatch(line)
        if not match:
            continue
        fields = match.groupdict()
        tx = int(fields["tx"])
        actual_table = [int(value, 16) for value in fields["table"].split(",")]
        valid_word = int(fields["valid"], 16)
        actual_valid = [bool(valid_word & (1 << index)) for index in range(25)]

        if actual_table != expected_table or actual_valid != expected_valid:
            for index, (actual, expected) in enumerate(zip(actual_table, expected_table)):
                if actual != expected or actual_valid[index] != expected_valid[index]:
                    raise SystemExit(
                        f"FAIL tx={tx} entry={index} "
                        f"expected={expected:012x}/{int(expected_valid[index])} "
                        f"actual={actual:012x}/{int(actual_valid[index])}"
                    )

        if fields["last"] == "0":
            recon = [int(fields[f"r{index}"], 16) for index in range(3)]
            update_history(expected_table, expected_valid, recon, fields["sel"] == "1")
            update_count += 1

    print(f"PASS updates={update_count}")


if __name__ == "__main__":
    main()
