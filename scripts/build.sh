#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="${1:-$(uname -m)}"
helium_version="$(tr -d '[:space:]' < "$root/helium-version.txt")"
checkout="$root/build/helium-macos"

case "$arch" in
  arm64|x86_64) ;;
  *) echo "Usage: $0 [arm64|x86_64]" >&2; exit 2 ;;
esac

if [ "$(uname -s)" != Darwin ]; then
  echo "Heliox can only be built on macOS." >&2
  exit 1
fi

if [ ! -d "$checkout/.git" ]; then
  mkdir -p "$root/build"
  git clone --branch "$helium_version" --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/imputnet/helium-macos.git "$checkout"
fi

git -C "$checkout" fetch --depth 1 origin "refs/tags/$helium_version:refs/tags/$helium_version"
git -C "$checkout" checkout --force "$helium_version"
git -C "$checkout" submodule update --init --force --depth 1
git -C "$checkout" checkout -- patches/series
git -C "$checkout/helium-chromium" checkout -- i18n

python3 "$root/scripts/overlay.py" "$checkout"

mkdir -p "$root/dist"
export OUT_DMG_PATH="$root/dist/heliox-$arch.dmg"
rm -f "$OUT_DMG_PATH"

(cd "$checkout" && ./build.sh "$arch")

(cd "$root/dist" && shasum -a 256 "heliox-$arch.dmg" > "heliox-$arch.dmg.sha256")
echo "Built $OUT_DMG_PATH"
