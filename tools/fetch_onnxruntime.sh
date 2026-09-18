#!/usr/bin/env bash
# Fetch the ONNX Runtime the extension links against, into third_party/.
#
# The C API is plain C with C linkage (onnxruntime_c_api.h, OrtGetApiBase), so
# it cross-links from llvm-mingw against the MSVC import library exactly the way
# the Orbbec SDK does.
#
#   tools/fetch_onnxruntime.sh              # win-x64, the version below
#   tools/fetch_onnxruntime.sh linux-x64    # for the Linux build
set -euo pipefail

VERSION="${ORT_VERSION:-1.20.1}"
FLAVOUR="${1:-win-x64}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO/third_party/onnxruntime-$FLAVOUR"

if [[ -f "$DEST/include/onnxruntime_c_api.h" ]]; then
	echo "==> already unpacked: $DEST"
	exit 0
fi

mkdir -p "$REPO/third_party"
# Windows packages are zips, Linux and macOS ones are tarballs.
ext="zip"
case "$FLAVOUR" in linux*|osx*) ext="tgz" ;; esac
url="https://github.com/microsoft/onnxruntime/releases/download/v${VERSION}/onnxruntime-${FLAVOUR}-${VERSION}.${ext}"
echo "==> $url"
tmp="$(mktemp -d)"
curl -fL --progress-bar -o "$tmp/ort.$ext" "$url"
mkdir -p "$tmp/unpacked"
if [[ "$ext" == "zip" ]]; then unzip -q "$tmp/ort.zip" -d "$tmp/unpacked"; else tar xzf "$tmp/ort.tgz" -C "$tmp/unpacked"; fi
inner="$(find "$tmp/unpacked" -maxdepth 1 -mindepth 1 -type d | head -1)"
rm -rf "$DEST"
mv "$inner" "$DEST"
rm -rf "$tmp"
echo "==> unpacked to $DEST"
ls "$DEST"
