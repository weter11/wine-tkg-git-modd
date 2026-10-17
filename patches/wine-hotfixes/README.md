# GE-Proton wine hotfixes, vendored for the Wine-Wineland diagnostic build

These are **verbatim upstream patch files**, fetched from
`gloriouseggroll/proton-ge-custom` at tag **GE-Proton11-9**:

    patches/wine-hotfixes/wine-wayland/                259 patches
    patches/wine-hotfixes/em-fixups/0001-*.patch       1 patch (SNI tray icons + native context menus)
    patches/wine-hotfixes/wineland-child-rendering/    85 patches
                                            + README.md

Why they are here: the cross-process dma-buf compositing path that refuses the direct
parent dma-buf on Wayland (`wayland_surface_direct_dmabuf_candidate`,
`wayland_surface_has_region_constraints`) exists **only** in GE-Proton's wine tree. Valve's
Proton (the base of the purepe runner) does not carry it: `strings winewayland.so | grep
'direct parent dmabuf'` returns 2 hits for GE-Proton11-9 and 0 for the purepe/wine-tkg/cachyos
builds. Building an instrumented driver therefore needs this tree.

Order of application (mirrors GE's own `patches/protonprep-valve-staging.sh`, lines ~126-140):

    1. wine-wayland/*.patch
    2. em-fixups/0001-winewayland-add-SNI-tray-icons-and-native-context-me.patch
    3. wineland-child-rendering/*.patch
    4. proton-purepe-wineland-diag.patch   (ours, see the repo root)
    5. patches/proton/83-nv_low_latency_wine.patch  (Nvidia Reflex / VK_NV_low_latency2)

Item 5 is **required**, and it is not ours: the child-rendering series' generator list
(`USER_DRIVER_FUNCS` in `dlls/winevulkan/make_vulkan`, extended by patch 0041) makes the
generated thunks call `vk_funcs->p_vkSetLatencySleepModeNV`, while the struct member and its
win32u implementation are added only by GE's `patches/proton/83-nv_low_latency_wine.patch`.
Without it `dlls/winevulkan/vulkan_thunks.c` fails to compile ~1.5 h into the build
(2026-10-17, CI run 39062234007). GE applies their `patches/proton/*` set late in their script;
`build-purepe.sh` applies item 5 right after item 4 and then runs a static gate that compares
every `vk_funcs->p_vk*` reference in a freshly generated `vulkan_thunks.c` against the
declarations in `include/wine/vulkan_driver.h` (75 functions / 75 declarations / 0 missing as of
this writing), so this class of mismatch fails in seconds instead of hours.

Base tree: `ValveSoftware/wine` commit **981e2f0b9007fd70a6e0ed6119cb18f4164e26f9** (the wine
pin of GE-Proton11-9; `build-purepe.sh` switches the wine submodule to it via `WINE_PIN`).
With that base the whole prefix applies cleanly: 259 + 1 + 85 patches, zero rejects
(verified locally 2026-10-17).

Only this prefix of GE's wine patches is applied - their later sets (`pending`,
`wine-staging/*`, `bluetooth-le`, `mta-certificate`, `qcap-dshow-fixes`, the remaining
`em-fixups` patches) are not, because the hypothesis under test lives entirely in the
Wine-Wineland compositing path. A diagnostic build is therefore not byte-identical to
GE-Proton11-9; state that when reporting results.

Upstream: Wine-Wineland by Erhan Bilgili <erhan.bilgili@gmail.com>
(https://github.com/nanomatters/wine-wineland), rebased onto GE-Proton's wine base by the
proton-ge-custom maintainers. Patch files carry their original mail headers and `Source:`
trailers.
