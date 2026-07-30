#!/usr/bin/env bash
# build-steamflow-runner.sh - Standalone WoW64 Wine 11 Master runner for SteamFlow
# Targets: Wine 11 Master (HEAD), pure WoW64 mode, no Valve Linux Steam bridge binaries

set -euo pipefail

# ============================================================================================
# VERSION PINS - Update these for component version bumps
# ============================================================================================
WINE_GIT_URL="https://gitlab.winehq.org/wine/wine.git"
WINE_COMMIT=""  # Empty = HEAD (master). Pin to a commit hash like "7177ece8" if needed.

# Component versions (empty = latest release from GitHub API)
DXVK_VERSION=""
VKD3D_VERSION=""
WINE_MONO_VERSION=""
WINE_GECKO_VERSION=""

# ============================================================================================
# BUILD CONFIGURATION
# ============================================================================================
BUILD_DIR="${PWD}/build"
DIST_DIR="${PWD}/dist/steamflow-runner"
WINE_SRC_DIR="${BUILD_DIR}/wine-git"
BUILD_LOG="${BUILD_DIR}/build.log"

# Wine build config (aligned with wine-tkg non-makepkg path)
export _NOLIB32="wow64"           # Pure WoW64 - 32-bit Windows apps via Wine's built-in WoW64
export _use_staging="false"        # No staging patches (pure master)
export _unfrog="true"              # Disable Frog/Proton patches (Linux bridge)
export _protonify="true"           # Proton game compatibility patches (minus bridge bits)
export _proton_fsync="true"        # Fsync support
export _wayland_driver="true"      # Wayland + Vulkan
export _proton_use_steamhelper="false"  # No Linux steamhelper
export _steamvr_support="false"    # No SteamVR
export _no_container="true"        # No Valve container
export _ci_build="true"
export _nomakepkg_dependency_autoresolver="true"
export _nomakepkg_prefix_path="${DIST_DIR}"
export _plain_version="${WINE_COMMIT}"
export _custom_wine_source="${WINE_GIT_URL}"
export _use_GE_patches="true"
export _GE_WAYLAND="true"
export _proton_rawinput="true"
export _proton_bcrypt="true"
export _childwindow_fix="true"
export _proton_force_LAA="true"
export _win10_default="true"
export _proton_winedbg_disable="true"
export _no_steampath="y"
export _no_autoinstall="true"
export _skip_uninstaller="true"
export _proton_fs_hack="false"
export _proton_winevulkan="false"
export _proton_mf_patches="false"
export _use_fastsync="false"
export _use_ntsync="false"
export _use_esync="false"
export _use_fsync="false"
export _steamclient_noswap="false"
export _proton_branch="experimental_11.0"

# GCC 14 compatibility flags
export CFLAGS="-O2 -pipe -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -fno-strict-aliasing"
export CXXFLAGS="${CFLAGS} -Wno-error=attributes"
export LDFLAGS="-Wl,-O1,--sort-common,--as-needed"
export CROSSCFLAGS="${CFLAGS}"
export CROSSCXXFLAGS="${CXXFLAGS}"
export CROSSLDFLAGS="${LDFLAGS}"
export MAKEFLAGS="-j$(nproc)"

# ============================================================================================
# HELPER FUNCTIONS
# ============================================================================================
log() { echo -e "\033[1;34m[build]\033[0m $*" | tee -a "${BUILD_LOG}"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" | tee -a "${BUILD_LOG}"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" | tee -a "${BUILD_LOG}"; exit 1; }
step() { echo -e "\n\033[1;36m=== $* ===\033[0m" | tee -a "${BUILD_LOG}"; }

download() {
    local url="$1" dest="$2"
    log "Downloading ${url} -> ${dest}"
    mkdir -p "$(dirname "${dest}")"
    if ! curl -fL --retry 3 --retry-delay 5 -o "${dest}" "${url}"; then
        err "Download failed: ${url}"
    fi
}

