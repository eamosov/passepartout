#!/bin/bash
#
# Xcode Run Script build phase wrapper for ydtun.
# Builds ydtun binary into a fixed location.
#

set -e

PARTOUT_ROOT="${SRCROOT}/../submodules/partout"
BUILD_SCRIPT="${PARTOUT_ROOT}/scripts/build-ydtun.sh"

if [ ! -f "${BUILD_SCRIPT}" ]; then
    echo "error: ydtun build script not found at ${BUILD_SCRIPT}" >&2
    exit 1
fi

# Fixed output directory
export NEKROVPN_PATH="${NEKROVPN_PATH:-${SRCROOT}/../../nekrovpn}"
export YDTUN_OUTPUT_DIR="${YDTUN_OUTPUT_DIR:-${PARTOUT_ROOT}/.build/ydtun}"
export SRCROOT="${SRCROOT}/.."

exec bash "${BUILD_SCRIPT}"
