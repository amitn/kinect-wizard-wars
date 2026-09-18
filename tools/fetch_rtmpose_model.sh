#!/usr/bin/env bash
# Fetch an RTMPose ONNX model into game/models/ (gitignored, like the SDK).
#
# These are the MMDeploy SDK packages from the RTMPose model zoo: a zip with
# end2end.onnx inside. Only the pose model is needed - person boxes come from
# the depth blob tracker that is already in the extension, so there is no
# detector network to run.
#
#   tools/fetch_rtmpose_model.sh            # rtmpose-t, 256x192 (fastest)
#   tools/fetch_rtmpose_model.sh s          # rtmpose-s
set -euo pipefail

SIZE="${1:-t}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO/game/models"
case "$SIZE" in
	t) url="https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/onnx_sdk/rtmpose-t_simcc-body7_pt-body7_420e-256x192-026a1439_20230504.zip" ;;
	s) url="https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/onnx_sdk/rtmpose-s_simcc-body7_pt-body7_420e-256x192-acd4a1ef_20230504.zip" ;;
	m) url="https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/onnx_sdk/rtmpose-m_simcc-body7_pt-body7_420e-256x192-e48f03d0_20230504.zip" ;;
	*) echo "unknown size: $SIZE (t, s or m)" >&2; exit 2 ;;
esac

out="$DEST/rtmpose-$SIZE.onnx"
if [[ -f "$out" ]]; then
	echo "==> already have $out"
	exit 0
fi
mkdir -p "$DEST"
echo "==> $url"
tmp="$(mktemp -d)"
curl -fL --progress-bar -o "$tmp/model.zip" "$url"
unzip -q "$tmp/model.zip" -d "$tmp/unpacked"
onnx="$(find "$tmp/unpacked" -name "*.onnx" | head -1)"
[[ -n "$onnx" ]] || { echo "no .onnx inside the package" >&2; exit 1; }
cp "$onnx" "$out"
rm -rf "$tmp"
ls -la "$out"
