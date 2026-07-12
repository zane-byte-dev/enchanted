#!/bin/sh
set -eu

# Build pi in an isolated copy and atomically install the runtime consumed by
# Xcode. Node is the default because measured startup is sub-second; Bun's
# smaller single-file build remains available via MOX_PI_RUNTIME_KIND=bun.
SOURCE_ROOT="${PI_SOURCE_ROOT:-${1:-$(cd "$(dirname "$0")/../.." && pwd)/pi}}"
OUTPUT_ROOT="${MOX_PI_RUNTIME_DIR:-${2:-$(cd "$(dirname "$0")/.." && pwd)/Vendor/PiRuntime}}"
OUTPUT_ARCHIVE="${MOX_PI_RUNTIME_ARCHIVE:-$OUTPUT_ROOT.zip}"
KIND="${MOX_PI_RUNTIME_KIND:-node}"
NODE="${NODE_EXECUTABLE:-/usr/local/bin/node}"
BUN="${BUN_EXECUTABLE:-$HOME/.bun/bin/bun}"
NPM="${NPM_EXECUTABLE:-/usr/local/bin/npm}"

if [ ! -f "$SOURCE_ROOT/packages/coding-agent/package.json" ]; then
  echo "pi source repository not found: $SOURCE_ROOT" >&2
  exit 1
fi
if [ ! -x "$NODE" ]; then
  echo "Node 22.19+ is required to build pi: $NODE" >&2
  exit 1
fi
if [ ! -x "$NPM" ]; then
  echo "npm is required to build pi: $NPM" >&2
  exit 1
fi
if [ "$KIND" != "node" ] && [ "$KIND" != "bun" ]; then
  echo "MOX_PI_RUNTIME_KIND must be node or bun" >&2
  exit 1
fi
if [ "$KIND" = "bun" ] && [ ! -x "$BUN" ]; then
  echo "Bun is required for the single-file runtime: $BUN" >&2
  exit 1
fi

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mox-pi-runtime.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT INT TERM
SOURCE_COPY="$WORK_ROOT/pi"
mkdir -p "$SOURCE_COPY" "$WORK_ROOT/bin"
rsync -a --delete --exclude .git "$SOURCE_ROOT/" "$SOURCE_COPY/"

# npm-run scripts use /usr/bin/env node. A private link makes the selected
# runtime deterministic even when GUI/sandbox PATH does not expose Node.
ln -s "$NODE" "$WORK_ROOT/bin/node"
export PATH="$WORK_ROOT/bin:$(dirname "$NPM"):$(dirname "$BUN"):/usr/bin:/bin:/usr/sbin:/sbin"
export NPM_CONFIG_CACHE="$WORK_ROOT/npm-cache"

# Compile the generated catalogs checked into the selected pi commit. Do not
# call upstream build:binary, which refreshes model catalogs from live APIs.
"$NPM" --prefix "$SOURCE_COPY/packages/tui" run build
(
  cd "$SOURCE_COPY/packages/ai"
  ../../node_modules/.bin/tsgo -p tsconfig.build.json
)
"$NPM" --prefix "$SOURCE_COPY/packages/agent" run build
"$NPM" --prefix "$SOURCE_COPY/packages/coding-agent" run build

STAGED_OUTPUT="$WORK_ROOT/runtime"
mkdir -p "$STAGED_OUTPUT"

if [ "$KIND" = "bun" ]; then
  (
    cd "$SOURCE_COPY/packages/coding-agent"
    "$BUN" build --compile ./dist/bun/cli.js ./src/utils/image-resize-worker.ts --outfile dist/pi
    "$NPM" run copy-binary-assets
  )
  RUNTIME_SOURCE="$SOURCE_COPY/packages/coding-agent/dist"
  for ITEM in pi package.json README.md CHANGELOG.md theme assets export-html docs examples photon_rs_bg.wasm; do
    if [ -e "$RUNTIME_SOURCE/$ITEM" ]; then
      ditto "$RUNTIME_SOURCE/$ITEM" "$STAGED_OUTPUT/$ITEM"
    fi
  done
  if ! VERSION="$($STAGED_OUTPUT/pi --version)" || [ -z "$VERSION" ]; then
    echo "Prepared Bun runtime failed its version probe" >&2
    exit 1
  fi
