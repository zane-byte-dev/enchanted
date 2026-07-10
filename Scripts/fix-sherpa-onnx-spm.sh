#!/bin/sh

# Xcode 26 copies every static XCFramework module map into one shared include
# directory. sherpa-onnx-spm ships two files named module.modulemap, which makes
# the build graph report duplicate outputs. Give ONNX Runtime's map a unique
# filename before Xcode computes XCFramework outputs. The module itself remains
# named `onnxruntime`; only the file name changes.

set -eu

if [ -z "${BUILD_DIR:-}" ]; then
    exit 0
fi

derived_data_dir="${BUILD_DIR%%/Build/*}"
xcframework="$derived_data_dir/SourcePackages/artifacts/sherpa-onnx-spm/onnxruntime/onnxruntime.xcframework"

if [ ! -d "$xcframework" ]; then
    exit 0
fi

for module_map in "$xcframework"/*/Headers/module.modulemap; do
    if [ -f "$module_map" ]; then
        mv "$module_map" "${module_map%/*}/onnxruntime.modulemap"
    fi
done
