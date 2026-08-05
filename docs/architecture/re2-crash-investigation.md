# RE2 First-Frame Crash — Provenance Chain & Investigation Notes

**Date:** 2026-08-04
**Runner:** `steamflow-runner-wine11-wow64` (b16, WINE_COMMIT `a011ce5724`, wine-tkg 11.14 staging)
**Game:** Resident Evil 2 (Steam app 883710), `re2.exe` PE 0x140000000–0x149bba000
**Crash:** `Unhandled page fault on read access to 0x0000000000000008` at `re2+0x1f543d6`

---

## 1. Root cause (empirically confirmed)

The crash is a NULL+8 dereference caused by an **empty adapter table**:

```
141f54324: mov $0x1,%edx                  ; loop counter i starts at 1
141f5434a: cmp %edx,0xc(%rcx); jbe skip   ; guard: count<=1 → skip fill entirely
141f54360: mov %edx,%eax
141f54362: lea (%rax,%rax,4),%rcx         ; rcx = i*5
141f54366: shl $0x4,%rcx                  ; rcx = i*80  (80-byte record stride)
141f5436a: add %r9,%rcx                   ; rcx = &record[i]   (records @ 0x1491b0300)
141f5436d: mov 0x8(%rcx),%rax             ; rax = record[i].field8    ← THE READ
141f54371: shr $0x36,%rax                 ; >> 54
141f54375: test $0x3ff,%eax               ; isolate bits 54-63
141f5437a: je 0x141f54389                 ; ZERO → SKIP (no table write)
141f5437c: and $0x3ff,%eax                ; idx = (field8>>54) & 0x3ff
141f54381: mov %rcx,0x91aff50(%r11,%rax,8); table[idx] = &record[i]
...
141f543ce: mov 0x91aff50(%r11,%rax,8),%rcx; rcx = table[1]  (index 1, from static .rdata)
141f543d6: mov 0x8(%rcx),%rax             ; ← CRASH: table[1] = NULL → read 0x8(NULL)
```

- **Table base:** `0x1491aff50` (RVA `0x91aff50`), 8-byte slots.
- **Records:** `0x1491b0300`, 80-byte stride, `field8` at +8.
- Every record's `field8` = a game-internal image pointer (`0x1482E78D0`, `0x14839A8E0`, …) with
  bits 54–63 = **0** → `je` skips every record → `table[1]` stays NULL → crash.

### Provenance of field8 (watchpoint-captured)

Hardware watchpoints on `0x1491b0308` (rec0.field8) and `0x1491b0358` (rec1.field8) fired at
**`0x141f542e6` / `0x141f5430c`** — the game's own 128-byte struct copies:

```
141f545d5: mov 0x68(%rcx),%rax    ; rax = RELATIVE OFFSET (0xF08C00)
141f545de: add %rcx,%rax          ; rax = struct_base + offset   ← deserializer fixup
141f545e6: mov %rax,0x68(%rcx)    ; field8 = 0x1473de9d0 + 0xF08C00 = 0x1482E78D0
```

- Source struct at `0x1473de9d0` ("TDB" magic `0x424454`, size 0x46) is **static game data**
  — the PE file bytes at RVA `0x73de9d8` are identical to runtime (LUID-like constants
  `0x13677`, `0x1c757`, `0x13d5b`, `0x4aff` are compile-time, never written at runtime;
  watchpoint on `0x1473de9d8` never fired).
- **Wine never consults/feeds field8.** Neither hAdapter nor the LUID reaches it.

### Verdicts on prior theories

