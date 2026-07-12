#!/bin/sh
set -eu

[ "${PLATFORM_NAME:-}" = "macosx" ] || exit 0

RUNTIME_ARCHIVE="${MOX_PI_RUNTIME_ARCHIVE:-$SRCROOT/Vendor/PiRuntime.zip}"
CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
DESTINATION="$CONTENTS/Resources/pi-runtime"
HELPER="$CONTENTS/Helpers/pi-node"
REQUIRED="${MOX_REQUIRE_BUNDLED_PI:-NO}"

if [ ! -f "$RUNTIME_ARCHIVE" ]; then
  rm -rf "$DESTINATION"
  rm -f "$HELPER"
  if [ "$REQUIRED" = "YES" ]; then
    echo "error: Bundled pi runtime missing. Run Scripts/prepare-pi-runtime.sh." >&2
    exit 1
  fi
  echo "note: No bundled pi runtime; Mox will use an external installation."
  exit 0
fi

rm -rf "$DESTINATION"
rm -f "$HELPER"
mkdir -p "$DESTINATION" "$(dirname "$HELPER")"
ditto -x -k "$RUNTIME_ARCHIVE" "$DESTINATION"
if [ ! -x "$DESTINATION/pi" ] || [ ! -x "$DESTINATION/node" ]; then
  echo "error: Bundled pi archive is invalid: $RUNTIME_ARCHIVE" >&2
  rm -rf "$DESTINATION"
  exit 1
fi
if [ ! -f "$DESTINATION/MANIFEST.sha256" ] || ! (cd "$DESTINATION" && shasum -a 256 -c MANIFEST.sha256 >/dev/null); then
  echo "error: Bundled pi archive failed its SHA-256 manifest check" >&2
  rm -rf "$DESTINATION"
  exit 1
fi
mv "$DESTINATION/node" "$HELPER"
rm -f "$DESTINATION/pi"
chmod 755 "$HELPER"

HELPER_ARCHS="$(lipo -archs "$HELPER" 2>/dev/null || true)"
for REQUIRED_ARCH in ${ARCHS:-}; do
  case " $HELPER_ARCHS " in
    *" $REQUIRED_ARCH "*) ;;
    *)
      echo "error: Bundled pi helper lacks required architecture $REQUIRED_ARCH (has: $HELPER_ARCHS)" >&2
      exit 1
      ;;
  esac
done

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --options runtime --timestamp=none \
    --entitlements "$SRCROOT/Enchanted/PiNode.entitlements" "$HELPER"
  find "$DESTINATION" -type f \( -name '*.node' -o -name '*.dylib' \) -print0 | while IFS= read -r -d '' NATIVE_MODULE; do
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
      --options runtime --timestamp=none "$NATIVE_MODULE"
  done
fi

echo "Embedded pi runtime: $HELPER + $DESTINATION"