else
  # Retain the installed, lockfile-resolved production closure without
  # consulting the registry, then discard sources/tests.
  "$NODE" "$(cd "$(dirname "$0")" && pwd)/prune-pi-runtime.mjs" "$SOURCE_COPY"

  find "$SOURCE_COPY/packages" -mindepth 1 -maxdepth 1 -type d \
    ! -name ai ! -name agent ! -name tui ! -name coding-agent -exec rm -rf {} +
  for PACKAGE in ai agent tui coding-agent; do
    find "$SOURCE_COPY/packages/$PACKAGE" -mindepth 1 -maxdepth 1 \
      ! -name dist ! -name package.json -exec rm -rf {} +
  done

  mv "$SOURCE_COPY/node_modules" "$STAGED_OUTPUT/node_modules"
  mkdir -p "$STAGED_OUTPUT/packages"
  for PACKAGE in ai agent tui coding-agent; do
    mv "$SOURCE_COPY/packages/$PACKAGE" "$STAGED_OUTPUT/packages/$PACKAGE"
  done
  ditto "$NODE" "$STAGED_OUTPUT/node"
  chmod 755 "$STAGED_OUTPUT/node"
  # Thin a universal build for the requested single architecture. Set
  # MOX_PI_ARCHS="arm64 x86_64" to keep a universal Node for universal apps.
  ARCHS_VALUE="${MOX_PI_ARCHS:-$(uname -m)}"
  if [ "$(printf '%s' "$ARCHS_VALUE" | wc -w | tr -d ' ')" = "1" ] && \
     lipo -info "$STAGED_OUTPUT/node" 2>/dev/null | grep -q "Architectures in the fat file"; then
    lipo "$STAGED_OUTPUT/node" -thin "$ARCHS_VALUE" -output "$STAGED_OUTPUT/node.thin"
    mv "$STAGED_OUTPUT/node.thin" "$STAGED_OUTPUT/node"
    chmod 755 "$STAGED_OUTPUT/node"
  fi
  printf '%s\n' '#!/bin/sh' \
    'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' \
    'exec "$ROOT/node" "$ROOT/packages/coding-agent/dist/cli.js" "$@"' \
    > "$STAGED_OUTPUT/pi"
  chmod 755 "$STAGED_OUTPUT/pi"
  if ! VERSION="$($STAGED_OUTPUT/pi --version)" || [ -z "$VERSION" ]; then
    echo "Prepared Node runtime failed its version probe" >&2
    exit 1
  fi
fi

printf '%s\n' "$VERSION" > "$STAGED_OUTPUT/VERSION"
printf '%s\n' "$KIND" > "$STAGED_OUTPUT/RUNTIME_KIND"
git -C "$SOURCE_ROOT" rev-parse HEAD > "$STAGED_OUTPUT/SOURCE_REVISION" 2>/dev/null \
  || printf '%s\n' unknown > "$STAGED_OUTPUT/SOURCE_REVISION"
(
  cd "$STAGED_OUTPUT"
  find . -type f ! -name MANIFEST.sha256 -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 > MANIFEST.sha256
)

STAGED_ARCHIVE="$WORK_ROOT/PiRuntime.zip"
(
  cd "$STAGED_OUTPUT"
  /usr/bin/zip -qry -y "$STAGED_ARCHIVE" .
)

mkdir -p "$(dirname "$OUTPUT_ROOT")"
rm -rf "$OUTPUT_ROOT"
mv "$STAGED_OUTPUT" "$OUTPUT_ROOT"
rm -f "$OUTPUT_ARCHIVE"
mv "$STAGED_ARCHIVE" "$OUTPUT_ARCHIVE"
echo "Prepared Mox pi runtime $VERSION ($KIND) at $OUTPUT_ROOT and $OUTPUT_ARCHIVE"
