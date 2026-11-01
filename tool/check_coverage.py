"""Enforce line coverage from Flutter's LCOV report without extra dependencies."""
import argparse
import math
from pathlib import Path


def line_coverage(path: Path) -> tuple[int, int]:
    lines = {}
    source = None
    for entry in path.read_text(encoding="utf-8").splitlines():
        if entry.startswith("SF:"):
            if source is not None or not entry[3:]:
                raise ValueError("invalid LCOV source record")
            source = entry[3:]
        elif entry.startswith("DA:"):
            if source is None:
                raise ValueError("LCOV line has no source")
            number, hits, *_ = entry[3:].split(",")
            number, hits = int(number), int(hits)
            if number < 1 or hits < 0:
                raise ValueError("invalid LCOV line counts")
            key = (source, number)
            lines[key] = lines.get(key, False) or hits > 0
        elif entry == "end_of_record":
            if source is None:
                raise ValueError("LCOV record has no source")
            source = None
    if source is not None or not lines:
        raise ValueError("empty or incomplete LCOV report")
    return sum(lines.values()), len(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--minimum", type=float, required=True)
    args = parser.parse_args()
    if not math.isfinite(args.minimum) or not 0 <= args.minimum <= 100:
        parser.error("minimum must be between 0 and 100")
    try:
        covered, total = line_coverage(args.report)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    percent = 100 * covered / total
    print(f"Flutter line coverage: {covered}/{total} = {percent:.2f}% (minimum {args.minimum:g}%)")
    return 0 if percent >= args.minimum else 1


if __name__ == "__main__":
    raise SystemExit(main())
