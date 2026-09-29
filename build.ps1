#Requires -Version 5.1
<#
  RustDesk QuickHost - x64 static build script (Windows)

  Produces a single portable RustDeskQS-x64.exe with:
    * static CRT (/MT)            -> no VC++ Redistributable required
    * static third-party libs     -> libyuv / libvpx / libsodium / zstd via vcpkg
    * only OS DLL imports         -> runs in a plain WinPE x64 image

  Usage:
    powershell -ExecutionPolicy Bypass -File .\build.ps1
    powershell -ExecutionPolicy Bypass -File .\build.ps1 -Configuration Debug
    powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipDeps        (deps already built)
    powershell -ExecutionPolicy Bypass -File .\build.ps1 -DryRun          (print commands only)

  Requirements: Visual Studio 2019/2022/2026 with the "Desktop development with C++"
  workload (MSVC toolset + Windows SDK) and git.exe on PATH.
#>
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('x64')]
    [string]$Platform = 'x64',

    [string]$Triplet = 'x64-windows-static',

    [string]$OutputDir = '',

    [switch]$SkipDeps,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$srcDir = Join-Path $repoRoot 'src'
$vcpkgRoot = Join-Path $repoRoot 'third_party\vcpkg'

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $buildDir = Join-Path $repoRoot ('build\{0}-{1}' -f $Configuration.ToLowerInvariant(), $Platform)
} elseif ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $buildDir = [System.IO.Path]::GetFullPath($OutputDir)
} else {
    $buildDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir))
}
$exeName = 'RustDeskQS-x64.exe'
$exePath = Join-Path $buildDir $exeName

if (-not (Test-Path $buildDir)) { New-Item -ItemType Directory -Path $buildDir -Force | Out-Null }

$work = Join-Path $buildDir '_cmd'
if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }

function Write-Step([string]$Message) { Write-Host "[build] $Message" -ForegroundColor Cyan }

$script:cmdIndex = 0

# ---------------------------------------------------------------------------
# Visual Studio discovery
# ---------------------------------------------------------------------------
Write-Step 'Locating Visual Studio'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null | Select-Object -First 1
    if (-not $vsPath) {
        $vsPath = & $vswhere -latest -products * -property installationPath 2>$null | Select-Object -First 1
    }
}
if (-not $vsPath) { throw 'Visual Studio with the C++ toolset was not found (vswhere).' }

$vcvarsall = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path $vcvarsall)) { throw "vcvarsall.bat not found: $vcvarsall" }
Write-Step "Toolchain: $vsPath"

$clProbe = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
if ($clProbe) { Write-Step "MSVC toolset: $($clProbe.Name)" }

$sdkProbe = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include' -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
if ($sdkProbe) {
    Write-Step "Windows SDK headers: $($sdkProbe.Name)"
} else {
    throw ('Windows 10/11 SDK not found. In the VS Installer add the "Desktop development ' +
           'with C++" workload (or the Windows SDK component) and re-run this script.')
}

# Runs a command line inside the vcvars environment. The command is written to a
# temporary .cmd file so that quoting stays predictable over SSH/CI.
function Invoke-VcCmd {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Description
    )
    Write-Step $Description
    Write-Host "       $CommandLine"
    if ($DryRun) { return }

    $script:cmdIndex++
    $cmdFile = Join-Path $work ('cmd{0:D3}.cmd' -f $script:cmdIndex)
    $content = "@echo off`r`ncall `"$vcvarsall`" $Platform >nul`r`nif errorlevel 1 exit /b 9009`r`n$CommandLine`r`n"
    [System.IO.File]::WriteAllText($cmdFile, $content, [System.Text.Encoding]::ASCII)

    # Run cmd.exe with a native invocation: it returns only when cmd.exe itself exits (it does
    # NOT wait for descendants such as the vctip.exe telemetry helper that cl.exe leaves behind,
    # which can hang for ~15 minutes when the telemetry endpoints are unreachable), and
    # $LASTEXITCODE is reliable here — Start-Process -PassThru reports an empty ExitCode on PS 5.1.
    & $env:ComSpec /d /c "`"$cmdFile`""
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "Command failed with exit code ${code}: $CommandLine"
    }
}

