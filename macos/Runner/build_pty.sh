#!/bin/sh
set -eu

# This is a separate single-threaded helper, not fork() inside the Dart VM.
pty_source="$PROJECT_DIR/../native/sshairy_pty.c"
pty_dir="$TARGET_TEMP_DIR/sshairy-pty"
pty_output="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/sshairy_pty"
mkdir -p "$pty_dir" "$(dirname "$pty_output")"
for pty_arch in $ARCHS; do
  /usr/bin/xcrun --sdk macosx clang -std=c11 -O2 -Wall -Wextra -Werror \
    -arch "$pty_arch" -isysroot "$SDKROOT" "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    "$pty_source" -o "$pty_dir/$pty_arch"
done
set --
for pty_arch in $ARCHS; do set -- "$@" "$pty_dir/$pty_arch"; done
/usr/bin/xcrun lipo -create "$@" -output "$pty_output"
chmod 755 "$pty_output"
# A user-launched local shell needs normal user permissions; no sandbox inheritance or exceptions.
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$pty_output"
fi
