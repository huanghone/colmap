#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Configure and build COLMAP with CUDA support, using a conda environment named
# "colmap" for the build/test dependencies and for running the test suite.
#
# Usage:
#   ./build_cuda_conda.sh              # create env (if needed), build, install, run ctest
#   ./build_cuda_conda.sh --no-test    # build + install only
#   ./build_cuda_conda.sh --fresh      # drop the CMake cache before configuring
#
# Environment overrides:
#   COLMAP_CONDA_ENV   conda env name        (default: colmap)
#   COLMAP_BUILD_DIR   build directory       (default: <repo>/build)
#   COLMAP_INSTALL_DIR install prefix        (default: <repo>/install)
#   CUDA_ARCH          CMAKE_CUDA_ARCHITECTURES (default: detected from nvidia-smi)
#
# Notes on this machine (Linux Mint 22 / Ubuntu 24.04, CUDA 13.0, RTX 5070):
#   * System Boost is 1.83 but COLMAP needs >= 1.84, so conda-forge Boost 1.92
#     is used. Ceres (no CUDA variant, to avoid dragging in the CUDA 12
#     runtime), OpenImageIO, SuiteSparse/CHOLMOD, Metis and GTest also come
#     from the conda env; Eigen is pinned to 3.4 for Ceres ABI consistency.
#   * The conda env ships libglib/libGL alongside system Qt5/GL. The build
#     binaries therefore get a transitive DT_RPATH (--disable-new-dtags) that
#     prefers $CONDA_PREFIX/lib, and the install tree gets an RPATH pointing
#     back at the conda env.
#   * Ubuntu's libqt5svg5-dev (needed by GUI_ENABLED, COLMAP_QT_COMPONENTS
#     includes Svg) is not installed and installing it needs root, so the two
#     .deb files are fetched and unpacked into a local prefix instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_ENV="${COLMAP_CONDA_ENV:-colmap}"
BUILD_DIR="${COLMAP_BUILD_DIR:-${SCRIPT_DIR}/build}"
INSTALL_DIR="${COLMAP_INSTALL_DIR:-${SCRIPT_DIR}/install}"
RUN_TESTS=1
FRESH=0

for arg in "$@"; do
    case "${arg}" in
        --no-test) RUN_TESTS=0 ;;
        --fresh) FRESH=1 ;;
        *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done

# --- locate and activate conda ------------------------------------------------
if ! command -v conda >/dev/null 2>&1; then
    for candidate in "${HOME}/miniconda3/etc/profile.d/conda.sh" \
                     "${HOME}/anaconda3/etc/profile.d/conda.sh"; do
        if [ -f "${candidate}" ]; then
            # shellcheck disable=SC1090
            source "${candidate}"
            break
        fi
    done
fi
command -v conda >/dev/null 2>&1 || { echo "conda not found" >&2; exit 1; }

if ! conda env list | awk '{print $1}' | grep -qx "${CONDA_ENV}"; then
    echo "==> creating conda env '${CONDA_ENV}'"
    # conda-forge ceres-solver defaults to a CUDA build that pulls the CUDA 12
    # runtime (~450 MB libcublas); the CPU build is what we want, since COLMAP's
    # own CUDA comes from the system toolkit.
    conda create -y -n "${CONDA_ENV}" --override-channels -c conda-forge \
        python=3.12 pip "cmake=3.31" ninja pkg-config \
        "ceres-solver=2.2.0=cpu*" "eigen=3.4" openimageio libopenimageio \
        libboost-devel suitesparse glog gflags sqlite metis gtest pytest numpy
fi

# shellcheck disable=SC1091
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV}"
echo "==> conda env: ${CONDA_PREFIX}"

# --- Qt5Svg development files (no root required) ------------------------------
QT5SVG_DIR=""
if [ ! -f /usr/lib/x86_64-linux-gnu/cmake/Qt5Svg/Qt5SvgConfig.cmake ]; then
    QT5SVG_PREFIX="${HOME}/.local/colmap-deps/qt5svg"
    QT5SVG_DIR="${QT5SVG_PREFIX}/usr/lib/x86_64-linux-gnu/cmake/Qt5Svg"
    if [ ! -f "${QT5SVG_DIR}/Qt5SvgConfig.cmake" ]; then
        echo "==> fetching libqt5svg5-dev into ${QT5SVG_PREFIX}"
        mkdir -p "${QT5SVG_PREFIX}"
        ( cd /tmp && apt-get download libqt5svg5-dev libqt5svg5 >/dev/null )
        for deb in /tmp/libqt5svg5-dev_*.deb /tmp/libqt5svg5_*.deb; do
            dpkg -x "${deb}" "${QT5SVG_PREFIX}"
        done
    fi
fi

# --- CUDA architecture --------------------------------------------------------
CUDA_ARCH="${CUDA_ARCH:-}"
if [ -z "${CUDA_ARCH}" ]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
        CUDA_ARCH="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
                     | head -1 | tr -d ' .')"
    fi
    CUDA_ARCH="${CUDA_ARCH:-native}"
fi
echo "==> CMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}"

# --- configure ----------------------------------------------------------------
mkdir -p "${BUILD_DIR}"
[ "${FRESH}" -eq 1 ] && rm -f "${BUILD_DIR}/CMakeCache.txt"

CMAKE_ARGS=(
    -GNinja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
    -DCMAKE_PREFIX_PATH="${CONDA_PREFIX}"
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    # Transitive DT_RPATH so conda's libglib/libGL win over the system copies
    # for *indirect* dependencies too (DT_RUNPATH is not transitive).
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--disable-new-dtags"
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
    -DCUDA_ENABLED=ON
    #-DONNX_ENABLED=ON
    -DGUI_ENABLED=ON
    -DTESTS_ENABLED=ON
)
[ -n "${QT5SVG_DIR}" ] && CMAKE_ARGS+=(-DQt5Svg_DIR="${QT5SVG_DIR}")

echo "==> configuring"
cmake -S "${SCRIPT_DIR}" -B "${BUILD_DIR}" "${CMAKE_ARGS[@]}"

# --- build / install ----------------------------------------------------------
JOBS="${JOBS:-$(nproc)}"
echo "==> building with ${JOBS} jobs"
cmake --build "${BUILD_DIR}" --parallel "${JOBS}"
cmake --install "${BUILD_DIR}"

# --- test ---------------------------------------------------------------------
if [ "${RUN_TESTS}" -eq 1 ]; then
    echo "==> running tests"
    ( cd "${BUILD_DIR}" && QT_QPA_PLATFORM=offscreen \
        ctest -j "${CTEST_JOBS:-4}" --timeout 600 --output-on-failure )
fi

echo "==> done: ${INSTALL_DIR}/bin/colmap"
"${INSTALL_DIR}/bin/colmap" --version