# ---------------------------------------------------------------------------
# vcpkg: bootstrap + dependencies
# ---------------------------------------------------------------------------
if (-not $SkipDeps) {
    $vcpkgExe = Join-Path $vcpkgRoot 'vcpkg.exe'
    $vcpkgShim = Join-Path $vcpkgRoot 'vcpkg.exe'   # shim is created by bootstrap

    if (-not (Test-Path (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat'))) {
        Write-Step 'Cloning vcpkg (shallow) into third_party\vcpkg'
        if ($DryRun) {
            Write-Host "       git clone --depth 1 https://github.com/microsoft/vcpkg.git `"$vcpkgRoot`""
        } else {
            $git = Get-Command git.exe -ErrorAction SilentlyContinue
            if (-not $git) { throw 'git.exe not found. Install Git for Windows (winget install Git.Git).' }
            if (Test-Path $vcpkgRoot) { Remove-Item $vcpkgRoot -Recurse -Force }
            New-Item -ItemType Directory -Path (Split-Path -Parent $vcpkgRoot) -Force | Out-Null
            & $git.Source clone --depth 1 https://github.com/microsoft/vcpkg.git $vcpkgRoot
            if ($LASTEXITCODE -ne 0) { throw 'git clone of vcpkg failed.' }
        }
    }

    if (-not (Test-Path $vcpkgShim)) {
        Write-Step 'Bootstrapping vcpkg'
        Invoke-VcCmd -Description 'bootstrap-vcpkg' `
            -CommandLine "call `"$vcpkgRoot\bootstrap-vcpkg.bat`" -disableMetrics"
        if (-not $DryRun -and -not (Test-Path $vcpkgShim)) { throw 'vcpkg bootstrap did not produce vcpkg.exe.' }
    }

    $includeDir = Join-Path $vcpkgRoot "installed\$Triplet\include"
    $libDir = Join-Path $vcpkgRoot "installed\$Triplet\lib"
    $requiredHeaders = @('libyuv\convert.h', 'vpx\vpx_encoder.h', 'sodium.h', 'zstd.h')
    $missing = $requiredHeaders | Where-Object { -not (Test-Path (Join-Path $includeDir $_)) }

    if ($missing) {
        Write-Step "Installing vcpkg dependencies ($Triplet): libyuv libvpx libsodium zstd"
        Write-Host '       first run also builds libvpx/libyuv/libsodium/zstd from source (10-40 min)'
        Invoke-VcCmd -Description 'vcpkg install' `
            -CommandLine ("`"$vcpkgShim`" install --triplet {0} --clean-after-build libyuv libvpx libsodium zstd" -f $Triplet)

        $stillMissing = $requiredHeaders | Where-Object { -not (Test-Path (Join-Path $includeDir $_)) }
        if ($stillMissing) { throw ("vcpkg did not provide: " + ($stillMissing -join ', ')) }
    } else {
        Write-Step 'vcpkg dependencies already present'
    }
} else {
    $includeDir = Join-Path $vcpkgRoot "installed\$Triplet\include"
    $libDir = Join-Path $vcpkgRoot "installed\$Triplet\lib"
}

# ---------------------------------------------------------------------------
# Locate the static libraries (names vary between ports/versions)
# ---------------------------------------------------------------------------
function Find-Lib {
    param([string]$Description, [string[]]$Candidates)
    foreach ($cand in $Candidates) {
        $p = Join-Path $libDir $cand
        if (Test-Path $p) { return $p }
    }
    throw ("Static library for {0} not found in {1}. Tried: {2}" -f $Description, $libDir, ($Candidates -join ', '))
}

$thirdPartyLibs = @(
    (Find-Lib 'libyuv' @('yuv.lib', 'libyuv.lib')),
    (Find-Lib 'libvpx' @('vpx.lib', 'vpx_static.lib', 'libvpx.lib', 'vpx_mt.lib', 'vpx_md.lib')),
    (Find-Lib 'libsodium' @('libsodium.lib', 'sodium.lib', 'libsodium_a.lib')),
    (Find-Lib 'zstd' @('zstd.lib', 'zstd_static.lib', 'libzstd.lib'))
)
Write-Step 'Third-party static libraries:'
$thirdPartyLibs | ForEach-Object { Write-Host "       $_" }

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------
$compileFlags = @(
    '/nologo', '/utf-8', '/std:c++17', '/EHsc', '/W3',
    '/DWIN32', '/D_WINDOWS', '/DUNICODE', '/D_UNICODE'
)
if ($Configuration -eq 'Debug') {
    $compileFlags += '/Od', '/Zi', '/MTd', '/D_DEBUG'
} else {
    $compileFlags += '/O2', '/MT', '/DNDEBUG'
}
$compileFlags += '/I"{0}"' -f $srcDir
$compileFlags += '/I"{0}"' -f $includeDir

$sourceFiles = @('main.cpp', 'portable_host.cpp', 'xp_fls_compat.cpp')
$objectFiles = @()

foreach ($src in $sourceFiles) {
    $srcPath = Join-Path $srcDir $src
    if (-not (Test-Path $srcPath)) { throw "Source not found: $srcPath" }
    $objPath = Join-Path $buildDir ($src -replace '\.cpp$', '.obj')
    $objectFiles += $objPath
    Invoke-VcCmd -Description "Compiling $src" `
        -CommandLine ('cl /c /Fo"{0}" {1} "{2}"' -f $objPath, ($compileFlags -join ' '), $srcPath)
}

$resourceFile = Join-Path $srcDir 'portable_host.rc'
$resPath = $null
if (Test-Path $resourceFile) {
    $resPath = Join-Path $buildDir 'portable_host.res'
    Invoke-VcCmd -Description 'Compiling resources' `
        -CommandLine ('rc /nologo /fo"{0}" /I"{1}" "{2}"' -f $resPath, $srcDir, $resourceFile)
}

if ($DryRun) { Write-Host '[build] dry run finished'; exit 0 }

# ---------------------------------------------------------------------------
# Link
# ---------------------------------------------------------------------------
$sdkLibs = @(
    'advapi32.lib', 'comctl32.lib', 'comdlg32.lib', 'crypt32.lib', 'gdi32.lib',
    'gdiplus.lib', 'iphlpapi.lib', 'mfuuid.lib', 'ole32.lib', 'oleaut32.lib',
    'shell32.lib', 'user32.lib', 'ws2_32.lib'
)

$linkFlags = @(
    '/nologo',
    '/SUBSYSTEM:WINDOWS,6.00',
    '/MACHINE:X64',
    '/OPT:REF', '/OPT:ICF',
    '/OUT:"{0}"' -f $exePath
)
if ($Configuration -eq 'Release') {
    $linkFlags += '/INCREMENTAL:NO'
}

$linkInputs = @($objectFiles)
if ($resPath) { $linkInputs += $resPath }
$linkInputs += $thirdPartyLibs
$linkInputs += $sdkLibs

Invoke-VcCmd -Description 'Linking RustDeskQS-x64.exe' `
    -CommandLine ('link {0} {1}' -f ($linkFlags -join ' '), ($linkInputs -join ' '))

if (-not (Test-Path $exePath)) { throw "Link reported success but $exePath is missing." }

# ---------------------------------------------------------------------------
# Verify the produced binary (machine type + import table)
# ---------------------------------------------------------------------------
function Get-PeSummary {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw "Not an MZ file: $Path" }

    function U16([int]$o) { return [BitConverter]::ToUInt16($bytes, $o) }
    function U32([int]$o) { return [BitConverter]::ToUInt32($bytes, $o) }

    $e = [int](U32 0x3C)
    if ([Text.Encoding]::ASCII.GetString($bytes, $e, 4) -ne "PE`0`0") { throw 'PE signature not found' }
    $coff = $e + 4
    $machine = U16 $coff
    $nsec = U16 ($coff + 2)
    $optSize = U16 ($coff + 16)
    $opt = $coff + 20
    $magic = U16 $opt
    $subsystem = U16 ($opt + 68)
    $subsysMajor = U16 ($opt + 48)   # MajorSubsystemVersion
    $subsysMinor = U16 ($opt + 50)   # MinorSubsystemVersion
    if ($magic -eq 0x20B) {          # PE32+
        $numRva = U32 ($opt + 108)
        $ddOff = $opt + 112
    } else {                          # PE32
        $numRva = U32 ($opt + 92)
        $ddOff = $opt + 96
    }
    $importRva = if ($numRva -gt 1) { U32 ($ddOff + 8) } else { 0 }

    $sections = @()
    $secOff = $opt + $optSize
    for ($i = 0; $i -lt $nsec; $i++) {
        $o = $secOff + (40 * $i)
        $nameBytes = New-Object byte[] 8
        [Array]::Copy($bytes, $o, $nameBytes, 0, 8)
        $sections += [pscustomobject]@{
            Name  = [Text.Encoding]::ASCII.GetString($nameBytes).TrimEnd([char]0)
            VA    = U32 ($o + 12)
            VSize = U32 ($o + 8)
            Raw   = U32 ($o + 20)
            RSize = U32 ($o + 16)
        }
    }

    $rvaToOffset = {
        param([uint32]$rva)
        foreach ($s in $sections) {
            $span = [Math]::Max($s.VSize, $s.RSize)
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $span)) { return [int]($s.Raw + ($rva - $s.VA)) }
        }
        return -1
    }

    function Read-CString([int]$off) {
        if ($off -lt 0 -or $off -ge $bytes.Length) { return $null }
        $end = $off
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        return [Text.Encoding]::ASCII.GetString($bytes, $off, $end - $off)
    }

    $dlls = @()
    if ($importRva -ne 0) {
        $off = & $rvaToOffset $importRva
        if ($off -ge 0) {
            while ($true) {
                $oft = U32 $off
                $nameRva = U32 ($off + 12)
                $firstThunk = U32 ($off + 16)
                if ($oft -eq 0 -and $nameRva -eq 0 -and $firstThunk -eq 0) { break }
                $dllOff = & $rvaToOffset $nameRva
                if ($dllOff -ge 0) { $dlls += Read-CString $dllOff }
                $off += 20
            }
        }
    }

    $crtPattern = 'vcruntime|msvcp|ucrtbase|concrt|vccorlib|msvcr|api-ms-win-crt'
    $crt = @($dlls | Where-Object { $_ -match $crtPattern })

    return [pscustomobject]@{
        Path            = $Path
        SizeBytes       = $bytes.Length
        Machine         = $(if ($machine -eq 0x8664) { 'AMD64 (x64)' } elseif ($machine -eq 0x14C) { 'x86 (32-bit)' } else { '0x{0:X4}' -f $machine })
        PeFormat        = $(if ($magic -eq 0x20B) { 'PE32+' } else { 'PE32' })
        Subsystem       = $(if ($subsystem -eq 2) { 'Windows GUI' } else { "id=$subsystem" })
        SubsystemVer    = '{0}.{1}' -f $subsysMajor, $subsysMinor
        ImportDlls      = $dlls
        CrtImports      = $crt
    }
}

Write-Step 'Verifying output binary'
$summary = Get-PeSummary -Path $exePath
Write-Host "       file      : $($summary.Path)"
Write-Host "       size      : $([math]::Round($summary.SizeBytes/1KB,1)) KB"
Write-Host "       machine   : $($summary.Machine)"
Write-Host "       format    : $($summary.PeFormat)"
Write-Host "       subsystem : $($summary.Subsystem) $($summary.SubsystemVer)"
Write-Host "       imports   : $($summary.ImportDlls -join ', ')"
if ($summary.CrtImports.Count -gt 0) {
    Write-Host "       CRT DLLs  : $($summary.CrtImports -join ', ')" -ForegroundColor Red
    throw 'Static build failed: dynamic CRT/API-set imports detected.'
} else {
    Write-Host '       CRT       : static (no vcruntime/msvcp/ucrt import)' -ForegroundColor Green
}

Write-Step "Build completed: $exePath"
