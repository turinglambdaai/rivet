#!/usr/bin/env python3
"""Build a binary libFuzzer seed corpus from Rivet's shared golden vectors."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


def safe_name(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", text).strip("-") or "case"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path, help="directory to receive binary corpus files")
    parser.add_argument(
        "--fixture",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "tests" / "protocol-golden.txt",
        help="shared protocol-golden.txt fixture",
    )
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    created = 0
    for line_number, raw_line in enumerate(
        args.fixture.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) != 3:
            raise SystemExit(f"invalid fixture line {line_number}: {raw_line}")
        kind, name, encoded_hex = parts
        try:
            payload = bytes.fromhex(encoded_hex)
        except ValueError as error:
            raise SystemExit(f"invalid fixture hex on line {line_number}: {error}") from error

        filename = f"{created:03d}-{safe_name(kind)}-{safe_name(name)}"
        (args.output / filename).write_bytes(payload)
        created += 1

    if created == 0:
        raise SystemExit("protocol fixture produced no fuzz seeds")
    print(f"wrote {created} fuzz seeds to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