download_github_latest() {
    local repo="$1" pattern="$2" dest_dir="$3" dest_file="${4:-}"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    log "Fetching latest release from ${repo}..."
    local asset_url
    asset_url=$(curl -fLs "${api_url}" | grep -Eo '"browser_download_url":\s*"[^"]*'"${pattern}"'[^"]*"' | head -1 | sed 's/.*"browser_download_url":\s*"\([^"]*\)".*/\1/') || true
    if [[ -z "${asset_url}" ]]; then
        warn "Could not auto-detect ${pattern} from ${repo}, trying common patterns..."
        # Fallback: try to construct from tag name
        local tag_name
        tag_name=$(curl -fLs "${api_url}" | grep -Eo '"tag_name":\s*"[^"]*"' | head -1 | sed 's/.*"tag_name":\s*"\([^"]*\)".*/\1/') || true
        if [[ -n "${tag_name}" ]]; then
            asset_url="https://github.com/${repo}/releases/download/${tag_name}/$(echo ${pattern} | sed 's/.*\*//')"
            # This is best-effort fallback; if it fails, script will error out in download()
        fi
    fi
    if [[ -z "${asset_url}" ]]; then
        err "Failed to find asset matching ${pattern} in ${repo}"
    fi
    local outfile="${dest_dir}/${dest_file:-$(basename "${asset_url}")}"
    download "${asset_url}" "${outfile}"
    echo "${outfile}"
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
        log "Cloning Wine repository (this may take a while)..."
        git clone --mirror "${WINE_GIT_URL}" "${WINE_SRC_DIR}" 2>&1 | tee -a "${BUILD_LOG}"
    fi
    # Checkout target commit
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
    log "Wine commit: ${actual_commit}"
    echo "${actual_commit}" > "${BUILD_DIR}/wine_commit.txt"
}

fetch_dxvk() {
    step "Fetching DXVK"
    local dest="${DIST_DIR}/lib64/wine/x86_64-windows"
    mkdir -p "${dest}"
    local tarball
    if [[ -n "${DXVK_VERSION}" ]]; then
        tarball=$(download_github_latest "doitsujin/dxvk" "dxvk-${DXVK_VERSION}.tar.gz" "${BUILD_DIR}/dxvk" "dxvk.tar.gz")
    else
        tarball=$(download_github_latest "doitsujin/dxvk" "dxvk-.*\\.tar\\.gz$" "${BUILD_DIR}/dxvk" "dxvk.tar.gz")
    fi
    log "Extracting DXVK..."
    tar -xzf "${tarball}" -C "${BUILD_DIR}/dxvk" --strip-components=1 2>&1 | tee -a "${BUILD_LOG}"
    # Copy 64-bit DLLs
    find "${BUILD_DIR}/dxvk" -name '*.dll' -path '*/x64/*' -exec cp -v {} "${dest}/" \\; 2>&1 | tee -a "${BUILD_LOG}"
    find "${BUILD_DIR}/dxvk" -name '*.dll' -path '*/x86_64/*' -exec cp -v {} "${dest}/" \\; 2>&1 | tee -a "${BUILD_LOG}"
    log "DXVK DLLs installed to ${dest}"
}

fetch_vkd3d() {
    step "Fetching VKD3D-Proton"
    local dest="${DIST_DIR}/lib64/wine/x86_64-windows"
    mkdir -p "${dest}"
    local tarball
    if [[ -n "${VKD3D_VERSION}" ]]; then
        tarball=$(download_github_latest "HansKristian-Work/vkd3d-proton" "vkd3d-proton-${VKD3D_VERSION}.tar.zst" "${BUILD_DIR}/vkd3d" "vkd3d.tar.zst")
    else
        tarball=$(download_github_latest "HansKristian-Work/vkd3d-proton" "vkd3d-proton-.*\\.tar\\.zst$" "${BUILD_DIR}/vkd3d" "vkd3d.tar.zst")
    fi
    log "Extracting VKD3D-Proton..."
    tar -xf "${tarball}" -C "${BUILD_DIR}/vkd3d" --strip-components=1 2>&1 | tee -a "${BUILD_LOG}"
    # Copy 64-bit DLLs
    find "${BUILD_DIR}/vkd3d" -name '*.dll' -path '*/x64/*' -exec cp -v {} "${dest}/" \\; 2>&1 | tee -a "${BUILD_LOG}"
    log "VKD3D-Proton DLLs installed to ${dest}"
}

