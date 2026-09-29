# Building RustDesk QuickHost (x64 static / WinPE)

This repository adds a reproducible Windows build that produces `RustDeskQS-x64.exe`:
a single, portable, **statically linked x64 host** that runs in a plain WinPE x64 image
without any redistributable.

| Item | Path |
|---|---|
| Build entry point | [`build.ps1`](../build.ps1) |
| Output | `build/<configuration>-x64/RustDeskQS-x64.exe` |
| Verification helper | [`tools/pe_deps.py`](../tools/pe_deps.py) |
| Local change log | [`CHANGES.md`](CHANGES.md) |

---

## 1. System requirements (build machine)

| Item | Requirement | Version verified in this build |
|---|---|---|
| OS | Windows 10/11 **x64** | Windows 11 (10.0.26200.9550) x64 |
| Visual Studio | 2019 / 2022 / 2026 with the **Desktop development with C++** workload | Visual Studio Community 18.10.1 (2026) |
| MSVC toolset | `cl.exe`, `link.exe`, `lib.exe` (Host x64) | 14.51.36231 |
| Windows SDK | 10.0.19041 or newer (headers + `um` / `ucrt` libraries) | 10.0.26100.0 |
| Git | on `PATH` (used to clone vcpkg) | Git for Windows 2.55.0.5 |
| Python 3 | optional, only needed for `tools/pe_deps.py` | 3.x |
| Disk | ~500 MB for the vcpkg tree, ~10 MB for build output | 434 MB + 8 MB measured |
| Network | required on first run: vcpkg clone, port sources, msys2 / nasm / perl | GitHub, msys2.org, nasm.us |

`rc.exe` ships with the Windows SDK; `vswhere.exe` ships with the Visual Studio Installer.
No Python, cmake, nasm, perl or 7z need to be installed manually — vcpkg downloads its own
tools when a port needs them.

### If the C++ workload or Windows SDK is missing

`build.ps1` fails fast with a clear error. Add the workload with an elevated command prompt:

```bat
"C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify ^
  --installPath "C:\Program Files\Microsoft Visual Studio\18\Community" ^
  --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --quiet --norestart
```

> The `--installPath` value must be quoted — it contains spaces. When running unattended over
> SSH, launch the command from Task Scheduler (`schtasks`); processes started by an SSH session
> are killed when the session closes.

---

## 2. Build

```powershell
# from the repository root
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Configuration Release
```

Options:

| Option | Effect |
|---|---|
| `-Configuration Debug` | `/Od /Zi /MTd /D_DEBUG` instead of `/O2 /MT /DNDEBUG` |
| `-SkipDeps` | skip the vcpkg bootstrap/install step (dependencies already present) |
| `-DryRun` | print every compile/link command without executing it |
| `-OutputDir <path>` | override the output directory |
| `-Triplet <name>` | default `x64-windows-static` |

First run additionally:

1. clones `microsoft/vcpkg` (shallow) into `third_party\vcpkg`,
2. runs `bootstrap-vcpkg.bat`,
3. installs `libyuv libvpx libsodium zstd` for `x64-windows-static`
   (builds libvpx/libyuv/libsodium/zstd from source, about 10 minutes on the verified machine).

Later runs skip straight to compile + link (about 1 minute).

---

## 3. What `build.ps1` does

1. Locates Visual Studio through `vswhere`, requires the MSVC toolset, checks for the Windows SDK.
2. Prepares vcpkg (`clone` → `bootstrap` → `install` for the `x64-windows-static` triplet).
3. Resolves the four static libraries (`yuv.lib`, `vpx.lib`, `libsodium.lib`, `zstd.lib`).
4. Writes each tool invocation into `build\...\_cmd\cmdNNN.cmd` prefixed with
   `vcvarsall.bat x64`, so quoting stays predictable.
5. Compiles `src/main.cpp`, `src/portable_host.cpp`, `src/xp_fls_compat.cpp`
   with `/nologo /utf-8 /std:c++17 /EHsc /W3 /DWIN32 /D_WINDOWS /DUNICODE /D_UNICODE /O2 /MT /DNDEBUG`.
6. Compiles `src/portable_host.rc` with `rc`.
7. Links with
   `/SUBSYSTEM:WINDOWS,6.00 /MACHINE:X64 /OPT:REF /OPT:ICF /INCREMENTAL:NO`
   plus the SDK import libraries `advapi32 comctl32 comdlg32 crypt32 gdi32 gdiplus iphlpapi
   mfuuid ole32 oleaut32 shell32 user32 ws2_32`.
8. Re-parses the produced PE file and **fails the build** if any dynamic CRT API-set is imported.

---

## 4. Output

```text
build\release-x64\
├── RustDeskQS-x64.exe   ← deliverable (~2.4 MB)
├── main.obj  portable_host.obj  xp_fls_compat.obj  portable_host.res
├── _cmd\                ← generated cmd files (one per tool invocation)
├── rustdesk_cpp_host.ini  en.txt  tw.txt   ← created on first run of the exe
```

Intermediate files are ignored by `.gitignore`; the `.exe` is also ignored (ship it as a
release asset, not in git).

---

## 5. Verification

Built-in (always runs at the end of `build.ps1`):