| Theory | Result |
|---|---|
| amd_ags_x64 / vendor SDK collision | **REFUTED** — 0 `agsInitialize` in 2.65M-line relay, 0 `GetProcAddress ags*`; `amd_ags_x64=b` override test crashed byte-identically. Loads but never invoked. |
| Wine hands back "low-looking" hAdapter → kernel-pointer-shape theory | **REFUTED for field8** — game computes field8 itself (`base + offset`), no wine involvement. |
| llvmpipe / GPU enumeration / VEN_0005 count | **REFUTED** — byte-identical crash with llvmpipe removed (VEN_0005=0). |
| Bit-54 on hAdapter / `handle_to_index` | **REFUTED + dangerous** — hAdapter never reaches field8; setting bit 54 would break wine's own handle table (`handle_to_index` = `(handle & ~0xc0000000) >> 6`). |
| b15 staging-off regression | **INVERTED** — b15 ran staging OFF; fix = b16 pin (`a011ce5724` + `_use_staging=true` + `_staging_upstreamignore=true` + d3dkmt userpatch). |

### Wine's D3DKMT side (from pinned source)

- `NtGdiDdDDIOpenAdapterFromDeviceName` (sysparams.c:8029) is a wrapper → delegates to
  `NtGdiDdDDIOpenAdapterFromLuid` (d3dkmt.c:614).
- `hAdapter = index_to_handle(index) = (index << 6) | 0x40000000` → `0x40000000`, `0x40000040`,
  `0x40000080` — **bits 54-63 = 0 always**.
- LUID from `NtAllocateLocallyUniqueId` (sysparams.c:1809) or registry cache — bits 54-63 = 0.
- Game uses hAdapter only in the 0x328 `QueryStatistics` buffer (all 6 calls succeed,
  `retval=00000000`), never in field8.

---

## 2. Fill-loop bypass experiment (validated the diagnosis)

In-memory patch applied at 0.6s interrupt (ptrace bypasses page permissions):

| Site | Bytes | Patch |
|---|---|---|
| `0x141f5437a` | `74 0d` (je) | `90 90` (nop — never skip) |
| `0x141f5437c` | `25 ff 03 00 00` (and $0x3ff) | `b8 01 00 00 00` (mov $1,%eax — force idx=1) |
| `0x141f543f3` | `0f 84 87 00 00 00` (je → table[83]) | `90` ×6 (nop) |
| `0x141f543c0` | `48 63 46 e0` (movslq -0x20(%rsi)) | `6a 01 58 90` (push 1; pop rax) |
| `0x141f54480` | `48 63 46 f8` (movslq -0x8(%rsi)) | `6a 01 58 90` |

**Result:** `table[1]` populated (`0x1479ef1b0`), crash **moved from `0x141f543d6` to
`0x141f7801a`** — ~146 KB forward with a valid 7-frame backtrace. **Diagnosis 100% confirmed.**

The game iterates a static GPU-index list (`1, 0x53, 0x54, 0x55, 0x50, 0x58, 0x56…` in .rdata
at `0x1458c0b20`, stride 0x30) and reads `table[idxA]` then `table[idxB]` per entry — hence the
lookup patches forcing index 1.

---

## 3. Second crash site & the zero-writer global `0x1491b0050`

**New crash after bypass:** `0x141f7801a` — `mov 0x14(%rdx),%eax` with `rdx = [0x1491b0050] = NULL`.

Caller loop (`0x141f80390`–`0x141f803cb`, owner fn `0x141f80260`):
```
141f80397: mov [0x1491b0050],%r13    ; r13 = context global → NULL
141f803b6: mov %r13,%rdx             ; rdx = NULL (2nd arg to record processor)
141f803c4: add [0x1491b0300],%rsi    ; rsi = records_base + i*80  (VALID)
141f803cb: call 0x141f78010          ; f(rcx=rbx, rdx=NULL, rsi=&record[i], r8=0)
141f7801a: mov 0x14(%rdx),%eax       ; ← CRASH (needs ctx->+0x14)
141f7802c: testb $0x1,0x13(%rdx)     ;     ctx->+0x13 flag
141f7806f: mov 0x48(%rbx),%rax       ;     ctx->+0x48 src
```

### Zero-writer proof (exhaustive)

`0x1491b0050` (RVA `0x91b0050`, in `.data` **BSS tail** — file-backed range ends at
`0x90db000`, so it is zero-filled by loader):

