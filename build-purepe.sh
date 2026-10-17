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
#   PROTON_REF     Proton tag (default: proton-11.0-2e, latest Valve release)
#   DXVK_RELEASE   DXVK release for the clean variant (default: 3.1.1)
#   BUILD_DATE     VERSIONS.txt stamp (default: now, UTC)
#   STEAMRT_IMAGE  SDK container image to build in. Pass a derived image that
#                  carries libxkbregistry-dev (see purepe-runner.yml) to get the
#                  native Wine Wayland driver built. Without it, winewayland is
#                  not compiled and the opt-in silently no-ops.
#   WAYLAND_REQUIRED  "1" = fail the build if the Wayland driver is missing
#                     (set by CI, where the probe guarantees the dev deps exist)

set -euo pipefail

ROOT_DIR="${PWD}"
BUILD_DIR="${ROOT_DIR}/build-purepe"
PROTON_REF="${PROTON_REF:-proton-11.0-2e}"
PROTON_BRANCH="${PROTON_BRANCH:-proton_11.0}"
DXVK_RELEASE="${DXVK_RELEASE:-3.1.1}"
WAYLAND_REQUIRED="${WAYLAND_REQUIRED:-0}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

SRC_DIR="${BUILD_DIR}/proton-src"
DIST_DIR="${BUILD_DIR}/dist"
REDIST_DIR="${SRC_DIR}/redist"   # `make redist` writes ./redist relative to the build cwd ($SRC_DIR)
PATCH_FILE="${ROOT_DIR}/proton-purepe-makefile.in.patch"

log() { echo -e "\033[1;34m[purepe]\033[0m $*" >&2; }
fail() { echo -e "\033[1;31m[purepe] ERROR: $*\033[0m" >&2; exit 1; }

[ -f "${PATCH_FILE}" ] || fail "patch file not found: ${PATCH_FILE}"

mkdir -p "${BUILD_DIR}"
rm -rf "${DIST_DIR}"   # fresh output each run (self-hosted runner persists between runs)

