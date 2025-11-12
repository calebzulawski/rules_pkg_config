import json
import os
import shutil
import sys


def _copy_file(src, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copy2(src, dest)


def _copy_dir(src, dest):
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    shutil.copytree(src, dest, symlinks=False, dirs_exist_ok=True)


def main():
    if len(sys.argv) != 2:
        print("Usage: mirror_paths.py <spec.json>", file=sys.stderr)
        return 1
    spec_path = sys.argv[1]
    with open(spec_path, "r", encoding="utf-8") as handle:
        entries = json.load(handle)
    for entry in entries:
        src = entry["src"]
        dest = entry["dest"]
        if not os.path.exists(src):
            raise FileNotFoundError(f"Host path '{src}' does not exist")
        if os.path.isfile(src):
            _copy_file(src, dest)
        else:
            _copy_dir(src, dest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
