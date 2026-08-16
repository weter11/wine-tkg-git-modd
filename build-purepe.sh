#!/usr/bin/env bash
# build-purepe.sh - Build Valve's pure-PE WoW64 Proton 11 runner for SteamFlow.
#
# Produces TWO tarballs from ONE `make redist` of the official Proton source:
#   steamflow-proton-11.0-purepe.tar.gz                  (clean release, DXVK <release>)
#   steamflow-proton-11.0-purepe-rtx_remix_debug.tar.gz  (DXVK = proton submodule pin 0a70623)
#
# The two variants are byte-identical EXCEPT files/lib/wine/dxvk/ + VERSIONS.txt.
# Recipe provenance: SteamFlow docs/architecture/phase3-pure-pe-proton11.md
# (local podman build, 2026-08-11/12) + staged compatibilitytools.d trees.
#
# Run on a HOST with a working container engine (docker or podman):
# proton's own make machinery (`make redist`) spawns the steamrt4 SDK container
# (see Makefile.in DOCKER_BASE) — see .github/workflows/purepe-runner.yml.
#   STEAMRT_IMAGE: registry.gitlab.steamos.cloud/proton/steamrt4/sdk/x86_64:4.0.20260331.220802-0
#
# Env overrides:
#   PROTON_REF     Proton tag (default: proton-11.0-1b)
#   DXVK_RELEASE   DXVK release for the clean variant (default: 3.0.2)
#   BUILD_DATE     VERSIONS.txt stamp (default: now, UTC)

set -euo pipefail

ROOT_DIR="${PWD}"
BUILD_DIR="${ROOT_DIR}/build-purepe"
PROTON_REF="${PROTON_REF:-proton-11.0-1b}"
PROTON_BRANCH="${PROTON_BRANCH:-proton_11.0}"
DXVK_RELEASE="${DXVK_RELEASE:-3.0.2}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

SRC_DIR="${BUILD_DIR}/proton-src"
DIST_DIR="${BUILD_DIR}/dist"
REDIST_DIR="${SRC_DIR}/redist"   # `make redist` writes ./redist relative to the build cwd ($SRC_DIR)
PATCH_FILE="${ROOT_DIR}/proton-purepe-makefile.in.patch"

log() { echo -e "\033[1;34m[purepe]\033[0m $*" >&2; }
fail() { echo -e "\033[1;31m[purepe] ERROR: $*\033[0m" >&2; exit 1; }

[ -f "${PATCH_FILE}" ] || fail "patch file not found: ${PATCH_FILE}"

mkdir -p "${BUILD_DIR}"