| Search | Result |
|---|---|
| RIP-relative stores (objdump `# 0x1491b0050`) | **0 stores / 5 loads** |
| `lea` address-taken | 0 |
| `movabs` moffs64 (A3/A1) | 0 |
| Absolute disp32 SIB (`89/8b/8d xx 25 disp32`) | 0 |
| Raw imm32/imm64 in .text | 0 |
| Exports (data at RVA 0x91b0050) | none (re2.exe exports only Wwise) |
| **Hardware watchpoint (runtime, patched run)** | **never fired** |

The whole `0x1491b0000–0x1491b00ff` region is a read-only global struct (~20 pointer slots:
`+0x00,+0x08,+0x10,+0x18,+0x20,+0x50,+0x58,+0x60,+0x68,+0x70,+0x78,+0x80,+0x88,+0x90,+0xb0,
+d8,+e0,+e8,+f8`) — 44+ refs, **all loads**, never written, never address-taken.

### Gate-chain probes (hypothesis inverted)

- `flag [0x1491c7b80] = 0x01`, `flag [0x1491c7b81] = 0x01` — adapter subsystem **initialized**
  (writer `0x14200cd87` ran before 0.6s arm).
- `0x14200bc10` (context creator, called at `0x141f80214`) returned **`0x7fffc08f8520` (non-NULL)**
  → the `je 0x141f80281` skip at `0x141f8021f` was **NOT taken**.
- `0x14200bf80` is a type-tag **dispatcher** (`mov -0x4(%rcx); shr $0x1d` → index into
  `0x1491c7bb0` 0x288-stride array → `0x14200a4e0`), not the initializer.
- Sibling cluster `0x1491c7b90/98/a0` is written by the game (teardown at `0x14200c0ff/143/14a`)
  but is a **different structure** from the `0x1491b0000` region.

### Conclusion

`0x1491b0050` is a **game-side struct field with zero writers in the entire PE** (any
addressing form) and **zero executed writes** (watchpoint). It is not branch-gated, not
patchable in re2.exe, not an export. **Rejected: game-side binary patch hypothesis.**

The value must be supplied by **an external module** (dxgi/d3d12/vulkan or a game-bundled DLL)
writing into the game's data via a pointer handed over during module init — a device/adapter
context object the runner's minimal build never creates. See next section.

---

## 4. DLL handoff investigation (next steps)

- **No DXGI/D3D12/vulkan calls appear in the relay before the crash** — the game's pre-crash
  init is D3DKMT-only (18 `NtGdiDdDDI*` hits, OpenAdapterFromDeviceName + QueryStatistics
  only).
- Game-side binary patch hypothesis for `0x1491b0050`: **REJECTED** (see §3).
- **QueryStatistics capture (2026-08-05, gdb, all 6 calls on b16):** the game queries 3 GPUs
  (LUID HighParts `0x3f5/0x456/0x457`), each with `D3DKMT_QUERYSTATISTICS_ADAPTER` (Type 0,
  calls 1-3) then `_ADAPTER_SEGMENT` (Type 3, calls 4-6). b16's dummy fill works but its
  memset-first approach **clobbers the input header** (Type returned 0 for calls 4-6,
  AdapterLuid wiped). **Fixed in b17** (commit `c2c1c788`+`fc7d9fd3`): save/restore
  Type+AdapterLuid around the memset, TRACE logs `type %u, adapter luid %08x:%08x`.
- Next lever: runner's `d3d12.dll`/`dxgi.dll` (VKD3D-Proton) `DLL_PROCESS_ATTACH` behavior and
  whether the device-context constructor populates the external adapter struct; verify
  `WINEDLLOVERRIDES` mapping (`d3d12=n,b; d3d12core=n,b; dxgi=n,b` present in
  `effective_launch_config.json`).
