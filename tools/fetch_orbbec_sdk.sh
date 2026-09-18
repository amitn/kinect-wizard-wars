#!/usr/bin/env bash
# Fetch the Orbbec SDK release the extension builds against.
#
# The SDK is not vendored: it is ~100 MB of binaries with its own licence, and
# the build only needs include/ and lib/ while the game only needs the runtime
# DLL and its extensions/ folder. This script puts an unpacked release in
# third_party/ (gitignored), which is what tools/build_extension.sh and the CI
# workflow both point at.
#
#   tools/fetch_orbbec_sdk.sh                # windows x64, the version below
#   ORBBEC_SDK_TAG=v2.9.3 tools/fetch_orbbec_sdk.sh linux_arm64
set -euo pipefail

TAG="${ORBBEC_SDK_TAG:-v2.9.3}"
FLAVOUR="${1:-win_x64}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO/third_party/orbbec_sdk_$FLAVOUR"

if [[ -f "$DEST/include/libobsensor/ObSensor.hpp" ]]; then
	echo "==> already unpacked: $DEST"
	exit 0
fi

mkdir -p "$REPO/third_party"
echo "==> looking up OrbbecSDK_v2 $TAG ($FLAVOUR)"
url=$(curl -fsSL "https://api.github.com/repos/orbbec/OrbbecSDK_v2/releases/tags/$TAG" \
	| grep -o "https://[^\"]*${FLAVOUR}\.zip" | head -1)
if [[ -z "$url" ]]; then
	echo "no ${FLAVOUR} asset on release $TAG" >&2
	exit 1
fi
echo "==> $url"
zip="$REPO/third_party/$(basename "$url")"
[[ -f "$zip" ]] || curl -fL --progress-bar -o "$zip" "$url"

# The Windows releases are zipped with backslash separators, which unzip(1)
# turns into files with backslashes in their names rather than directories.
python3 - "$zip" "$DEST" <<'PYEOF'
import os, shutil, sys, zipfile

src, dest = sys.argv[1], sys.argv[2]
if os.path.isdir(dest):
    shutil.rmtree(dest)
with zipfile.ZipFile(src) as z:
    names = [i.filename.replace("\\", "/") for i in z.infolist()]
    # Releases wrap everything in one folder; strip it so include/ is at the top.
    tops = {n.split("/", 1)[0] for n in names if "/" in n}
    strip = tops.pop() + "/" if len(tops) == 1 else ""
    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        if name.endswith("/"):
            continue
        rel = name[len(strip):] if strip and name.startswith(strip) else name
        out = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with z.open(info) as f, open(out, "wb") as o:
            shutil.copyfileobj(f, o)
print("unpacked", sum(1 for _ in names), "entries")
PYEOF
echo "==> unpacked to $DEST"
ls "$DEST"
