#!/usr/bin/env bash
# Run on the target platform; packages the complete Flutter bundle and its PTY helper.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=macos ;;
  *) printf '%s\n' 'Run this script on Linux or macOS.' >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64) arch=x64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) printf '%s\n' 'Unsupported CPU architecture.' >&2; exit 1 ;;
esac
version=
while IFS= read -r line; do
  case "$line" in version:*) version=${line#version: }; version=${version%$'\r'}; break ;; esac
done < pubspec.yaml
[[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]] || { printf '%s\n' 'Invalid package version.' >&2; exit 1; }

flutter build "$platform" --release
name="sshairy-$version-$platform-$arch-$(date +%Y%m%d-%H%M%S)"
mkdir -p dist
stage="dist/$name"
mkdir -- "$stage" # refuse to overwrite an earlier bundle
if [[ "$platform" == linux ]]; then
  source="build/linux/$arch/release/bundle"
  [[ -x "$source/sshairy" && -x "$source/lib/sshairy_pty" && -d "$source/data/flutter_assets" ]]
  cp -a "$source/." "$stage/"
else
  apps=(build/macos/Build/Products/Release/*.app)
  [[ ${#apps[@]} == 1 && -d "${apps[0]}" && -x "${apps[0]}/Contents/MacOS/sshairy_pty" ]]
  cp -R "${apps[0]}" "$stage/"
fi
cp README.md "$stage/"
if [[ -f LICENSE ]]; then cp LICENSE "$stage/"; fi
dart run tool/write_notices.dart "$stage/THIRD_PARTY_NOTICES.txt"
tar -czf "$stage.tar.gz" -C dist "$name"
tar -tzf "$stage.tar.gz" > /dev/null
if [[ "$platform" == macos ]]; then
  (cd dist && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
else
  (cd dist && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
fi
printf 'Created %s.tar.gz\n' "$stage"