- **DLL attach verdict (2026-08-05):** `dxgi.dll`+`d3d11.dll` DO get `DLL_PROCESS_ATTACH`
  (relay-verified) but both entries are the minimal wine stub (RVA 0x11f0: config-key reads
  only, no D3DKMT/device work). `d3d12.dll` (VKD3D-Proton forwarder shim → `d3d12core.dll`
  via `LoadLibraryA`+`GetProcAddress`) is **never attached** — re2.exe imports `dxgi.dll` +
  `d3d11.dll` but NOT `d3d12.dll` statically, and zero graphics calls occur pre-crash. So
  the runner's DLLs execute no adapter/device setup in the crashing window; the
  `0x1491b0050` writer must be game-side code that never runs under wine, or a wine D3DKMT
  data-shape gap.

---

## 5. Working debug harness (reusable)

**Methodology-first rule:** primary evidence = hardware watchpoint, not disassembly/call-order
reasoning (earlier "QueryStatistics precedes crash" was 1.46M log lines apart and false).

Proven recipe (gdb under launch; gdb must be parent — Yama ptrace_scope=1 blocks attach):
1. Launch `gdb -q -x cmds --args wine re2.exe`.
2. Python timer thread sends `interrupt` at **0.6s** (module maps ~1s; records written
   ~1–2s; crash beats 1.5s under `WINEDEBUG=-all`; measured `ELAPSED=3.94`/`5.55s` without
   debug logging).
3. Poll until the target `.text` page is readable (interrupt can land mid-load).
4. Arm `hbreak` + HW watchpoints post-exec; use `interrupt -a` semantics — plain async
   `continue` fails with "selected thread is running".
5. Continue; capture `info registers` + `bt` + memory dumps on each hit.

**Pitfalls (all empirical):**
- wine's SIGUSR1 handler clobbers DR registers → arm only after the exec/interrupt.
- `exec` of wine-preloader resets DR → never arm pre-run.
- re2.exe invisible to gdb solib events (wine maps the PE itself, not via dlopen).
- HW watchpoints false-positive on **mangohud threads** (known wine+gdb quirk) — prefer fixed
  game-global addresses or filter by thread.
- winedbg deferred breakpoints disable at set time even with `$CanDeferOnBPByAddr=1`;
  `winedbg --gdb` remote-stub port is undocumented (not 3456).
- Raw-address breakpoints cannot insert before the PE maps (wine execs wine-preloader first);
  poll the page instead.

### Key addresses (current task map)

| Symbol | Address |
|---|---|
| table | `0x1491aff50` (slot[5] static default only) |
| table[1] | `0x1491aff58` |
| records | `0x1491b0300` (80-byte stride, field8 at +8) |
| fill-loop field8 read | `0x141f5436d` |
| struct-copy stores | `0x141f542e6` / `0x141f5430c` |
| deserializer fixup | `0x141f545e6` / `0x141f5460f` |
| source struct ("TDB") | `0x1473de9d0` (src+0x60=`0x1473dea30`, src+0x68=`0x1473dea38`) |
| crash site 1 | `0x141f543d6` |
| crash site 2 (after bypass) | `0x141f7801a` |
| zero-writer global | `0x1491b0050` (BSS, 0 writers, 5 readers) |
| context creator | `0x14200bc10` (returns non-NULL) |
| dispatcher | `0x14200bf80` (type-tag → `0x1491c7bb0` + tag*0x288 → `0x14200a4e0`) |
| subsystem flags | `0x1491c7b80/81/82` (all set to 1) |
| GPU-index list | `0x1458c0b20` (.rdata, stride 0x30, idxA at -0x20, idxB at -0x8) |

### Evidence files (`/home/wer/tmp/`)

- `re2_watch6.txt` — field8 watchpoint hits (provenance)
- `re2_src_watch3.txt` — fixup-routine watchpoint hits
- `re2_luid_watch.txt` — LUID-field watch (never fired; static data)
- `re2_g0050_watch.txt` / `re2_g0050_watch2.txt` — `0x1491b0050` watch (never fired)
- `re2_gate_probe.txt` — creator/flags probes (hypothesis inverted)
- `re2_fillpatch.txt` — bypass experiment (+146KB progress)
- `re2_firstinit_probe.txt` — factory/first-init probe
- `re2_full_relay.log` — 179MB relay (AGS never called, D3DKMT-only pre-crash)
- `re2_gdb_backtrace.txt` — original SIGSEGV capture