fetch_wine_mono() {
    step "Fetching Wine-Mono"
    local dest="${DIST_DIR}/share/wine/mono"
    mkdir -p "${dest}"
    local tarball
    if [[ -n "${WINE_MONO_VERSION}" ]]; then
        tarball=$(download_github_latest "madewokherd/wine-mono" "wine-mono-${WINE_MONO_VERSION}.msi" "${BUILD_DIR}/mono" "wine-mono.msi")
    else
        tarball=$(download_github_latest "madewokherd/wine-mono" "wine-mono-.*\\.msi$" "${BUILD_DIR}/mono" "wine-mono.msi")
    fi
    cp -v "${tarball}" "${dest}/" 2>&1 | tee -a "${BUILD_LOG}"
    log "Wine-Mono installed to ${dest}"
}

fetch_wine_gecko() {
    step "Fetching Wine-Gecko"
    local dest="${DIST_DIR}/share/wine/gecko"
    mkdir -p "${dest}"
    local tarball
    if [[ -n "${WINE_GECKO_VERSION}" ]]; then
        tarball=$(download_github_latest "wine-mirror/wine-gecko" "wine-gecko-${WINE_GECKO_VERSION}-x86_64.tar.xz" "${BUILD_DIR}/gecko" "wine-gecko.tar.xz")
    else
        tarball=$(download_github_latest "wine-mirror/wine-gecko" "wine-gecko-.*-x86_64\\.tar\\.xz$" "${BUILD_DIR}/gecko" "wine-gecko.tar.xz")
    fi
    log "Extracting Wine-Gecko..."
    tar -xf "${tarball}" -C "${dest}" --strip-components=1 2>&1 | tee -a "${BUILD_LOG}"
    log "Wine-Gecko installed to ${dest}"
}

