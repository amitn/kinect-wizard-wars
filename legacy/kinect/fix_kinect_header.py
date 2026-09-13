#!/usr/bin/env python3
"""Make the Kinect SDK 2.0 headers compile with clang/GCC (MinGW).

The MIDL-generated headers forward-declare enums (`typedef enum _X X;` before
`enum _X {...};`), which MSVC accepts but ISO C++ compilers reject. This copies
Kinect.h and Kinect.INPC.h into an output directory with each typedef moved
after its enum definition. Native MSVC builds do not need this.

    python3 fix_kinect_header.py <sdk inc dir> <output dir>
"""
import os
import re
import sys

PATTERN = re.compile(
    r"typedef enum (_\w+) (\w+);\s*\n(\s*\n)*enum \1\s*\{(.*?)\}\s*;",
    re.DOTALL,
)


def fix(text: str):
    return PATTERN.subn(lambda m: "enum %s {%s};\ntypedef enum %s %s;" % (m.group(1), m.group(4), m.group(1), m.group(2)), text)


def main(src_dir: str, out_dir: str) -> int:
    os.makedirs(out_dir, exist_ok=True)
    for name in ("Kinect.h", "Kinect.INPC.h"):
        src = os.path.join(src_dir, name)
        if not os.path.isfile(src):
            print("missing %s" % src)
            return 1
        with open(src, "r", encoding="utf-8", errors="replace") as f:
            fixed, count = fix(f.read())
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            f.write(fixed)
        print("%s: moved %d enum typedefs after their definitions" % (name, count))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
