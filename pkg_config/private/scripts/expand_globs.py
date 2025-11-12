import glob
import json
import os
import sys


def _normalize(path):
    return os.path.normpath(path)


def main():
    if len(sys.argv) != 2:
        print("Usage: expand_globs.py <spec.json>", file=sys.stderr)
        return 1
    spec_path = sys.argv[1]
    with open(spec_path, "r", encoding="utf-8") as handle:
        patterns = json.load(handle)
    matches = []
    seen = set()
    for pattern in patterns:
        if not pattern:
            continue
        entries = glob.glob(pattern)
        if not entries:
            entries = [pattern]
        for entry in entries:
            if not os.path.isdir(entry):
                continue
            normalized = _normalize(entry)
            if normalized not in seen:
                seen.add(normalized)
                matches.append(normalized)
    print(json.dumps(matches))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
