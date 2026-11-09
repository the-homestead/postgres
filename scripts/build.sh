#!/usr/bin/env bash
# build.sh — build an image preset with docker buildx bake.
#
# Usage:
#   scripts/build.sh [target] [--load|--push] [extra bake args...]
#
# Examples:
#   scripts/build.sh                     # dev preset, loaded into the local daemon
#   scripts/build.sh full                # full preset for this machine's arch, loaded
#   scripts/build.sh full --push         # full preset, every platform, pushed
#   TAG=18-rc scripts/build.sh full --push
#
# --load only takes one platform, so multi-platform presets are narrowed to the
# local architecture when loading.
set -euo pipefail

cd "$(dirname "$0")/../container"

target="${1:-dev}"
[ $# -gt 0 ] && shift

mode="--load"
if [ "${1:-}" = "--load" ] || [ "${1:-}" = "--push" ]; then
    mode="$1"
    shift
fi

extra=()
if [ "$mode" = "--load" ]; then
    arch="$(docker version --format '{{.Server.Arch}}')"
    extra+=(--set "${target}.platform=linux/${arch}")
fi

echo ">>> docker buildx bake ${target} ${mode} ${extra[*]} $*"
exec docker buildx bake "$target" "$mode" "${extra[@]}" "$@"