fetch_fonts() {
    step "Fetching Liberation Fonts"
    local dest="${DIST_DIR}/share/fonts"
    mkdir -p "${dest}"
    # Use system fonts if available, otherwise download
    if [[ -d /usr/share/fonts/liberation ]]; then
        log "Using system Liberation fonts"
        cp -v /usr/share/fonts/liberation/*.ttf "${dest}/" 2>&1 | tee -a "${BUILD_LOG}"
    else
        log "Downloading Liberation Fonts..."
        local url="https://github.com/liberationfonts/liberation-fonts/files/5931818/liberation-fonts-ttf-2.1.5.tar.gz"
        local tarball="${BUILD_DIR}/fonts/liberation-fonts.tar.gz"
        download "${url}" "${tarball}"
        tar -xzf "${tarball}" -C "${BUILD_DIR}/fonts" --strip-components=1 2>&1 | tee -a "${BUILD_LOG}"
        find "${BUILD_DIR}/fonts" -name '*.ttf' -exec cp -v {} "${dest}/" \\; 2>&1 | tee -a "${BUILD_LOG}"
    fi
    log "Fonts installed to ${dest}"
}

# ============================================================================================
# WINE BUILD (via wine-tkg non-makepkg path)
# ============================================================================================
build_wine() {
    step "Building Wine (WoW64 mode)"
    cd "${PWD}/wine-tkg-git"
    
    # Source the non-makepkg build script
    export _where="${PWD}/wine-tkg-git"
    export srcdir="${BUILD_DIR}"
    
    # Override variables for our build
    export _NOLIB32="wow64"
    export _use_staging="false"
    export _unfrog="true"
    export _protonify="true"
    export _proton_fsync="true"
    export _wayland_driver="true"
    export _proton_use_steamhelper="false"
    export _steamvr_support="false"
    export _no_container="true"
    export _ci_build="true"
    export _nomakepkg_dependency_autoresolver="true"
    export _nomakepkg_prefix_path="${DIST_DIR}"
    export _plain_version="${WINE_COMMIT}"
    export _custom_wine_source="${WINE_GIT_URL}"
    export _use_GE_patches="true"
    export _GE_WAYLAND="true"
    export _proton_rawinput="true"
    export _proton_bcrypt="true"
    export _childwindow_fix="true"
    export _proton_force_LAA="true"
    export _win10_default="true"
    export _proton_winedbg_disable="true"
    export _no_steampath="y"
    export _no_autoinstall="true"
    export _skip_uninstaller="true"
    export _proton_fs_hack="false"
    export _proton_winevulkan="false"
    export _proton_mf_patches="false"
    export _use_fastsync="false"
    export _use_ntsync="false"
    export _use_esync="false"
    export _use_fsync="false"
    export _steamclient_noswap="false"
    export _proton_branch="experimental_11.0"
    export _LOCAL_PRESET="none"
    
    # Ensure scripts are executable
    chmod +x "${_where}"/wine-tkg-scripts/*.sh
    
    # Run the build via non-makepkg path
    log "Starting Wine build via wine-tkg non-makepkg path..."
    cd "${_where}"
    ACTION="build" ./non-makepkg-build.sh 2>&1 | tee -a "${BUILD_LOG}"
    
    # The build output goes to ${_where}/wine-tkg-* or similar; find it
    local built_dir
    built_dir=$(find "${_where}" -maxdepth 1 -type d -name 'wine-tkg-*' 2>/dev/null | head -1)
    if [[ -z "${built_dir}" ]]; then
        err "Could not locate built wine-tkg directory"
    fi
    log "Found build output: ${built_dir}"
    
    # Copy to our dist structure
    step "Installing Wine build to dist/"
    mkdir -p "${DIST_DIR}"
    rsync -a "${built_dir}/" "${DIST_DIR}/" 2>&1 | tee -a "${BUILD_LOG}"
    log "Wine installed to ${DIST_DIR}"
}

# ============================================================================================
# PACKAGING
# ============================================================================================
package_runner() {
    step "Packaging SteamFlow Runner"
    local output="${PWD}/steamflow-runner-wine11-wow64.tar.gz"
    log "Creating archive: ${output}"
    tar -czf "${output}" -C "${PWD}/dist" steamflow-runner 2>&1 | tee -a "${BUILD_LOG}"
    log "Archive created: ${output}"
    ls -lh "${output}" | tee -a "${BUILD_LOG}"
    
    # Write manifest
    cat > "${PWD}/dist/steamflow-runner/MANIFEST.txt" <<MANIFEST
SteamFlow WoW64 Wine Runner
===========================
Wine: $(cat "${BUILD_DIR}/wine_commit.txt" 2>/dev/null || echo "unknown")
DXVK: $(ls "${DIST_DIR}/lib64/wine/x86_64-windows"/dxvk*.dll 2>/dev/null | head -1 | xargs basename || echo "not found")
VKD3D: $(ls "${DIST_DIR}/lib64/wine/x86_64-windows"/vkd3d*.dll 2>/dev/null | head -1 | xargs basename || echo "not found")
Mono: $(ls "${DIST_DIR}/share/wine/mono"/wine-mono*.msi 2>/dev/null | head -1 | xargs basename || echo "not found")
Gecko: $(ls "${DIST_DIR}/share/wine/gecko" 2>/dev/null | head -1 || echo "not found")
Fonts: $(ls "${DIST_DIR}/share/fonts"/*.ttf 2>/dev/null | wc -l) files
Built: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
MANIFEST
    cat "${PWD}/dist/steamflow-runner/MANIFEST.txt" | tee -a "${BUILD_LOG}"
}

# ============================================================================================
# MAIN
# ============================================================================================
main() {
    step "Starting SteamFlow WoW64 Wine 11 Master Runner Build"
    log "Build directory: ${BUILD_DIR}"
    log "Dist directory: ${DIST_DIR}"
    log "Wine source: ${WINE_GIT_URL} @ ${WINE_COMMIT:-HEAD}"
    
    mkdir -p "${BUILD_DIR}" "${DIST_DIR}"
    : > "${BUILD_LOG}"
    
    # Fetch all components in parallel where possible
    fetch_wine_source &
    fetch_dxvk &
    fetch_vkd3d &
    fetch_wine_mono &
    fetch_wine_gecko &
    fetch_fonts &
    wait
    
    # Build Wine (this takes the longest, do it last after downloads)
    build_wine
    
    # Package
    package_runner
    
    step "Build complete!"
    log "Artifact: ${PWD}/steamflow-runner-wine11-wow64.tar.gz"
    log "Build log: ${BUILD_LOG}"
}

main "$@"
