#!/usr/bin/env bash
set -euxo pipefail

arch="$1"
workspace="$(pwd)"
source_dir="$workspace/build/src"

if [ -f "$workspace/build_finished_$arch.log" ]; then
  mkdir -p "$workspace/release_asset"
  export OUT_DMG_PATH="$workspace/release_asset/heliox-$arch.dmg"
  (cd "$source_dir" && xattr -cs out/Default/Helium.app && "$workspace/sign_and_package_app.sh")
  (cd "$workspace/release_asset" && shasum -a 256 "heliox-$arch.dmg" > "heliox-$arch.dmg.sha256")
  echo "packaged=true" >> "$GITHUB_OUTPUT"
else
  gsync --file-system "$source_dir"
  tar -C build -c -f - src | zstd -11 -T0 -o build_src.tar.zst
  sha256sum ./build_src.tar.zst > ./sums.txt
  mkdir -p upload_part_build
  mv build_src.tar.zst sums.txt upload_part_build/
  echo "packaged=false" >> "$GITHUB_OUTPUT"
fi

mkdir -p upload_logs
cp ./*.log upload_logs/