FREE_GB=$(df -BG "${BUILD_DIR}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
[ "${FREE_GB}" -ge 25 ] || fail "insufficient disk: ${FREE_GB}G free (need >= 25G; the full proton redist peaks at ~17-19G)"

log "== Cloning Proton ${PROTON_REF} (branch ${PROTON_BRANCH}), shallow + submodules =="
rm -rf "${SRC_DIR}"
git clone --branch "${PROTON_REF}" --depth 1 --shallow-submodules --recursive \
    https://github.com/ValveSoftware/Proton.git "${SRC_DIR}"

cd "${SRC_DIR}"
git describe --tags --always
DXVK_SUB=$(git submodule status dxvk | awk '{print $1}' | sed 's/^-//;s/^+//')
WINE_SUB=$(git submodule status wine | awk '{print $1}' | sed 's/^-//;s/^+//')
log "dxvk submodule:  ${DXVK_SUB} (expect 0a70623de9c5c6993c71ba3f063719ec29f431ec)"
log "wine submodule:  ${WINE_SUB} (expect 81d78e4f3ea8ce868d775021fdc9f90122dc1a6b)"
[ "${WINE_SUB}" = "81d78e4f3ea8ce868d775021fdc9f90122dc1a6b" ] || log "WARN: wine submodule differs from proton-11.0-1b pin (recipe built against 81d78e4)"

log "== Applying pure-PE Makefile.in patch =="
patch -p1 < "${PATCH_FILE}"
grep -q 'Pure-PE WoW64' Makefile.in || fail "patch did not apply (marker not found)"
grep -q 'WINEOPENXR_x86_64_PE_ARCHS = x86_64' Makefile.in || fail "patch did not apply (wineopenxr marker missing)"

# Match the established VERSIONS.txt display form (short hash, e.g. "0a70623 (dxvk)")
DXVK_SUB_SHORT="${DXVK_SUB:0:7}"

log "== make redist (this is the long step) =="
make -j"$(nproc)" redist 2>&1 | tee "${BUILD_DIR}/redist.log"
[ -d "${REDIST_DIR}" ] || fail "make redist produced no ${REDIST_DIR}"

log "== Pure-PE gates =="
[ -d "${REDIST_DIR}/files/lib/wine/i386-windows" ] || fail "GATE: i386-windows PE dir missing"
[ -d "${REDIST_DIR}/files/lib/wine/x86_64-windows" ] || fail "GATE: x86_64-windows PE dir missing"
ELF32=$(find "${REDIST_DIR}" -type f -exec file {} + 2>/dev/null | grep -c 'ELF 32-bit' || true)
[ "${ELF32}" = "0" ] || fail "GATE: ${ELF32} ELF 32-bit files in redist (pure-PE violated)"
[ -f "${REDIST_DIR}/proton" ] || fail "GATE: root proton script missing (classify_runner -> Proton kind)"

# Free disk before staging: the build/ tree (wine/kaldi/dxvk obj dirs) and the
# internal dist/ staging mirror are the bulk of the footprint. redist/ is complete.
log "== Cleaning build/ + dist/ trees (redist is self-contained) =="
rm -rf build dist
df -h "${BUILD_DIR}" | tail -1

log "== Staging variant A: rtx_remix_debug (stock dxvk submodule ${DXVK_SUB}) =="
rm -rf "${DIST_DIR}/steamflow-proton-11.0-purepe-rtx_remix_debug"
mkdir -p "${DIST_DIR}"
cp -a "${REDIST_DIR}" "${DIST_DIR}/steamflow-proton-11.0-purepe-rtx_remix_debug"
rm -rf "${DIST_DIR}/steamflow-proton-11.0-purepe-rtx_remix_debug/__pycache__"
cat > "${DIST_DIR}/steamflow-proton-11.0-purepe-rtx_remix_debug/VERSIONS.txt" <<EOF
WINE_COMMIT=${PROTON_REF}
DXVK_VERSION=${DXVK_SUB_SHORT} (dxvk)
VKD3D_PROTON_VERSION=ef20c02 (vkd3d-proton)
DXVK_NVAPI_VERSION=c68c350 (dxvk-nvapi)
VKD3D_VERSION=30b93dc (vkd3d)
RUNNER_VERSION=${PROTON_REF}-purepe
BUILD_DATE=${BUILD_DATE}
EOF

log "== Staging variant B: clean release (DXVK ${DXVK_RELEASE} swapped in) =="
rm -rf "${DIST_DIR}/steamflow-proton-11.0-purepe"
cp -a "${REDIST_DIR}" "${DIST_DIR}/steamflow-proton-11.0-purepe"
rm -rf "${DIST_DIR}/steamflow-proton-11.0-purepe/__pycache__"
DXVK_DL="${BUILD_DIR}/dxvk-${DXVK_RELEASE}.tar.gz"
if [ ! -f "${DXVK_DL}" ]; then
    log "Downloading DXVK ${DXVK_RELEASE} release tarball"
    wget -q --no-use-server-timestamps -O "${DXVK_DL}" \
        "https://github.com/doitsujin/dxvk/releases/download/v${DXVK_RELEASE}/dxvk-${DXVK_RELEASE}.tar.gz" \
        || curl -fL --retry 3 -o "${DXVK_DL}" \
        "https://github.com/doitsujin/dxvk/releases/download/v${DXVK_RELEASE}/dxvk-${DXVK_RELEASE}.tar.gz"
fi
[ -s "${DXVK_DL}" ] || fail "DXVK ${DXVK_RELEASE} download failed"
DXVDIR="${BUILD_DIR}/dxvk-${DXVK_RELEASE}"
rm -rf "${DXVDIR}" && mkdir -p "${DXVDIR}"
tar -xzf "${DXVK_DL}" -C "${DXVDIR}"
RELEASE_DIR="${DIST_DIR}/steamflow-proton-11.0-purepe/files/lib/wine/dxvk"
SRC64=$(find "${DXVDIR}" -path '*dxvk/x64/d3d11.dll' | head -1)
SRC32=$(find "${DXVDIR}" -path '*dxvk/win32/d3d11.dll' | head -1)
[ -n "${SRC64}" ] && [ -n "${SRC32}" ] || fail "DXVK release layout unexpected (x64/win32 d3d11.dll not found)"
mkdir -p "${RELEASE_DIR}/x86_64-windows" "${RELEASE_DIR}/i386-windows"
cp -f "${DXVDIR}"/dxvk-*/dxvk/x64/*.dll "${RELEASE_DIR}/x86_64-windows/"
cp -f "${DXVDIR}"/dxvk-*/dxvk/win32/*.dll "${RELEASE_DIR}/i386-windows/"
printf 'dxvk %s (release)\n' "${DXVK_RELEASE}" > "${RELEASE_DIR}/version"
cat > "${DIST_DIR}/steamflow-proton-11.0-purepe/VERSIONS.txt" <<EOF
WINE_COMMIT=${PROTON_REF}
DXVK_VERSION=${DXVK_RELEASE} (release)
VKD3D_PROTON_VERSION=ef20c02 (vkd3d-proton)
DXVK_NVAPI_VERSION=c68c350 (dxvk-nvapi)
VKD3D_VERSION=30b93dc (vkd3d)
RUNNER_VERSION=${PROTON_REF}-purepe (clean release build)
BUILD_DATE=${BUILD_DATE}
EOF

log "== Verifying variant diff (must be ONLY files/lib/wine/dxvk + VERSIONS.txt) =="
diff -rq "${DIST_DIR}/steamflow-proton-11.0-purepe" "${DIST_DIR}/steamflow-proton-11.0-purepe-rtx_remix_debug" \
    | grep -v '^Only in' || true

log "== Packaging tarballs =="
tar -C "${DIST_DIR}" --exclude='*/__pycache__' -czf "${DIST_DIR}/steamflow-proton-11.0-purepe.tar.gz" \
    steamflow-proton-11.0-purepe
tar -C "${DIST_DIR}" --exclude='*/__pycache__' -czf "${DIST_DIR}/steamflow-proton-11.0-purepe-rtx_remix_debug.tar.gz" \
    steamflow-proton-11.0-purepe-rtx_remix_debug

ls -lh "${DIST_DIR}"/*.tar.gz
log "DONE. Tarballs in ${DIST_DIR}"
