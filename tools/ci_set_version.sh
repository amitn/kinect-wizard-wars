#!/usr/bin/env bash
# Stamp the build with its version. A `v1.2.3` tag is the version; any other
# build is "<project version>-dev.<commit>". The Windows exe metadata needs a
# purely numeric a.b.c.d, so that is derived from the same string.
#
#   tools/ci_set_version.sh            # in CI, reads GITHUB_REF / GITHUB_SHA
#   tools/ci_set_version.sh 1.2.3      # or name the version
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$REPO/game/project.godot"
presets="$REPO/game/export_presets.cfg"

base="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$project" | head -1)"
if [[ $# -ge 1 ]]; then
	version="$1"
elif [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
	version="${GITHUB_REF#refs/tags/v}"
else
	sha="${GITHUB_SHA:-$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo local)}"
	version="${base}-dev.${sha:0:7}"
fi
numeric="$(echo "$version" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
numeric="${numeric:-0.0.0}.0"

sed -i "s|^config/version=.*|config/version=\"$version\"|" "$project"
sed -i "s|^application/file_version=.*|application/file_version=\"$numeric\"|; s|^application/product_version=.*|application/product_version=\"$numeric\"|" "$presets"
echo "version $version (exe metadata $numeric)"
if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "GAME_VERSION=$version" >> "$GITHUB_ENV"
fi
