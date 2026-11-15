#!/usr/bin/env bash
# Run on the target platform. Linux produces AppImage and deb; macOS produces zip and dmg.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=macos ;;
  *) printf '%s\n' 'Run this script on Linux or macOS.' >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64) arch=x64; appimage_arch=x86_64; deb_arch=amd64 ;;
  arm64|aarch64) arch=arm64; appimage_arch=aarch64; deb_arch=arm64 ;;
  *) printf '%s\n' 'Unsupported CPU architecture.' >&2; exit 1 ;;
esac

version=$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | tr -d '\r')
[[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]] || { printf '%s\n' 'Invalid package version.' >&2; exit 1; }

# An unset variable keeps a timestamp; an explicitly empty one produces release names.
stamp="${SSHAIRY_BUILD_STAMP-$(date +%Y%m%d-%H%M%S)}"
suffix=""
[[ -n "$stamp" ]] && suffix="-$stamp"
if [[ "$platform" == macos ]]; then label=universal; else label=$arch; fi
base="sshairy-$version-$platform-$label$suffix"

flutter build "$platform" --release

mkdir -p dist
stage="dist/$base"
[[ ! -e "$stage" ]] || { printf 'Output already exists: %s\n' "$stage" >&2; exit 1; }
mkdir -- "$stage"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ "$platform" == macos ]]; then
  apps=(build/macos/Build/Products/Release/*.app)
  [[ ${#apps[@]} == 1 && -d "${apps[0]}" && -x "${apps[0]}/Contents/MacOS/sshairy_pty" ]]
  app=${apps[0]}
  for binary in "$app/Contents/MacOS/Sshairy" "$app/Contents/MacOS/sshairy_pty"; do
    archs=$(lipo -archs "$binary")
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || {
      printf 'Not a universal binary: %s (%s)\n' "$binary" "$archs" >&2
      printf '%s\n' 'Set ARCHS = "arm64 x86_64" for the Runner Release configuration.' >&2
      exit 1
    }
  done
  cp -R "$app" "$stage/"
  cp README.md "$stage/"
  if [[ -f LICENSE ]]; then cp LICENSE "$stage/"; fi
  dart run tool/write_notices.dart "$stage/THIRD_PARTY_NOTICES.txt"

  # ditto keeps framework symlinks and resource forks that plain zip would break.
  ditto -c -k --sequesterRsrc "$stage" "dist/$base.zip"

  mkdir "$work/dmg"
  cp -R "$app" "$work/dmg/"
  ln -s /Applications "$work/dmg/Applications"
  cp README.md "$work/dmg/"
  if [[ -f LICENSE ]]; then cp LICENSE "$work/dmg/"; fi
  cp "$stage/THIRD_PARTY_NOTICES.txt" "$work/dmg/"
  hdiutil create -volname Sshairy -srcfolder "$work/dmg" -ov -format UDZO "dist/$base.dmg"

  (cd dist && shasum -a 256 "$base.zip" "$base.dmg" > "$base.sha256")
  printf 'Created %s.zip and %s.dmg\n' "$stage" "$stage"
  exit 0
fi

source="build/linux/$arch/release/bundle"
[[ -x "$source/sshairy" && -x "$source/lib/sshairy_pty" && -d "$source/data/flutter_assets" ]]
for binary in "$source/sshairy" "$source/lib/sshairy_pty"; do
  info=$(file -b "$binary")
  case "$arch" in
    x64) [[ "$info" == *x86-64* ]] || { printf 'Unexpected architecture for %s: %s\n' "$binary" "$info" >&2; exit 1; } ;;
    arm64) [[ "$info" == *aarch64* ]] || { printf 'Unexpected architecture for %s: %s\n' "$binary" "$info" >&2; exit 1; } ;;
  esac
done
cp -a "$source/." "$stage/"
cp README.md "$stage/"
if [[ -f LICENSE ]]; then cp LICENSE "$stage/"; fi
dart run tool/write_notices.dart "$stage/THIRD_PARTY_NOTICES.txt"

icon=assets/brand/icon.png
[[ -f "$icon" ]]
desktop="$work/sshairy.desktop"
cat > "$desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Sshairy
Comment=Lightweight SSH client with an AI agent
Exec=sshairy
Icon=sshairy
Terminal=false
Categories=Network;RemoteAccess;
Keywords=ssh;terminal;sftp;
EOF

# Map the shared libraries the bundle actually links to their runtime packages.
package_dependencies() {
  local dir=$1 lib deps
  deps=$(
    find "$dir" -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
      xargs -0 -r ldd 2>/dev/null |
      awk '/=> \// {print $3}' |
      sort -u |
      while IFS= read -r lib; do
        dpkg-query -S "$lib" 2>/dev/null | head -n 1 | cut -d: -f1
      done |
      sort -u |
      grep -v '^$' |
      paste -sd, -
  ) || true
  printf '%s' "${deps:-libgtk-3-0, libsecret-1-0}"
}

deb="$work/deb"
mkdir -p "$deb/DEBIAN" "$deb/opt/sshairy" "$deb/usr/bin" \
  "$deb/usr/share/applications" "$deb/usr/share/icons/hicolor/512x512/apps"
cp -a "$stage/." "$deb/opt/sshairy/"
ln -s /opt/sshairy/sshairy "$deb/usr/bin/sshairy"
cp "$desktop" "$deb/usr/share/applications/sshairy.desktop"
cp "$icon" "$deb/usr/share/icons/hicolor/512x512/apps/sshairy.png"
cat > "$deb/DEBIAN/control" <<EOF
Package: sshairy
Version: $version
Architecture: $deb_arch
Maintainer: Sshairy <noreply@sshairy.dev>
Installed-Size: $(du -sk "$deb/opt" | cut -f1)
Depends: $(package_dependencies "$deb/opt/sshairy")
Section: net
Priority: optional
Description: Lightweight SSH client with an AI agent
 A Flutter desktop SSH client with an SFTP browser and an AI agent.
EOF
dpkg-deb --build --root-owner-group "$deb" "dist/$base.deb" >/dev/null

appdir="$work/appdir"
mkdir -p "$appdir/usr/bin" "$appdir/usr/share/applications" \
  "$appdir/usr/share/icons/hicolor/512x512/apps"
cp -a "$stage/." "$appdir/usr/bin/"
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/sshairy" "$@"
EOF
chmod +x "$appdir/AppRun"
cp "$icon" "$appdir/sshairy.png"
cp "$desktop" "$appdir/sshairy.desktop"
cp "$icon" "$appdir/usr/share/icons/hicolor/512x512/apps/sshairy.png"
cp "$desktop" "$appdir/usr/share/applications/sshairy.desktop"
if ! command -v appimagetool >/dev/null 2>&1; then
  printf '%s\n' 'appimagetool not found. Install it or extract it onto PATH.' >&2
  exit 1
fi
ARCH="$appimage_arch" appimagetool "$appdir" "dist/$base.AppImage" >/dev/null
chmod +x "dist/$base.AppImage"

(cd dist && sha256sum "$base.AppImage" "$base.deb" > "$base.sha256")
printf 'Created %s.AppImage and %s.deb\n' "$stage" "$stage"
