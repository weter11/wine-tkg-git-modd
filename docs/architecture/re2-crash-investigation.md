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
