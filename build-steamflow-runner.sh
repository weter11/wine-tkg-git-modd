#!/usr/bin/env bash
# build-steamflow-runner.sh - Standalone WoW64 Wine 11 Master runner for SteamFlow
# Targets: Wine 11 Master (HEAD), pure WoW64 mode, DXVK, VKD3D-Proton, DXVK-NVAPI, D7VK

set -euo pipefail

# Fixed root workspace directory
ROOT_DIR="${PWD}"

# ============================================================================================
# VERSION PINS - Update these for component version bumps (empty = latest GitHub release)
# ============================================================================================
WINE_GIT_URL="https://gitlab.winehq.org/wine/wine.git"
WINE_COMMIT="${WINE_COMMIT:-a011ce5724}"  # Staging base (Build #12 known-good commit); empty = HEAD (master)

DXVK_VERSION="${DXVK_VERSION:-}"
VKD3D_VERSION="${VKD3D_VERSION:-}"
DXVK_NVAPI_VERSION="${DXVK_NVAPI_VERSION:-}"
D7VK_VERSION="${D7VK_VERSION:-}"
WINE_MONO_VERSION="${WINE_MONO_VERSION:-}"
WINE_GECKO_VERSION="${WINE_GECKO_VERSION:-2.47.4}"

# ============================================================================================
# BUILD CONFIGURATION
# ============================================================================================
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist/steamflow-runner"
WINE_SRC_DIR="${BUILD_DIR}/wine-git"
BUILD_LOG="${BUILD_DIR}/build.log"
WINE_TKG_DIR="${ROOT_DIR}/wine-tkg-git"

# Track detected component versions for VERSIONS.txt
DXVK_DETECTED_VER="unknown"
VKD3D_DETECTED_VER="unknown"
DXVK_NVAPI_DETECTED_VER="unknown"
D7VK_DETECTED_VER="unknown"
MONO_DETECTED_VER="unknown"

# GCC 14 compatibility flags
export CFLAGS="-O2 -pipe -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -fno-strict-aliasing"
export CXXFLAGS="${CFLAGS} -Wno-error=attributes"
export LDFLAGS="-Wl,-O1,--sort-common,--as-needed"
export CROSSCFLAGS="${CFLAGS}"
export CROSSCXXFLAGS="${CXXFLAGS}"
export CROSSLDFLAGS="${LDFLAGS}"
export MAKEFLAGS="-j$(nproc)"

