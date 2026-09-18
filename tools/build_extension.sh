#!/usr/bin/env bash
# Build the OrbbecCamera + RtmPose GDExtension for Windows x86_64 - from Linux.
#
# The game runs on Windows (that is where the camera and the SDK live) but this
# machine has no MSVC, so the DLL is cross-compiled with llvm-mingw. That works
# because the Orbbec SDK's C++ API is header-only over a plain C export surface:
# there are no MSVC-mangled C++ symbols to link against.
#
# Everything it needs is fetched into third_party/ (gitignored) on first run:
# the SDK, the toolchain, and the godot-cpp submodule.
#
#   tools/build_extension.sh                    # template_release
#   TARGET=template_debug tools/build_extension.sh
#   JOBS=4 tools/build_extension.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ORBBEC_SDK_DIR:-$REPO/third_party/orbbec_sdk_win_x64}"
TOOLCHAIN="${MINGW_DIR:-$REPO/third_party/llvm-mingw}"
TARGET="${TARGET:-template_release}"
JOBS="${JOBS:-$(nproc)}"
export PATH="$HOME/.local/bin:$PATH"

if ! command -v scons >/dev/null; then
	# No pip or uv on the dev box: run SCons straight from its wheel.
	SCONS_DIR="$REPO/third_party/scons"
	if [[ ! -f "$SCONS_DIR/SCons/__init__.py" ]]; then
		echo "==> fetching scons"
		mkdir -p "$SCONS_DIR"
		whl=$(curl -fsSL https://pypi.org/pypi/SCons/json | python3 -c "import json,sys; d=json.load(sys.stdin); print([u['url'] for u in d['urls'] if u['filename'].endswith('.whl')][0])")
		curl -fsSL -o "$SCONS_DIR/scons.whl" "$whl"
		(cd "$SCONS_DIR" && unzip -o -q scons.whl)
	fi
	scons() { PYTHONPATH="$SCONS_DIR" python3 -c "import SCons.Script; SCons.Script.main()" "$@"; }
fi

[[ -f "$SDK/include/libobsensor/ObSensor.hpp" ]] || "$REPO/tools/fetch_orbbec_sdk.sh"
ORT="${ONNXRUNTIME_DIR:-$REPO/third_party/onnxruntime-win-x64}"
[[ -f "$ORT/include/onnxruntime_c_api.h" ]] || "$REPO/tools/fetch_onnxruntime.sh"

if [[ ! -x "$TOOLCHAIN/bin/x86_64-w64-mingw32-clang++" ]]; then
	echo "==> fetching llvm-mingw (a few hundred MB, once)"
	host="$(uname -m)"                       # aarch64 here, x86_64 in CI
	url=$(curl -fsSL "https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest" \
		| grep -o "https://[^\"]*ucrt-ubuntu[^\"]*${host}\.tar\.xz" | head -1)
	[[ -n "$url" ]] || { echo "no ${host} llvm-mingw asset found" >&2; exit 1; }
	mkdir -p "$REPO/third_party"
	tarball="$REPO/third_party/$(basename "$url")"
	[[ -f "$tarball" ]] || curl -fL --progress-bar -o "$tarball" "$url"
	rm -rf "$TOOLCHAIN" "$REPO/third_party/llvm-mingw-unpack"
	mkdir -p "$REPO/third_party/llvm-mingw-unpack"
	tar -xf "$tarball" -C "$REPO/third_party/llvm-mingw-unpack"
	mv "$(find "$REPO/third_party/llvm-mingw-unpack" -maxdepth 1 -mindepth 1 -type d | head -1)" "$TOOLCHAIN"
	rmdir "$REPO/third_party/llvm-mingw-unpack"
fi

[[ -f "$REPO/extension/godot-cpp/SConstruct" ]] || git -C "$REPO" submodule update --init --recursive

echo "==> building $TARGET with $(basename "$TOOLCHAIN"), -j$JOBS"
cd "$REPO/extension"
scons platform=windows arch=x86_64 target="$TARGET" \
	use_mingw=yes use_llvm=yes mingw_prefix="$TOOLCHAIN" \
	orbbec_sdk="$SDK" onnxruntime="$ORT" -j"$JOBS"

echo "==> built:"
ls -la "$REPO/game/bin/windows/" | head -20
[[ -f "$REPO/game/bin/windows/liborbbecwizard.windows.template_release.x86_64.dll" ]] || { echo "build failed" >&2; exit 1; }
