#!/bin/bash
#
# Xcode Run Script build phase wrapper for sing-box.
# Builds libsingbox.a into a fixed location that Package.swift can reference.
#

set -e

PARTOUT_ROOT="${SRCROOT}/../submodules/partout"
BUILD_SCRIPT="${PARTOUT_ROOT}/vendors/sing-box/build-sing-box.sh"

if [ ! -f "${BUILD_SCRIPT}" ]; then
    echo "warning: sing-box build script not found at ${BUILD_SCRIPT}, skipping"
    exit 0
fi

# Fixed output directory that Package.swift references via vendors/sing-box/build
export SING_BOX_OUTPUT_DIR="${PARTOUT_ROOT}/vendors/sing-box/build"
export SRCROOT="${SRCROOT}/.."

exec bash "${BUILD_SCRIPT}"
