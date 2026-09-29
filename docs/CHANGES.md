# Local changes vs upstream

* Upstream: <https://github.com/Terence0816/RustDesk-QuickHost>
* Local snapshot: state after tag `v1.1.2.4` (`src/portable_host.rc` reports
  `1.1.2.3`, About dialog reports `1.1.2.4`; upstream `main` has moved on to `1.1.2.5`).
* The x64 static build described in [`BUILD.md`](BUILD.md) was made **in this repository copy only**.

---

## 1. Source code changes: none

No file under `src/` was modified **by this work**. All `src/` files still carry the
original `2026-07-08` timestamp; this session only created `build.ps1`, `tools/` and the
new `docs/` files.

Compared with upstream `Terence0816/RustDesk-QuickHost` tags:

| Path | Status |
|---|---|
| `src/portable_host.h`, `main.cpp`, `xp_fls_compat.cpp`, `app_resources.h` | identical to upstream `main` |
| `src/portable_host.cpp`, `src/portable_host.rc` | **pre-existing snapshot difference**, not an edit made here: the local copy is ahead of tag `v1.1.2.4` (About = `1.1.2.4`, Excel XML clipboard work) and behind `main` (which is `1.1.2.5`) |
| `resources/` | identical to upstream |
| `third_party/libsodium/`, `third_party/zstd_prebuilt/`, `third_party/vcpkg_overlays/` | identical to upstream |
| `docs/compatibility-notes.md`, `LICENSE`, `.gitignore` (base) | identical to upstream |

No source edit was needed for the x64 static build:

* window long access already uses `GetWindowLongPtrW` / `SetWindowLongPtrW` (64-bit safe),
* no inline `__asm` blocks,
* the H.264 encoder MFT CLSID is declared in source (`kClsidCmsH264EncoderMFT`), so no
  `mfplat` import is emitted,
* `xp_fls_compat.cpp` disables itself on non-x86 targets.

---

## 2. Files added

| Path | Purpose |
|---|---|
| `build.ps1` | Windows x64 `/MT` build entry point (vcpkg + cl + rc + link + PE self-check) |
| `tools/pe_deps.py` | PE inspection: machine type, subsystem, imports, `--check-crt`, `--list-file` for WinPE images |
| `docs/BUILD.md` | build method, system requirements, output, verification |
| `docs/CHANGES.md` | this file |

`build.ps1` implementation notes (details in [`BUILD.md`](BUILD.md) §9): it calls `cmd.exe`
with a native invocation instead of `Start-Process -Wait`, because the latter waits for the
whole process tree and `cl.exe` leaves a `vctip.exe` (telemetry helper) behind that hangs
for ~15 minutes when Microsoft telemetry endpoints are unreachable; the exit code comes from
`$LASTEXITCODE` because `Start-Process -PassThru` reports an empty `ExitCode` on PowerShell 5.1.

---

## 3. Existing files moved / edited

| Path | Change | Reason |
|---|---|---|
| `RELEASE_NOTES_v1.0.0.0.md` → `docs/RELEASE_NOTES_v1.0.0.0.md` | moved | keep the repository root for entry points only; no file referenced the old path |
| `README.md` | Repository Layout updated (EN + ZH) and a **Building** section added (EN + ZH) | the upstream sentence "local/private build scripts are intentionally not included" is no longer true for this copy |
| `.gitignore` | added `third_party/vcpkg/`, `__pycache__/`, `*.pyc` | vcpkg is cloned by `build.ps1` and must not be committed |

Nothing else in the upstream tree was edited.

---

## 4. Deliberately not changed

* Version strings: `FILEVERSION` stays `1.1.2.3`, About stays `1.1.2.4` — the binary is a
  rebuild of the same snapshot, not an upstream release.
* `third_party/vcpkg_overlays/` (XP / x86 triplets) — unused by the x64 build.
* Application logic, defaults, INI handling, codecs — untouched.

---

## 5. Generated (not source, ignored by git)

| Path | Notes |
|---|---|
| `build/` | objects, generated `_cmd\*.cmd`, `RustDeskQS-x64.exe`, and the `rustdesk_cpp_host.ini` / `en.txt` / `tw.txt` created on first run |
| `third_party/vcpkg/` | 434 MB vcpkg clone + `installed/x64-windows-static` |

---

## 6. Build provenance

* Built on a Windows 11 x64 VM with Visual Studio Community 18.10.1 (MSVC 14.51.36231),
  Windows SDK 10.0.26100.0, Git 2.55.0.5.
* vcpkg ports: libvpx 1.16.0#3, libyuv 1916, libsodium 1.0.22#1, zstd 1.5.7.
* Result: `RustDeskQS-x64.exe` — AMD64, PE32+, subsystem 6.00, static CRT, 13 OS DLL imports
  (identical set to the official x86 v1.1.2.5 release).
* Verified: smoke test on the Windows 11 VM and a live remote-control session from WinPE x64.

### Possible future optimizations (not applied)

* Rebuild libyuv with SIMD (`/arch:AVX2` or clang-cl) — the vcpkg MSVC build has no
  acceleration paths, colour conversion is the main CPU cost.
* Confirm libvpx runtime CPU detection is enabled in the vcpkg build.
* Compare GDI capture vs `BitBlt`/`PrintWindow` variants if capture, not encoding, is the bottleneck.