---

## 6. Post-OpenAdapter record construction — static-data deserializer (investigation COMPLETE)

**Status: COMPLETE (2026-08-05).** The record builder feeds strictly from static `.data`
templates; no `OpenAdapter` handle or runtime LUID ever populates `rec.field8`. The
`(field8>>54)&0x3ff` tag is therefore **always 0 by construction** under wine — a game-side
expectation mismatch, not a wine D3DKMT data defect.

### 6.1 Record instantiator — `0x141f54270`

Copies **0xE0 bytes per record** (0x80 + 0x60) from two source regions into the
`0x1491b02a0+` record array:

```
141f5428c: movups (%rcx),%xmm0         ; source A: 8×16B = 0x80 bytes
141f542a0: movups %xmm0,0x91b02a0(%r11) ; → dest 0x1491b02a0 (records area)
141f542a8: lea 0x91b02a0(%r11),%rdx
141f542b3: lea 0x80(%rdx),%rdx          ; stride 0x80
... 14 more movups (source B = rcx+0x80 → dest+0x80), last qword at 0x141f54320
```

Called from the orchestrator `0x141f7fbd3` (fn `0x141f7f870`, crash backtrace frame #2).
The watchpoint-verified writes to `0x1491b0308/0x1491b0358` (field8 of rec0/rec1) are the
`movups` at `0x141f542e6/0x141f5430c` — the records ARE built, but from the static
template, not from any D3DKMT result.

### 6.2 "TDB" deserializer — `0x141f54590`

Validates the magic header and performs **self-relative pointer fixups**:

```
141f54590: cmpl $0x424454,(%rcx)        ; "TDB" magic — else return 0
141f545a4: cmpl $0x46,0x4(%rcx)         ; size check
141f545aa: mov 0x58(%rcx),%rax
141f545b0: lea (%rax,%rcx,1),%r8        ; r8 = base + field58
141f545bc: mov 0x60(%rcx),%rax
141f545c9: add %rcx,%rax                ; field60 = base + field60
141f545d5: mov 0x68(%rcx),%rax
141f545de: add %rcx,%rax                ; field68 = base + field68
141f545e6: mov %rax,0x68(%rcx)          ; ← field8 source = src+0x68 = 0x1473dea38
... (same pattern for +0x70, ...)
```

Each non-zero field at +0x58/+0x60/+0x68/+0x70 gets `field += struct_base`. For field8:
`0x1473de9d0 + 0xF08C00 = 0x1482E78D0` — an **in-image pointer**, computed by the game
itself. Wine is never consulted.

### 6.3 Static-data provenance (full chain, call-graph closed)

```
14087f1ed: lea 0x1473de9d0,%rdx          ; ← STATIC .data TDB template (baked constants)
14087f1f7: call 0x141f7f870              ; orchestrator(rcx=[0x149178e98], rdx=template)
  141f7f889: mov %rdx,%rsi               ; rsi = template
  141f7f899: call 0x141f54590            ; "TDB" deserializer (magic + fixups)
  141f7fbc7: mov %rsi,0x35d8(%r15)
  141f7fbce: call 0x141f54270            ; copy 0xE0-byte records
```

- Source = compile-time `.data` (RVA `0x73de9d8` file bytes `00 00 00 00 77 36 01 00 …`
  byte-identical to runtime; LUID-like constants `0x13677/0x1c757/0x13d5b/0x4aff` never
  written at runtime — watchpoint never fired).
- `0x1491b02ac` (record count) and `0x1491b0300` (records base) have **no RIP-relative
  writers** — same class as `0x1491b0050`; they live in the same BSS region and are written
  by the copy function via `r11`-relative addressing (`0x91b02a0(%r11)`, objdump-annotated).
- **No code path packs hAdapter/LUID/index into field8's bits 54–63.** 0 stores targeting it,
  no OR/shift on it anywhere. The `OpenAdapterFromDeviceName` handles (3 calls, all SUCCESS)
  and the 0x328 QueryStatistics buffers feed a **different** consumer (the `0x1491c7b90`
  object list + per-GPU stats), never field8.

### 6.4 Why the tag is always 0 under wine

The `(field8>>54)&0x3ff` check is a tagged-pointer discriminator. The records are copies
of a static template whose pointers are in-image (top bits 0). On Windows the game must
obtain differently-tagged records from a path that never executes under this runner —
consistent with the §3 zero-writer evidence: the tag source is absent, so `table[1]` is
never populated and the fill loop crashes.

**Verdict:** static-data deserializer investigation CLOSED. Record construction is
game-internal static templating; the fix must make the game reach a code path that tags
records (or a runner-level adapter identity the game expects), not patch the fill loop or
the deserializer. GDB reverse-engineering of the pre-crash init is paused.

---

## 7. Open questions and next steps (2026-08-05)

What a fresh session should try next, in priority order:

1. **The game's tagging code path on Windows.** The records are static-template
   copies whose field8 tags are 0 under wine. On Windows the game must obtain
   tagged records from a path that never executes here. Candidate: identify the
   code that would normally overwrite field8 (or its source) with an adapter
   identity — the `0x14200c9xx` enumeration region and the `0x1491c7b90` object
   list are the only D3DKMT-fed consumers; verify whether a Windows KMD-shaped
   base (bits 54-63 set) is expected via `base+offset` in the deserializer.
2. **Re-test b17 through SteamFlow** (runner already installed, b16 in
   `.b16bak`): confirm QueryStatistics Type/Luid echo-back via the +d3dkmt
   TRACE, and re-check whether the crash site moved at all under the new
   win32u.so (expected: still `0x141f543d6` — but confirm empirically).
3. **Wine D3DKMT data-shape gap** — if the game does consume some D3DKMT
   return to tag records on Windows, compare wine's `d3dkmt.c` struct layouts
   (adapter LUID/handle) against what the record fields expect.
4. **Do NOT revisit:** AGS, llvmpipe/GPU-count, QueryAdapterInfo, hAdapter
   bit-54, `0x1491b0050` patching, fill-loop patching — all empirically
   refuted or unpatchable (see §1–§6).

---

## 8. Proton win32u comparison + record-array writer proof (2026-08-05)

**Status: COMPLETE.** Answers §7.1–§7.3 definitively. Proton's win32u does NOT
custom-patch any D3DKMT adapter-identity path; the records array (rec2+) has
**zero writers** in the whole PE; the "GPU-index list" is actually a
method-dispatch table. The `d3dkmt_proton_parity.mypatch` userpatch (verified
against pinned `a011ce5724`) is the only win32u lever available.

### 8.1 Proton vs wine-tkg win32u (diff of `d3dkmt.c` + `sysparams.c`)

Clone: `wine-proton` @ `proton_11.0` (`81d78e4`, shallow). Diff vs pinned
wine-src (`a011ce5724`, wine-tkg 11.14 staging):

**`dlls/win32u/d3dkmt.c`** (97-line diff — every hunk catalogued):
- `#define WIN32_NO_STATUS` + `#include "d3dkmdt.h"` (needed for the caps struct)
- `KMT_DRIVERVERSION_WDDM_3_1` → **`KMT_DRIVERVERSION_WDDM_1_3`** (Valve pins
  WDDM 1.3 — RE Engine titles gate DX12 features on this value)
- **NEW `KMTQAITYPE_WDDM_2_7_CAPS` case** — reads VkPhysicalDeviceDriverProperties,
  advertises Hardware-Scheduling for NVIDIA proprietary drivers,
  `WINE_DISABLE_HARDWARE_SCHEDULING` override (Valve-custom, not upstream)
- **Khronos vendor-ID filter in the GPU-list builder:**
  `if (devinfo[i].properties2.properties.vendorID >= 0x10000) continue;`
  — excludes software rasterizers (llvmpipe/lavapipe report 0x10005) from the
  wine-side GPU list (this is the "Ignore software Vulkan devices" fix)
- Upstream churn only (not custom): external_fence vs external_memory
  extension, dpi return type.

**`dlls/win32u/sysparams.c`** (46 KB, 69 hunks — up to line 6163):
- `fixup_device_id()` — `WINE_HIDE_NVIDIA_GPU` / `WINE_HIDE_AMD_GPU` /
  `WINE_HIDE_VANGOGH_GPU` / `WINE_HIDE_INTEL_GPU` env-var spoofing (Valve-custom)
- steamcompmgr modeset disable, display-mode list changes, dpi plumbing
- **ZERO** LUID / OpenAdapter / hAdapter / QueryStatistics changes (grep=0)

**Verdict:** Proton does NOT change `NtGdiDdDDIOpenAdapterFromLuid/DeviceName`,
LUID generation, handle format, or adapter enumeration. LUIDs come from the
same `NtAllocateLocallyUniqueId` path as wine-tkg. The only D3DKMT-relevant
Valve deltas: WDDM version pin (1.3), WDDM_2_7_CAPS/HwSch, and the
software-vendor filter. **The "Proton adapter-handle difference" hypothesis is
therefore REFUTED at the source level** — no win32u handle-shape change can
make the game tag records.

### 8.2 Record-array writer proof (why §6's conclusion is airtight)

Watchpoint captures (already on disk, no new runs needed):

- **`re2_watch6.txt` (0.6s, pre-copy):** `0x1491b0300+` all zeros.
- **`re2_watch4.txt` (crash):** rec0/rec1 filled only by the 0xE0-byte copy
  (values `0x1482e78d0`, `0x1479ef200`, … = template-derived in-image ptrs).
- The copy at `0x141f54270` spans `0x1491b02a0–0x1491b0388` = rec0 (0x50)
  fully + rec1's first 0x30 bytes. **rec2+ (`0x1491b03a0+`) are BSS zeros
  and no instruction in the PE writes them** — the fill loop (bound
  `template[0xC]` = `0x13677` = 79,479 iterations) reads them all → tag 0 →
  `table[1]` stays NULL → crash at `0x141f543d6`. No writer exists to find.

### 8.3 The "GPU-index list" is a method-dispatch table

The `0x1458c0b20` list the earlier session called "GPU-index list" is decoded
(instantiator base `0x1458c0ae0`, entries at `[rsi-0x20]` idxA, `[rsi-0x18]`
strA, `[rsi-0x10]` byteA, `[rsi-8]` idxB, `[rsi]` strB, `[rsi+8]` byteB;
stride 0x30, 7 entries). The string targets are **.NET-style method names**:

```
Equals  GetHashCode  Finalize  GetType  ToString  CompareTo  Compare
DefaultExceptionHandler  GetEnumerator  MoveNext  get_Current  IndexOf
```

Entry 0: `idxA=1` `strA="Equals"` — the crash reads `table[1]` for it. This is
a **vtable/interface-dispatch descriptor table** (IEnumerator:
get_Current+MoveNext; IComparable: CompareTo; IComparer: Compare), not GPU
indices. The records are method/type descriptors whose field8 tags select the
dispatch slot. On Windows the game populates records 2+ from a reflection path
that never executes under this runner (consistent with §6.4: tag source
absent, no win32u parameter can supply it).

### 8.4 Userpatch deliverable — `d3dkmt_proton_parity.mypatch`

Located at `wine-tkg-userpatches/d3dkmt_proton_parity.mypatch` (this repo).
Verified with `patch --dry-run` + real apply against pinned `a011ce5724`
`dlls/win32u/d3dkmt.c` (all 3 hunks clean):

1. `WIN32_NO_STATUS` + `d3dkmdt.h` include
2. `KMT_DRIVERVERSION_WDDM_1_3` (Proton parity — RE Engine WDDM gate)
3. `KMTQAITYPE_WDDM_2_7_CAPS` + NVIDIA HwSch + `WINE_DISABLE_HARDWARE_SCHEDULING`
4. Khronos vendor-ID filter in the GPU-list builder (excludes llvmpipe/lavapipe)

Caveats: this is **Proton-parity**, i.e. the full set of Valve's win32u D3DKMT
deltas. It does NOT and cannot populate `table[1]` (watchpoint-proven: no
win32u data reaches field8) — so the §1 crash site is **expected to stay
`0x141f543d6`**. It is the correct deliverable for "provide the WDDM adapter
identity RE Engine expects": it removes the software GPU from wine's
enumeration and pins the WDDM version to what RE Engine's DX12 path was built
against, matching Proton exactly. Test in b18 via SteamFlow; if the crash
moves (it may, if the game now picks a different init branch), the new site
feeds the next round.

### 8.6 b18 empirical result (2026-08-05) — parity patch LIVE, crash UNCHANGED

Runner `steamflow-runner-wine11-wow64` rebuilt (BUILD_DATE 2026-08-05T09:52:09Z,
WINE_COMMIT `a011ce5724`, DXVK v3.0.2, VKD3D-Proton v3.0.1, DXVK-NVAPI v0.9.2).
Verified in the installed binary:

- `strings win32u.so` → `WINE_DISABLE_HARDWARE_SCHEDULING` (parity patch §8.4
  item 3 landed) AND `(%p): type %u, adapter luid %08x:%08x` (b17
  query-stats TRACE landed). Both mypatches are in the shipped win32u.so.

Launch via SteamFlow (log `logs/wine_883710.log`, 08:17):

```
04fc:warn:module:find_builtin_dll cannot find builtin library for L"\\??\\Z:\\home\\wer\\.steam\\steam\\steamapps\\common\\Resident Evil 2\\amd_ags_x64.dll"
04fc:warn:module:LdrGetProcedureAddress "Steam_ReleaseThreadLocalMemory" (ordinal 0) not found in L"Z:\\...\\re2.exe"
...
wine: Unhandled page fault on read access to 0000000000000008 at address 0000000141F543D6 (thread 04fc), starting debugger...
```

**Crash is byte-identical at `0x141f543d6`** — `table[1]` still NULL, exactly as
§8.4 predicted. The Proton-parity patch changes wine's D3DKMT surface
(WDDM 1.3 pin, WDDM_2_7_CAPS/HwSch, llvmpipe exclusion) but the game's
record-tagging still never happens: field8 tags come from game-internal static
templating, not from any win32u D3DKMT parameter (watchpoint-proven, §1–§6).

**Conclusion of the Proton-parity experiment:** the "Proton adapter-handle
difference" hypothesis is now REFUTED empirically, not just at the source
level (§8.1). No win32u userpatch can populate `table[1]`. The remaining levers
are §7.1's game-side tagging path (a path that under this runner never
executes) — outside win32u's reach.

### 8.5 Reusable tooling added this session

- `re2iat_dump.py` — correct IAT name resolution (bit-63 ordinal vs
  IMAGE_IMPORT_BY_NAME). Result: **no static NtGdiDdDDI\* imports**; game
  resolves D3DKMT at runtime via slots at `0x1491C8xxx` (not the IAT).
- `re2_gpu_list_dump.py` / `re2_list_head.py` — GPU-index/method-list decode.
- `re2_tpl_dump.py` — TDB template field decode (count `0x13677` @ +0xC).
- `re2recscan.py` — **DO NOT RERUN on this machine**: capstone `detail=True`
  over the full `.text` OOMs the 16 GB box. Use byte-pattern grep + objdump
  instead (see §5 methodology).