FREE_GB=$(df -BG "${BUILD_DIR}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
[ "${FREE_GB}" -ge 10 ] || fail "insufficient disk: ${FREE_GB}G free (need >= 10G; the full proton redist peaks at ~17-19G on self-hosted runners with more headroom)"

log "== Cloning Proton ${PROTON_REF} (branch ${PROTON_BRANCH}), shallow + submodules =="
rm -rf "${SRC_DIR}"
git clone --branch "${PROTON_REF}" --depth 1 --shallow-submodules --recursive \
    https://github.com/ValveSoftware/Proton.git "${SRC_DIR}"

cd "${SRC_DIR}"
git describe --tags --always
DXVK_SUB=$(git submodule status dxvk | awk '{print $1}' | sed 's/^-//;s/^+//')
WINE_SUB=$(git submodule status wine | awk '{print $1}' | sed 's/^-//;s/^+//')
log "dxvk submodule:  ${DXVK_SUB}"
log "wine submodule:  ${WINE_SUB}"
# The wayland driver must exist in the wine tree we build; it is not a TKG patch.
if [ ! -d "wine/dlls/winewayland.drv" ]; then
    fail "wine submodule ${WINE_SUB:0:12} has no dlls/winewayland.drv — this Proton pin cannot support native Wayland"
fi
log "wine tree has dlls/winewayland.drv (${PROTON_REF})"

WINE_TREE_DESC="${PROTON_REF}"

# --- optional: GE-Proton Wine-Wineland base (diagnostic builds) -----------------
# WINE_PIN switches the wine tree from Valve's submodule pin to another commit, and
# WINELAND_PATCH_ROOT applies GE-Proton's wine hotfixes in GE's own order (see
# patches/protonprep-valve-staging.sh in gloriouseggroll/proton-ge-custom @ GE-Proton11-9),
# followed by our diagnostic patch. Both default to empty: a normal purepe build is untouched.
if [ -n "${WINE_PIN:-}" ]; then
    log "== Switching wine submodule to ${WINE_PIN:0:12} =="
    ( cd wine && git fetch --depth 1 origin "${WINE_PIN}" && git checkout -q FETCH_HEAD ) \
        || fail "cannot check out wine commit ${WINE_PIN}"
    WINE_SUB=$(git -C wine rev-parse HEAD)
    log "wine tree now at ${WINE_SUB:0:12}"
fi

if [ -n "${WINELAND_PATCH_ROOT:-}" ]; then
    [ -n "${WINE_PIN:-}" ] || fail "WINELAND_PATCH_ROOT needs WINE_PIN (the GE hotfixes only apply to that tree)"
    [ -f "${ROOT_DIR}/proton-purepe-wineland-diag.patch" ] || fail "diagnostic patch file missing"
    apply_wine_dir() {
        local dir="$1" n=0 p
        [ -d "${dir}" ] || fail "patch dir missing: ${dir}"
        for p in "${dir}"/*.patch; do
            [ -f "${p}" ] || continue
            patch -Np1 -s -d wine -i "${p}" || fail "patch failed: $(basename "${p}")"
            n=$((n + 1))
        done
        log "  applied ${n} patches from $(basename "${dir}")"
    }
    log "== Applying GE wine hotfixes (order as in GE protonprep-valve-staging.sh) =="
    apply_wine_dir "${WINELAND_PATCH_ROOT}/wine-wayland"
    patch -Np1 -s -d wine -i "${WINELAND_PATCH_ROOT}"/em-fixups/0001-*.patch \
        || fail "SNI hotfix patch failed"
    log "  applied em-fixups/0001 (SNI)"
    apply_wine_dir "${WINELAND_PATCH_ROOT}/wineland-child-rendering"
    log "== Applying purepe Wine-Wineland diagnostic patch (TRACE + trial switch) =="
    patch -Np1 -s -d wine -i "${ROOT_DIR}/proton-purepe-wineland-diag.patch" \
        || fail "diagnostic patch failed"
    grep -q 'WINELAND_IGNORE_OCCLUSION_CLIP' wine/dlls/winewayland.drv/wayland_surface.c \
        || fail "diagnostic patch marker missing"
    # Nvidia Reflex / VK_NV_low_latency2 driver member + its win32u implementation. The
    # child-rendering series' generator list (patch 0041) emits thunks calling
    # vk_funcs->p_vkSetLatencySleepModeNV, while the member and implementation live in GE's
    # patches/proton/83-nv_low_latency_wine.patch — without it winevulkan fails to compile
    # ~1.5 h into the build (verified 2026-10-17, run 39062234007). GE applies their
    # patches/proton/* set late, after the wayland series, so it goes here as well.
    [ -f "${ROOT_DIR}/patches/proton/83-nv_low_latency_wine.patch" ] || fail "low-latency patch missing"
    patch -p1 -s -d wine -i "${ROOT_DIR}/patches/proton/83-nv_low_latency_wine.patch" \
        || fail "nv_low_latency_wine patch failed"
    grep -q 'win32u_vkSetLatencySleepModeNV' wine/dlls/win32u/vulkan.c \
        || fail "low-latency patch marker missing in win32u/vulkan.c"
    grep -q 'p_vkSetLatencySleepModeNV' wine/include/wine/vulkan_driver.h \
        || fail "low-latency patch marker missing in include/wine/vulkan_driver.h"

    # Static completeness gate for the generated Vulkan thunks: every member the generator
    # emits as vk_funcs->p_vkX must be declared in struct vulkan_funcs, otherwise the build
    # dies at dlls/winevulkan/vulkan_thunks.c long after this step. Run the generator here
    # (it only writes dlls/winevulkan/vulkan_thunks.c) and diff the two sets.
    if command -v python3 >/dev/null 2>&1 && [ -f wine/dlls/winevulkan/make_vulkan ]; then
        log "== Gate: Vulkan thunk members vs struct vulkan_funcs =="
        if ( cd wine/dlls/winevulkan && python3 make_vulkan ) >"${BUILD_DIR}/make_vulkan.log" 2>&1; then
            missing=$(grep -o 'vk_funcs->p_vk[A-Za-z0-9_]*' wine/dlls/winevulkan/vulkan_thunks.c \
                      | sed 's/vk_funcs->//' | LC_ALL=C sort -u \
                      | comm -23 - <(grep -o 'PFN_[A-Za-z0-9_]* p_vk[A-Za-z0-9_]*' wine/include/wine/vulkan_driver.h \
                                      | awk '{print $2}' | LC_ALL=C sort -u))
            if [ -n "${missing}" ]; then
                log "GATE FAILED: thunks reference members absent from vulkan_driver.h:"
                echo "${missing}" | sed 's/^/    /' >&2
                fail "missing vulkan driver members (a GE patch that adds them is not applied)"
            fi
            log "  ok: every vk_funcs->p_vk* reference is declared"
        else
            log "WARN: make_vulkan did not run; skipping the thunk-membership gate"
        fi
    fi
    WINE_TREE_DESC="${PROTON_REF} + GE-Proton11-9 wine hotfixes + purepe diag"
fi

log "== Applying pure-PE Makefile.in patch =="
patch -p1 < "${PATCH_FILE}"
grep -q 'Pure-PE WoW64' Makefile.in || fail "patch did not apply (marker not found)"
grep -q 'WINEOPENXR_x86_64_PE_ARCHS = x86_64' Makefile.in || fail "patch did not apply (wineopenxr marker missing)"

log "== Applying pure-PE Wayland opt-in patch (proton script) =="
WAYLAND_PATCH_FILE="${ROOT_DIR}/proton-purepe-wayland.patch"
[ -f "${WAYLAND_PATCH_FILE}" ] || fail "wayland patch file not found: ${WAYLAND_PATCH_FILE}"
patch -p1 < "${WAYLAND_PATCH_FILE}"
grep -q 'PROTON_ENABLE_WAYLAND' proton || fail "wayland patch did not apply (marker not found)"

# Match the established VERSIONS.txt display form (short hash, e.g. "0a70623 (dxvk)")
DXVK_SUB_SHORT="${DXVK_SUB:0:7}"

log "== make redist (this is the long step) =="
make -j"$(nproc)" redist 2>&1 | tee "${BUILD_DIR}/redist.log"
# Proton 11.0 `make redist` creates redist inside build/build--local/redist,
# not at the top level. Move it up so the GATE checks and staging work.
if [ ! -d "${REDIST_DIR}" ] && [ -d "${SRC_DIR}/build/build--local/redist" ]; then
    log "Moving build/build--local/redist -> redist/ for compatibility"
    mv "${SRC_DIR}/build/build--local/redist" "${SRC_DIR}/redist" || fail "failed to move build--local/redist to redist"
fi
[ -d "${REDIST_DIR}" ] || fail "make redist produced no ${REDIST_DIR}"

log "== Pure-PE gates =="
[ -d "${REDIST_DIR}/files/lib/wine/i386-windows" ] || fail "GATE: i386-windows PE dir missing"
[ -d "${REDIST_DIR}/files/lib/wine/x86_64-windows" ] || fail "GATE: x86_64-windows PE dir missing"
ELF32=$(find "${REDIST_DIR}" -type f -exec file {} + 2>/dev/null | grep -c 'ELF 32-bit' || true)
[ "${ELF32}" = "0" ] || fail "GATE: ${ELF32} ELF 32-bit files in redist (pure-PE violated)"
[ -f "${REDIST_DIR}/proton" ] || fail "GATE: root proton script missing (classify_runner -> Proton kind)"

# Wayland opt-in gate. Pure-PE means the only Unix side is x86_64-unix, so the
# driver must be present as: x86_64-unix/winewayland.so (ELF64) + the PE
# winewayland.drv in both x86_64-windows and i386-windows. A 32-bit wine build
# would also emit i386-unix/winewayland.so (ELF32) which the pure-PE gate above
# would catch; it must never be shipped.
WAYLAND_SO="${REDIST_DIR}/files/lib/wine/x86_64-unix/winewayland.so"
WAYLAND_DRV64="${REDIST_DIR}/files/lib/wine/x86_64-windows/winewayland.drv"
WAYLAND_DRV32="${REDIST_DIR}/files/lib/wine/i386-windows/winewayland.drv"
if [ -f "${WAYLAND_SO}" ] && [ -f "${WAYLAND_DRV64}" ] && [ -f "${WAYLAND_DRV32}" ]; then
    log "Native Wayland driver built: winewayland.so + winewayland.drv (x86_64 + i386 PE)"
elif [ "${WAYLAND_REQUIRED}" = "1" ]; then
    fail "GATE: WAYLAND_REQUIRED=1 but Wayland driver missing from redist (winewayland.so=${WAYLAND_SO} winewayland.drv=${WAYLAND_DRV64}). The SDK image lacks libxkbregistry-dev; wine configure skipped the driver."
else
    log "WARN: winewayland.so not present (opt-in Wayland unavailable until build/staging includes it)"
fi

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
WINE_COMMIT=${WINE_TREE_DESC}
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
# Some redist markers (notably files/lib/wine/dxvk/version, written by SDK
# container steps) arrive root-owned; the runner user then cannot truncate them
# with `>`. Normalize ownership of the staged trees up front. GitHub runners
# have passwordless sudo; local podman runs fall through with a warning.
if command -v sudo >/dev/null 2>&1; then
    sudo -n chown -R "$(id -u):$(id -g)" "${DIST_DIR}/steamflow-proton-11.0-purepe" 2>/dev/null \
        || log "WARN: sudo chown unavailable/failed for variant B tree"
fi
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
# DXVK release tarballs have shipped x32/ + x64/ since forever (verified on
# 1.10, 2.2, 3.0.2, 3.1.1). The old win32/ pattern was a guess and never matched
# any release, so SRC32 came back empty and the build died here.
SRC64=$(find "${DXVDIR}" -path '*/dxvk/x64/d3d11.dll' -o -path '*/x64/d3d11.dll' | head -1)
SRC32=$(find "${DXVDIR}" -path '*/dxvk/x32/d3d11.dll' -o -path '*/x32/d3d11.dll' | head -1)
[ -n "${SRC64}" ] && [ -n "${SRC32}" ] || fail "DXVK release layout unexpected (x64/x32 d3d11.dll not found)"
mkdir -p "${RELEASE_DIR}/x86_64-windows" "${RELEASE_DIR}/i386-windows"
cp -f "$(dirname "${SRC64}")"/*.dll "${RELEASE_DIR}/x86_64-windows/"
cp -f "$(dirname "${SRC32}")"/*.dll "${RELEASE_DIR}/i386-windows/"
printf 'dxvk %s (release)\n' "${DXVK_RELEASE}" > "${RELEASE_DIR}/version" || {
    # The container-written marker can be root-owned; unlink (needs only dir
    # write perms) then retry once.
    rm -f "${RELEASE_DIR}/version" 2>/dev/null || true
    printf 'dxvk %s (release)\n' "${DXVK_RELEASE}" > "${RELEASE_DIR}/version" || \
        fail "cannot write ${RELEASE_DIR}/version (ownership/permissions of staged tree)"
}
cat > "${DIST_DIR}/steamflow-proton-11.0-purepe/VERSIONS.txt" <<EOF
WINE_COMMIT=${WINE_TREE_DESC}
DXVK_VERSION=${DXVK_RELEASE} (release)
VKD3D_PROTON_VERSION=ef20c02 (vkd3d-proton)
DXVK_NVAPI_VERSION=c68c350 (dxvk-nvapi)
VKD3D_VERSION=30b93dc (vkd3d)
RUNNER_VERSION=${PROTON_REF}-purepe (clean release build)
BUILD_DATE=${BUILD_DATE}
EOF

# Native Wine Wayland driver. Valve's steamrt4 SDK image ships wayland-client
# and wayland-egl dev files but NOT libxkbregistry-dev, so plain `make redist`
# skips winewayland.drv (wine configure.ac requires WAYLAND_CLIENT_LIBS,
# WAYLAND_SCANNER, XKBCOMMON_LIBS AND XKBREGISTRY_LIBS together). The CI builds
# against a derived image that adds libxkbregistry-dev. If a build runs on the
# stock image, the opt-in silently no-ops unless a driver is injected from
# GE_WAYLAND_DIR (set by the operator; intentionally empty by default so CI
# never touches a host-local path that does not exist on the runner).
log "== Verifying native Wayland modules from the Proton build =="
for variant in steamflow-proton-11.0-purepe steamflow-proton-11.0-purepe-rtx_remix_debug; do
    vdir="${DIST_DIR}/${variant}/files/lib/wine"
    if [ ! -f "${vdir}/x86_64-unix/winewayland.so" ] || [ ! -f "${vdir}/x86_64-windows/winewayland.drv" ]; then
        if [ -n "${GE_WAYLAND_DIR:-}" ] && [ -d "${GE_WAYLAND_DIR}" ]; then
            log "WARN: ${variant} missing native Wayland modules — injecting from GE_WAYLAND_DIR=${GE_WAYLAND_DIR}"
            mkdir -p "${vdir}/x86_64-unix" "${vdir}/x86_64-windows" "${vdir}/i386-windows"
            for rel in x86_64-unix/winewayland.so x86_64-windows/winewayland.drv i386-windows/winewayland.drv; do
                if [ -f "${GE_WAYLAND_DIR}/${rel}" ]; then
                    cp -f "${GE_WAYLAND_DIR}/${rel}" "${vdir}/${rel}"
                    log "  injected ${rel}"
                fi
            done
            # Never ship the 32-bit ELF unixlib: pure-PE has no i386-unix side.
            rm -f "${vdir}/i386-unix/winewayland.so"
        else
            log "  ${variant}: no Wayland driver and GE_WAYLAND_DIR unset — opt-in Wayland unavailable in this variant"
        fi
    else
        log "  ${variant} has native Wayland modules from the Proton build"
    fi
done

# Runtime deps for winewayland.so. Inside pressure-vessel (Steam Runtime 4) only
# libwayland-client.so.0 and libxkbcommon.so.0 are guaranteed; libwayland-egl.so.1
# and libxkbregistry.so.0 are not in the overrides set. winewayland.so NEEDEDs all
# four, so ship the missing ones next to the driver and rely on the proton script's
# LD_LIBRARY_PATH prepend of files/lib/x86_64-linux-gnu.
# WAYLAND_RUNTIME_DIR (set by CI) points at libs extracted from the SDK image —
# the authoritative source, since the runner host may not have them installed.
log "== Staging Wayland runtime libraries =="
for variant in steamflow-proton-11.0-purepe steamflow-proton-11.0-purepe-rtx_remix_debug; do
    libdir="${DIST_DIR}/${variant}/files/lib/x86_64-linux-gnu"
    mkdir -p "${libdir}"
    for lib in libxkbregistry.so.0 libwayland-egl.so.1; do
        src=""
        for search_dir in "${WAYLAND_RUNTIME_DIR:-}" /usr/lib/x86_64-linux-gnu; do
            [ -n "${search_dir}" ] || continue
            src=$(find "${search_dir}" -maxdepth 1 -name "${lib}*" -type f 2>/dev/null | head -1)
            [ -n "${src}" ] && break
        done
        if [ -n "${src}" ]; then
            cp -f "${src}" "${libdir}/"
            ln -sf "$(basename "${src}")" "${libdir}/${lib}"
            log "  staged ${lib} (from ${src})"
        else
            log "  WARN: ${lib} not available — winewayland.so may fail to load at runtime"
        fi
    done
done

log "== Verifying variant diff (must be ONLY files/lib/wine/dxvk + VERSIONS.txt) =="
diff -rq "${DIST_DIR}/steamflow-proton-11.0-purepe" "${DIST_DIR}/steamflow-proton-11.0-purepe-rtx_remix_debug" \
    | grep -v '^Only in' || true

log "== Post-staging Wayland verification =="
for variant in steamflow-proton-11.0-purepe steamflow-proton-11.0-purepe-rtx_remix_debug; do
    vdir="${DIST_DIR}/${variant}/files/lib/wine"
    [ -f "${vdir}/x86_64-unix/winewayland.so" ] || log "WARN: ${variant} missing x86_64-unix winewayland.so"
    [ -f "${vdir}/x86_64-windows/winewayland.drv" ] || log "WARN: ${variant} missing x86_64-windows winewayland.drv"
    # Confirm zero 32-bit ELF Wayland .so files in either variant
    WDL32=$(find "${vdir}" -type f -path '*wayland*' -exec file {} + 2>/dev/null | grep -c 'ELF 32-bit' || true)
    [ "${WDL32}" = "0" ] || fail "GATE: ${variant} has ${WDL32} ELF 32-bit Wayland files (pure-PE violated)"
done

log "== Packaging tarballs =="
tar -C "${DIST_DIR}" --exclude='*/__pycache__' -czf "${DIST_DIR}/steamflow-proton-11.0-purepe.tar.gz" \
    steamflow-proton-11.0-purepe
tar -C "${DIST_DIR}" --exclude='*/__pycache__' -czf "${DIST_DIR}/steamflow-proton-11.0-purepe-rtx_remix_debug.tar.gz" \
    steamflow-proton-11.0-purepe-rtx_remix_debug

ls -lh "${DIST_DIR}"/*.tar.gz
log "DONE. Tarballs in ${DIST_DIR}"