```text
[build] Verifying output binary
       machine   : AMD64 (x64)
       format    : PE32+
       subsystem : Windows GUI 6.0
       imports   : ADVAPI32.dll, COMCTL32.dll, COMDLG32.dll, CRYPT32.dll, GDI32.dll,
                   gdiplus.dll, IPHLPAPI.DLL, ole32.dll, OLEAUT32.dll, SHELL32.dll,
                   USER32.dll, WS2_32.dll, KERNEL32.dll
       CRT       : static (no vcruntime/msvcp/ucrt import)
```

Standalone check with Python 3:

```bash
python3 tools/pe_deps.py build/release-x64/RustDeskQS-x64.exe --check-crt
python3 tools/pe_deps.py build/release-x64/RustDeskQS-x64.exe --symbols   # per-DLL imports
python3 tools/pe_deps.py app.exe --list-file winpe_modules.txt            # compare with a WinPE image
```

`--list-file` accepts any module list (one DLL name per line, e.g. extracted from a
`boot.wim`) and reports imports that the image does not contain.

### Measured result of this build

| Property | Value |
|---|---|
| File | `RustDeskQS-x64.exe`, 2393.5 KB |
| Machine / format | AMD64 (x64) / PE32+ |
| Subsystem | Windows GUI, version 6.00 |
| CRT | static (`/MT`) — no `vcruntime`, `msvcp`, `ucrtbase`, `api-ms-win-crt-*` |
| Imported DLLs | 13, all OS system DLLs — identical to the official x86 release |
| Runs on | Windows 11 build VM (smoke test) and WinPE x64 (remote session verified) |

---

## 6. Runtime notes (WinPE)

* The binary imports only OS DLLs, so a stock WinPE x64 image is enough — no
  Visual C++ Redistributable, no UCRT package, no SxS assembly.
* `mfplat.dll` (Media Foundation) is loaded **dynamically** at runtime by
  `src/portable_host.cpp`; when it is missing the encoder falls back to VP8, which is why
  the host still streams in WinPE.
* H.264 uses the system `CLSID_CMSH264EncoderMFT` GUID declared in-source
  (`kClsidCmsH264EncoderMFT`), so no `mfplat` import is emitted at link time.
* This binary is **64-bit only**: it will not run in a 32-bit (x86) WinPE image, which has
  no WoW64.
* Performance: vcpkg builds libyuv without SIMD acceleration under MSVC, and VP8 encoding in
  WinPE is software-only, so capture/compression is slower than on a full Windows install.
  See `CHANGES.md` for the possible optimizations.

---

## 7. Out of scope: 32-bit / Windows XP

`third_party/vcpkg_overlays/` contains ports and triplets that pin the XP-compatible
toolset (`x86-windows-static-v141xp.cmake`, libvpx static-suffix patches). Those are used
for the 32-bit / XP flavour of the official release, which is built with linker 14.16
(`/SUBSYSTEM:WINDOWS,5.1`, no WoW64 dependency issues, `DYNAMICBASE` + `NX` still set).
`build.ps1` intentionally targets only `x64` and does not use the overlays — a 64-bit
binary cannot run on Windows XP anyway.

---

## 8. Dependency versions (vcpkg, `x64-windows-static`)

| Port | Version |
|---|---|
| libvpx | 1.16.0#3 |
| libyuv | 1916 |
| libsodium | 1.0.22#1 |
| zstd | 1.5.7 |
| libjpeg-turbo | 3.2.0#1 (libyuv dependency) |
| libspng | 0.7.4 (libyuv dependency) |
| zlib | 1.3.2#2 (libyuv dependency) |

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Each compile step takes exactly ~15 minutes while the CPU stays idle, `vctip.exe` lingers | `cl.exe` spawns `vctip.exe` (VC telemetry helper) which hangs when `vortex.data.microsoft.com` is unreachable. `Start-Process -Wait` waits for the whole process tree, so the build waits for it too. | `build.ps1` runs `cmd.exe` via a native invocation (`& $env:ComSpec ...` + `$LASTEXITCODE`), which waits for `cmd.exe` only. Do **not** switch back to `Start-Process -Wait`. |
| Exit code reported as empty: `Command failed with exit code : cl ...` | On PowerShell 5.1 the `ExitCode` of a process object from `Start-Process -PassThru` is empty even after `WaitForExit()`. | Use `$LASTEXITCODE` from a native invocation (already done). |
| Build stops right after a step when driven over SSH | The Windows OpenSSH service breaks the stdout pipe of child processes when the session closes, so PowerShell fails/blocks on the next `Write-Host`. | Redirect the script output to a file instead of the SSH pipe: `powershell -File build.ps1 > build.log 2>&1`, or run it through Task Scheduler (`schtasks`) as `run_build.cmd` does. |
| `vswhere` finds Visual Studio but `cl` / the Windows SDK is missing | The C++ workload or the Windows SDK component is not installed. | See §1 — add `Microsoft.VisualStudio.Workload.NativeDesktop`. |
| `vcpkg` warns about a mismatched `VCPKG_ROOT` | Visual Studio sets `VCPKG_ROOT` to its own bundled copy. | Harmless; `build.ps1` uses `third_party\vcpkg`. |