# ============================================================================================
# HELPER FUNCTIONS (Logging redirected to stderr so stdout remains clean for string returns)
# ============================================================================================
log() { echo -e "\033[1;34m[build]\033[0m $*" | tee -a "${BUILD_LOG}" >&2; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" | tee -a "${BUILD_LOG}" >&2; }
err() { echo -e "\033[1;31m[error]\033[0m $*" | tee -a "${BUILD_LOG}" >&2; exit 1; }
step() { echo -e "\n\033[1;36m=== $* ===\033[0m" | tee -a "${BUILD_LOG}" >&2; }

download() {
    local url="$1" dest="$2"
    log "Downloading ${url} -> ${dest}"
    mkdir -p "$(dirname "${dest}")"
    if ! curl -fL --retry 3 --retry-delay 5 -o "${dest}" "${url}"; then
        err "Download failed: ${url}"
    fi
}

download_github_latest() {
    local repo="$1" pattern="$2" dest_dir="$3" dest_file="${4:-}" tag="${5:-}"
    log "Fetching release info for ${repo}..."
    local res
    res=$(python3 -c "
import urllib.request, json, re
tag = '${tag}'
url = f'https://api.github.com/repos/${repo}/releases/' + (f'tags/{tag}' if tag else 'latest')
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read().decode())
        pattern = re.compile(r'${pattern}')
        tag_name = data.get('tag_name', 'unknown')
        for asset in data.get('assets', []):
            if pattern.search(asset['name']):
                print(f\"{asset['browser_download_url']}|{tag_name}\")
                break
except Exception as e:
    pass
")
    if [[ -z "${res}" ]]; then
        err "Failed to find asset matching pattern '${pattern}' in ${repo}"
    fi
    local asset_url="${res%%|*}"
    local version_tag="${res##*|}"
    local outfile="${dest_dir}/${dest_file:-$(basename "${asset_url}")}"
    download "${asset_url}" "${outfile}"
    echo "${outfile}|${version_tag}"
}

# ============================================================================================
# COMPONENT FETCHING
# ============================================================================================
fetch_wine_source() {
    step "Fetching Wine source"
    mkdir -p "${BUILD_DIR}"
    if [[ -d "${WINE_SRC_DIR}/.git" ]]; then
        log "Updating existing Wine repository..."
        git -C "${WINE_SRC_DIR}" fetch --all --tags --prune
    else
        log "Cloning Wine repository..."
        git clone --mirror "${WINE_GIT_URL}" "${WINE_SRC_DIR}" 2>&1 | tee -a "${BUILD_LOG}"
    fi
    
    local workdir="${BUILD_DIR}/wine-source"
    rm -rf "${workdir}"
    git clone "${WINE_SRC_DIR}" "${workdir}" 2>&1 | tee -a "${BUILD_LOG}"
    if [[ -n "${WINE_COMMIT}" ]]; then
        log "Checking out pinned commit: ${WINE_COMMIT}"
        git -C "${workdir}" checkout "${WINE_COMMIT}" 2>&1 | tee -a "${BUILD_LOG}"
    else
        log "Checking out master HEAD"
        git -C "${workdir}" checkout master 2>&1 | tee -a "${BUILD_LOG}"
    fi
    local actual_commit
    actual_commit=$(git -C "${workdir}" rev-parse HEAD)
    log "Wine commit: ${actual_commit} (staging base a011ce5724)"
    echo "${actual_commit}" > "${BUILD_DIR}/wine_commit.txt"
}

fetch_dxvk() {
    step "Fetching DXVK"
    local dest_64="${DIST_DIR}/lib64/wine/x86_64-windows"
    local dest_32="${DIST_DIR}/lib64/wine/i386-windows"
    mkdir -p "${dest_64}" "${dest_32}" "${BUILD_DIR}/dxvk"
    
    local res tarball
    res=$(download_github_latest "doitsujin/dxvk" "dxvk-.*\\.tar\\.gz$" "${BUILD_DIR}/dxvk" "dxvk.tar.gz" "${DXVK_VERSION}")
    tarball="${res%%|*}"
    DXVK_DETECTED_VER="${res##*|}"
    
    log "Extracting DXVK (${DXVK_DETECTED_VER})..."
    tar -xzf "${tarball}" -C "${BUILD_DIR}/dxvk" --strip-components=1 2>&1 | tee -a "${BUILD_LOG}"
    
    # 64-bit DLLs -> system32
    find "${BUILD_DIR}/dxvk" -name '*.dll' \( -path '*/x64/*' -o -path '*/x86_64/*' \) -exec cp -v -t "${dest_64}/" {} + 2>&1 | tee -a "${BUILD_LOG}" || true
    # 32-bit DLLs -> syswow64 (handles x32 and x86 paths)
    find "${BUILD_DIR}/dxvk" -name '*.dll' \( -path '*/x32/*' -o -path '*/x86/*' -o -path '*/i386/*' \) -exec cp -v -t "${dest_32}/" {} + 2>&1 | tee -a "${BUILD_LOG}" || true
    
    log "DXVK installed to ${dest_64} and ${dest_32}"
}

fetch_vkd3d() {
    step "Fetching VKD3D-Proton"
    local dest_64="${DIST_DIR}/lib64/wine/x86_64-windows"
    local dest_32="${DIST_DIR}/lib64/wine/i386-windows"
    mkdir -p "${dest_64}" "${dest_32}" "${BUILD_DIR}/vkd3d"
    
    local res tarball
    res=$(download_github_latest "HansKristian-Work/vkd3d-proton" "vkd3d-proton-.*\\.tar\\.zst$" "${BUILD_DIR}/vkd3d" "vkd3d.tar.zst" "${VKD3D_VERSION}")
    tarball="${res%%|*}"
    VKD3D_DETECTED_VER="${res##*|}"
    
    log "Extracting VKD3D-Proton (${VKD3D_DETECTED_VER})..."
    tar -xf "${tarball}" -C "${BUILD_DIR}/vkd3d" --strip-components=1 2>&1 | tee -a "${BUILD_LOG}"
    
    # 64-bit DLLs -> system32
    find "${BUILD_DIR}/vkd3d" -name '*.dll' \( -path '*/x64/*' -o -path '*/x86_64/*' \) -exec cp -v -t "${dest_64}/" {} + 2>&1 | tee -a "${BUILD_LOG}" || true
    # 32-bit DLLs -> syswow64 (handles x32 and x86 paths)
    find "${BUILD_DIR}/vkd3d" -name '*.dll' \( -path '*/x32/*' -o -path '*/x86/*' -o -path '*/i386/*' \) -exec cp -v -t "${dest_32}/" {} + 2>&1 | tee -a "${BUILD_LOG}" || true
    
    log "VKD3D-Proton installed to ${dest_64} and ${dest_32}"
}

fetch_dxvk_nvapi() {
    step "Fetching DXVK-NVAPI"
    local dest_64="${DIST_DIR}/lib64/wine/x86_64-windows"
    local dest_32="${DIST_DIR}/lib64/wine/i386-windows"
    mkdir -p "${dest_64}" "${dest_32}" "${BUILD_DIR}/dxvk-nvapi"
    
    local res tarball
    res=$(download_github_latest "jp7677/dxvk-nvapi" "dxvk-nvapi-.*\\.tar\\.gz$" "${BUILD_DIR}/dxvk-nvapi" "dxvk-nvapi.tar.gz" "${DXVK_NVAPI_VERSION}")
    tarball="${res%%|*}"
    DXVK_NVAPI_DETECTED_VER="${res##*|}"
    
    log "Extracting DXVK-NVAPI (${DXVK_NVAPI_DETECTED_VER})..."
    tar -xzf "${tarball}" -C "${BUILD_DIR}/dxvk-nvapi" --strip-components=1 2>&1 | tee -a "${BUILD_LOG}"
    
    # 64-bit DLLs -> system32
    find "${BUILD_DIR}/dxvk-nvapi" -name '*.dll' \( -path '*/x64/*' -o -path '*/x86_64/*' \) -exec cp -v -t "${dest_64}/" {} + 2>&1 | tee -a "${BUILD_LOG}" || true
    # 32-bit DLLs -> syswow64
    find "${BUILD_DIR}/dxvk-nvapi" -name '*.dll' \( -path '*/x32/*' -o -path '*/x86/*' -o -path '*/i386/*' \) -exec cp -v -t "${dest_32}/" {} + 2>&1 | tee -a "${BUILD_LOG}" || true
    
    log "DXVK-NVAPI installed to ${dest_64} and ${dest_32}"
}

fetch_d7vk() {
    step "Fetching D7VK (Direct3D 7 / DDraw via Vulkan)"
    local dest_64="${DIST_DIR}/lib64/wine/x86_64-windows"
    local dest_32="${DIST_DIR}/lib64/wine/i386-windows"
    mkdir -p "${dest_64}" "${dest_32}" "${BUILD_DIR}/d7vk"
    
    local res tarball
    res=$(download_github_latest "WinterSnowfall/d7vk" "d7vk-.*\\.zip$" "${BUILD_DIR}/d7vk" "d7vk.zip" "${D7VK_VERSION}")
    tarball="${res%%|*}"
    D7VK_DETECTED_VER="${res##*|}"
    
    log "Extracting D7VK (${D7VK_DETECTED_VER})..."
    python3 -c "import zipfile; zipfile.ZipFile('${tarball}').extractall('${BUILD_DIR}/d7vk')" 2>&1 | tee -a "${BUILD_LOG}"
    
    # 64-bit DLLs -> system32
    find "${BUILD_DIR}/d7vk" -name '*.dll' \( -path '*/x64/*' -o -path '*/x86_64/*' \) -exec cp -v -t "${dest_64}/" {} + 2>&1 | tee -a "${BUILD_LOG}" || true
    # 32-bit DLLs -> syswow64
    find "${BUILD_DIR}/d7vk" -name '*.dll' \( -path '*/x32/*' -o -path '*/x86/*' -o -path '*/i386/*' \) -exec cp -v -t "${dest_32}/" {} + 2>&1 | tee -a "${BUILD_LOG}" || true
    
    log "D7VK installed to ${dest_64} and ${dest_32}"
}

fetch_wine_mono() {
    step "Fetching Wine-Mono"
    local dest="${DIST_DIR}/share/wine/mono"
    mkdir -p "${dest}" "${BUILD_DIR}/mono"
    
    local res tarball
    res=$(download_github_latest "wine-mono/wine-mono" "wine-mono-.*\\.msi$" "${BUILD_DIR}/mono" "wine-mono.msi" "${WINE_MONO_VERSION}")
    tarball="${res%%|*}"
    MONO_DETECTED_VER="${res##*|}"
    
    cp -v "${tarball}" "${dest}/" 2>&1 | tee -a "${BUILD_LOG}"
    log "Wine-Mono installed to ${dest}"
}

fetch_wine_gecko() {
    step "Fetching Wine-Gecko"
    local dest="${DIST_DIR}/share/wine/gecko"
    mkdir -p "${dest}" "${BUILD_DIR}/gecko"
    local version="${WINE_GECKO_VERSION}"
    local tarball="${BUILD_DIR}/gecko/wine-gecko-${version}-x86_64.tar.xz"
    local url="https://dl.winehq.org/wine/wine-gecko/${version}/wine-gecko-${version}-x86_64.tar.xz"
    
    log "Downloading Wine-Gecko ${version} from WineHQ..."
    download "${url}" "${tarball}"
    log "Extracting Wine-Gecko..."
    tar -xf "${tarball}" -C "${dest}" 2>&1 | tee -a "${BUILD_LOG}"
    log "Wine-Gecko installed to ${dest}"
}

fetch_fonts() {
    step "Fetching Liberation Fonts"
    local dest="${DIST_DIR}/share/fonts"
    mkdir -p "${dest}" "${BUILD_DIR}/fonts"
    
    if find /usr/share/fonts -iname "Liberation*.ttf" -print -quit | grep -q .; then
        log "Using system Liberation fonts from pacman..."
        find /usr/share/fonts -iname "Liberation*.ttf" -exec cp -v -t "${dest}/" {} + 2>&1 | tee -a "${BUILD_LOG}"
    else
        log "Downloading Liberation Fonts fallback..."
        local url="https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz"
        local tarball="${BUILD_DIR}/fonts/liberation-fonts.tar.gz"
        download "${url}" "${tarball}"
        tar -xzf "${tarball}" -C "${BUILD_DIR}/fonts" --strip-components=1 2>&1 | tee -a "${BUILD_LOG}"
        find "${BUILD_DIR}/fonts" -name '*.ttf' -exec cp -v -t "${dest}/" {} + 2>&1 | tee -a "${BUILD_LOG}"
    fi
    log "Fonts installed to ${dest}"
}

# ============================================================================================
# WINE BUILD
# ============================================================================================
build_wine() {
    step "Building Wine (WoW64 mode)"
    cd "${WINE_TKG_DIR}"

    # IMPORTANT: the non-makepkg path sources customization.cfg (prepare.sh
    # _init: source "$_where"/customization.cfg), NOT a root wine-tkg.cfg.
    # Writing to the wrong file silently drops every setting below (the
    # runner was previously built with _use_staging=true from the default
    # customization.cfg, and userpatches were never confirmed/applied).
    #
    # This build uses the staging base a011ce5724 (Build #12 known-good
    # commit) with staging enabled (_use_staging="true") plus the
    # d3dkmt_query_stats.mypatch for RE Engine compatibility.
    # _staging_upstreamignore="true" ensures the wine commit pin is
    # honored even when staging is active (prepare.sh:616 skips the
    # "reset to staging base" step, so the pin lands unconditionally).
    cat << EOF > customization.cfg
_LOCAL_PRESET="none"
_custom_wine_source="${WINE_GIT_URL}"
_plain_version="${WINE_COMMIT}"
_use_staging="true"
_staging_upstreamignore="true"
_unfrog="true"
_protonify="true"
_proton_fsync="true"
_wayland_driver="true"
_proton_use_steamhelper="false"
_steamvr_support="false"
_no_container="true"
_ci_build="true"
_user_patches_no_confirm="true"
_NOLIB32="wow64"
_no_steampath="y"
_no_autoinstall="true"
_skip_uninstaller="true"
_proton_fs_hack="false"
_proton_winevulkan="false"
_proton_mf_patches="false"
_use_fastsync="false"
_use_ntsync="false"
_use_esync="false"
_use_fsync="false"
_steamclient_noswap="false"
EOF

    # advanced-customization.cfg is sourced after customization.cfg and resets
    # this option to false by default, so override it in the final config layer.
    printf '\n_user_patches_no_confirm="true"\n' >> wine-tkg-profiles/advanced-customization.cfg

    # ------------------------------------------------------------------
    # d3dkmt QueryStatistics patch (self-contained, written at build time)
    # ------------------------------------------------------------------
    # NtGdiDdDDIQueryStatistics is an empty stub in wine (returns STATUS_SUCCESS
    # without writing the output buffer). The RE Engine (Resident Evil 2/3/7)
    # queries adapter statistics during renderer init and dereferences the
    # result -> null+8 crash at re2.exe+0x1f543d6. This patch zeroes the buffer
    # and fills ProcessAdapterInformation with plausible dummy values so the
    # game sees a valid 1-segment adapter.
    #
    # The non-makepkg path picks up *.mypatch from wine-tkg-userpatches/ and
    # applies them with patch -p1 (user_patcher). _user_patches_no_confirm=true
    # (set in customization.cfg above) makes the apply unconditional in CI.
    mkdir -p "${WINE_TKG_DIR}/wine-tkg-userpatches"
    cat > "${WINE_TKG_DIR}/wine-tkg-userpatches/d3dkmt_query_stats.mypatch" << 'PATCH_EOF'
--- a/dlls/win32u/d3dkmt.c
+++ b/dlls/win32u/d3dkmt.c
@@ -724,6 +724,41 @@ NTSTATUS WINAPI NtGdiDdDDIQueryStatistics( D3DKMT_QUERYSTATISTICS *stats )
 NTSTATUS WINAPI NtGdiDdDDIQueryStatistics( D3DKMT_QUERYSTATISTICS *stats )
 {
-    FIXME( "(%p): stub\n", stats );
+    D3DKMT_QUERYSTATISTICS_TYPE type;
+    LUID luid;
+
+    if (!stats) return STATUS_INVALID_PARAMETER;
+
+    /* Save the query header BEFORE zeroing: the game sends Type + AdapterLuid
+     * in the input struct and a conforming implementation must echo them back
+     * unchanged (re2.exe queries ADAPTER then ADAPTER_SEGMENT per GPU and
+     * re-reads the header after the call). */
+    type = stats->Type;
+    luid = stats->AdapterLuid;
+
+    TRACE( "(%p): type %u, adapter luid %08x:%08x\n", stats, type,
+           luid.HighPart, luid.LowPart );
+
+    /* Zero the whole buffer first so games that read the result never see
+     * garbage, then populate plausible dummy values. The RE Engine
+     * (Resident Evil 2/3/7, etc.) queries adapter statistics during renderer
+     * init and dereferences the result; the empty stub made it read a null
+     * structure and crash (re2.exe+0x1f543d6, movq 8(%rcx) with rcx=0). */
+    memset( stats, 0, sizeof(*stats) );
+
+    /* Echo the query header back to the caller. */
+    stats->Type = type;
+    stats->AdapterLuid = luid;
+
+    /* D3DKMT_QUERYSTATISTICS_PROCESS_ADAPTER / _PROCESS_SEGMENT queries:
+     * the game reads NbSegments/NodeCount/VidPnSourceCount and iterates
+     * over them — a zero count makes it dereference a null segment table. */
+    stats->QueryResult.ProcessAdapterInformation.NbSegments = 1;
+    stats->QueryResult.ProcessAdapterInformation.NodeCount = 1;
+    stats->QueryResult.ProcessAdapterInformation.VidPnSourceCount = 1;
+    stats->QueryResult.ProcessAdapterInformation.CommitmentData.BytesBySegmentPreference[0] = 0x40000000;
+    stats->QueryResult.ProcessAdapterInformation.CommitmentData.BytesBySegmentPreference[1] = 0x10000000;
+    stats->QueryResult.ProcessAdapterInformation._Policy.PreferAperture[0] = 1;
+    stats->QueryResult.ProcessAdapterInformation._Policy.PreferApertureForRead[0] = 1;
     return STATUS_SUCCESS;
 }
 
PATCH_EOF
    log "Wrote d3dkmt_query_stats.mypatch to wine-tkg-userpatches/"

    export _where="${WINE_TKG_DIR}"
    export srcdir="${BUILD_DIR}"
    
    chmod +x "${_where}"/wine-tkg-scripts/*.sh
    
    log "Starting Wine build via wine-tkg non-makepkg path..."
    ACTION="build" ./non-makepkg-build.sh 2>&1 | tee -a "${BUILD_LOG}"
    
    local built_dir
    built_dir=$(find "${_where}/non-makepkg-builds" -maxdepth 2 -type d -name 'wine-tkg-*' 2>/dev/null | head -1)
    if [[ -z "${built_dir}" ]]; then
        built_dir=$(find "${_where}" -maxdepth 2 -type d -name 'wine-tkg-*' 2>/dev/null | head -1)
    fi
    if [[ -z "${built_dir}" ]]; then
        err "Could not locate built wine-tkg directory in non-makepkg-builds"
    fi
    log "Found build output: ${built_dir}"
    
    step "Installing Wine build to dist/"
    mkdir -p "${DIST_DIR}"
    rsync -a "${built_dir}/" "${DIST_DIR}/" 2>&1 | tee -a "${BUILD_LOG}"
    log "Wine installed to ${DIST_DIR}"
}

# ============================================================================================
# PACKAGING & MANIFEST
# ============================================================================================
package_runner() {
    step "Packaging SteamFlow Runner"
    local output="${ROOT_DIR}/steamflow-runner-wine11-wow64.tar.gz"
    
    # Parseable key-value file for SteamFlow
    cat > "${DIST_DIR}/VERSIONS.txt" <<VERSIONS
WINE_COMMIT=$(cat "${BUILD_DIR}/wine_commit.txt" 2>/dev/null || echo "unknown")
DXVK_VERSION=${DXVK_DETECTED_VER}
VKD3D_PROTON_VERSION=${VKD3D_DETECTED_VER}
DXVK_NVAPI_VERSION=${DXVK_NVAPI_DETECTED_VER}
D7VK_VERSION=${D7VK_DETECTED_VER}
WINE_MONO_VERSION=${MONO_DETECTED_VER}
WINE_GECKO_VERSION=${WINE_GECKO_VERSION}
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
VERSIONS

    # Human-readable summary
    cat > "${DIST_DIR}/MANIFEST.txt" <<MANIFEST
SteamFlow WoW64 Wine Runner
===========================
Wine Commit: $(cat "${BUILD_DIR}/wine_commit.txt" 2>/dev/null || echo "unknown")
DXVK: ${DXVK_DETECTED_VER}
VKD3D-Proton: ${VKD3D_DETECTED_VER}
DXVK-NVAPI: ${DXVK_NVAPI_DETECTED_VER}
D7VK: ${D7VK_DETECTED_VER}
Wine-Mono: ${MONO_DETECTED_VER}
Wine-Gecko: ${WINE_GECKO_VERSION}
Fonts: $(ls "${DIST_DIR}/share/fonts"/*.ttf 2>/dev/null | wc -l) files
Built: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
MANIFEST

    cat "${DIST_DIR}/VERSIONS.txt" | tee -a "${BUILD_LOG}"

    log "Creating release archive: ${output}"
    tar -czf "${output}" -C "${ROOT_DIR}/dist" steamflow-runner 2>&1 | tee -a "${BUILD_LOG}"
    log "Archive created: ${output}"
    ls -lh "${output}" | tee -a "${BUILD_LOG}"
}

# ============================================================================================
# MAIN
# ============================================================================================
main() {
    mkdir -p "${BUILD_DIR}" "${DIST_DIR}"
    : > "${BUILD_LOG}"

    step "Starting SteamFlow WoW64 Wine 11 Master Runner Build"
    log "Root directory: ${ROOT_DIR}"
    log "Build directory: ${BUILD_DIR}"
    log "Dist directory: ${DIST_DIR}"
    log "Wine source: ${WINE_GIT_URL} @ ${WINE_COMMIT:-HEAD}"
    
    fetch_wine_source
    fetch_dxvk
    fetch_vkd3d
    fetch_dxvk_nvapi
    fetch_d7vk
    
    fetch_wine_mono
    fetch_wine_gecko
    fetch_fonts
    
    build_wine
    package_runner
    
    step "Build complete!"
    log "Artifact: ${ROOT_DIR}/steamflow-runner-wine11-wow64.tar.gz"
    log "Build log: ${BUILD_LOG}"
}

main "$@"
