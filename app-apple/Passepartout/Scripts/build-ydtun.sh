#!/bin/bash
#
# Xcode Run Script build phase wrapper for ydtun.
# Builds ydtun binary into a fixed location.
#

set -e

PARTOUT_ROOT="${SRCROOT}/../submodules/partout"
BUILD_SCRIPT="${PARTOUT_ROOT}/vendors/ydtun/build-ydtun.sh"

if [ ! -f "${BUILD_SCRIPT}" ]; then
    echo "warning: ydtun build script not found at ${BUILD_SCRIPT}, skipping"
    exit 0
fi

# Fixed output directory
export YDTUN_OUTPUT_DIR="${PARTOUT_ROOT}/vendors/ydtun/build"
export SRCROOT="${SRCROOT}/.."

exec bash "${BUILD_SCRIPT}"
