#!/usr/bin/env bash
set -euo pipefail

status="${1:-}"
packaged="${2:-}"
last_phase="${3:-}"
arch="${4:-unknown}"

case "$status:$packaged:$last_phase" in
  finished:true:true|finished:true:false|running:false:false)
    echo "Build phase for $arch: status=$status, packaged=$packaged"
    ;;
  running:false:true)
    echo "::error::Build for $arch is still running after the last allowed phase; the checkpoint was uploaded, but no release asset is available. Review the build logs before changing the phase limit." >&2
    exit 1
    ;;
  *)
    echo "::error::Invalid build phase outcome for $arch: status='$status', packaged='$packaged', last_phase='$last_phase'. Expected finished/true or running/false." >&2
    exit 1
    ;;
esac
