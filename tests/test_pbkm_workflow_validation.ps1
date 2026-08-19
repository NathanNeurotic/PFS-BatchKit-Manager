# test_pbkm_workflow_validation.ps1
# Phase 8: PBKM Workflow & Partition-Size Logic Validation Harness
# Validates that:
# 1. Batch script partition size prompts and mkpart call sites correctly pass 8M, 16M, 32M, 64M, 128M, etc.
# 2. No outdated "The size must be multiplied by 128" guidance remains in user partition creation prompts.
# 3. Fixed-size system partitions (e.g. PSBBN header resources) remain preserved at 128M.
# 4. Batch-generated pfsshell command streams execute and create partitions of sizes 8M..1G on a virtual disk fixture.

param(
    [string]$PbkmRoot = "$PSScriptRoot\..\PFS-BatchKit-Manager",
    [string]$PfsshellPath = "$PSScriptRoot\..\PFS-BatchKit-Manager\BAT\pfsshell.exe",
    [string]$HdlDumpPath = "$PSScriptRoot\..\PFS-BatchKit-Manager\BAT\hdl_dump.exe",
    [string]$WorkingDir = "$PSScriptRoot\fixtures_pbkm_test"
)

$ErrorActionPreference = "Stop"

function Assert-PeArchitectureX86 {
    param([string]$BinaryPath)
    if (-not (Test-Path $BinaryPath)) { throw "Binary not found: '$BinaryPath'" }
    $bytes = [System.IO.File]::ReadAllBytes($BinaryPath)
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne 0x014C) {
        $archStr = switch ($machine) {
            0x8664 { "x64 (64-bit)" }
            default { "0x$($machine.ToString('X4'))" }
        }
        throw "PE Architecture violation on '$BinaryPath': expected x86 32-bit (0x014C), found $archStr (machine 0x$($machine.ToString('X4')))"
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Phase 8: PBKM Workflow & Batch Logic Validation Harness " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "PBKM Root: $PbkmRoot"
Write-Host "pfsshell binary: $PfsshellPath"
Write-Host "hdl_dump binary: $HdlDumpPath"

Assert-PeArchitectureX86 $PfsshellPath
Assert-PeArchitectureX86 $HdlDumpPath
Write-Host "Verified PE Architecture: both binaries are native x86 32-bit (0x014C)." -ForegroundColor Green

# -------------------------------------------------------------
# Part 1: Static Analysis of Batch Scripts
# -------------------------------------------------------------
Write-Host "`n[Part 1] Performing Static Analysis on PBKM Batch Files..." -ForegroundColor Yellow

$mainBatPath = Join-Path $PbkmRoot "!PFS-BatchKit-Manager.bat"
$appsBatPath = Join-Path $PbkmRoot "BAT\APPS.BAT"

if (-not (Test-Path $mainBatPath)) { throw "Main batch script not found: $mainBatPath" }
if (-not (Test-Path $appsBatPath)) { throw "APPS.BAT not found: $appsBatPath" }

$mainBat = Get-Content $mainBatPath -Raw
$appsBat = Get-Content $appsBatPath -Raw

# Check 1: Outdated 128 multiplier text is removed from partition menus
if ($mainBat -match "The size must be multiplied by 128") {
    throw "FAIL: Outdated guidance 'The size must be multiplied by 128' found in !PFS-BatchKit-Manager.bat"
}
if ($appsBat -match "The size must be multiplied by 128") {
    throw "FAIL: Outdated guidance 'The size must be multiplied by 128' found in APPS.BAT"
}
Write-Host "   PASS: No outdated 'The size must be multiplied by 128' text found." -ForegroundColor Green

# Check 2: New small size support is documented in user prompts
if ($mainBat -notmatch "Supported sizes: 8M, 16M, 32M, 64M, 128M") {
    throw "FAIL: Expected 'Supported sizes: 8M, 16M, 32M, 64M, 128M' not found in !PFS-BatchKit-Manager.bat"
}
if ($appsBat -notmatch "Supported sizes: 8M, 16M, 32M, 64M, 128M") {
    throw "FAIL: Expected 'Supported sizes: 8M, 16M, 32M, 64M, 128M' not found in APPS.BAT"
}
Write-Host "   PASS: Small size support (8M..64M) is present in both batch scripts." -ForegroundColor Green

# Check 3: Verify mkpart call sites
# Site A: General partition creation (!PFS-BatchKit-Manager.bat line ~4076) -> echo !PFS_Option! "!PartName!" !partsize! !fstype!
if ($mainBat -notmatch 'echo !PFS_Option! "!PartName!" !partsize! !fstype!') {
    throw "FAIL: General partition creation mkpart pattern not matched in !PFS-BatchKit-Manager.bat"
}
# Site B: Custom app partition creation (!PFS-BatchKit-Manager.bat line ~9182) -> echo mkpart !PPName! !partsize! PFS
if ($mainBat -notmatch 'echo mkpart !PPName! !partsize! PFS') {
    throw "FAIL: Custom app mkpart pattern not matched in !PFS-BatchKit-Manager.bat"
}
# Site C: APPS.BAT partition creation (APPS.BAT line ~805) -> echo mkpart !PartName! !partsize! PFS
if ($appsBat -notmatch 'echo mkpart !PartName! !partsize! PFS') {
    throw "FAIL: APPS.BAT mkpart pattern not matched in APPS.BAT"
}
Write-Host "   PASS: All mkpart call sites verified passing !partsize! directly to pfsshell." -ForegroundColor Green

# Check 4: Verify fixed-size partitions remain untouched
# PSBBN Resource partition in !PFS-BatchKit-Manager.bat must remain 128M
if ($mainBat -notmatch 'echo mkpart "!PartName!" 128M PFS >> "%~dp0TMP\\pfs-updateheader.txt"') {
    throw "FAIL: Fixed-size 128M PSBBN header resource partition pattern altered in !PFS-BatchKit-Manager.bat"
}
Write-Host "   PASS: Fixed-size 128M PSBBN resource partition creation is preserved untouched." -ForegroundColor Green

# -------------------------------------------------------------
# Part 2: Dynamic Execution of Batch-Generated pfsshell Commands
# -------------------------------------------------------------
Write-Host "`n[Part 2] Simulating PBKM pfsshell Workflows on Virtual Disk Fixture..." -ForegroundColor Yellow

if (Test-Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null

$imgFile = Join-Path $WorkingDir "pbkm_sim.img"
$stream = [System.IO.File]::Create($imgFile)
$stream.SetLength(8L * 1024L * 1024L * 1024L)
$stream.Close()
Write-Host "   Created 8 GiB fixture image: $imgFile"

function Run-Pfsshell {
    param([string[]]$Commands)
    $inputScript = ($Commands -join "`n") + "`nexit`n"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PfsshellPath
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($inputScript)
    $p.StandardInput.Flush()
    $p.StandardInput.Close()

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit(60000)

    return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Run-HdlDump {
    param([string[]]$ArgsList)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HdlDumpPath
    $psi.Arguments = $ArgsList -join " "
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit(60000)

    return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

# Initialize APA
$initRes = Run-Pfsshell @("device $imgFile", "initialize yes")
if ($initRes.ExitCode -ne 0) {
    throw "FAIL: pfsshell initialize failed (exit code $($initRes.ExitCode)): $($initRes.Stdout)"
}
Write-Host "   APA fixture initialized."

# Test each size via exact batch script generation pattern:
# echo device !@pfsshell_path!
# echo mkpart "!PartName!" !partsize! PFS
# echo exit
$testSizes = @("8M", "16M", "32M", "64M", "128M", "256M", "512M", "1G")

foreach ($sz in $testSizes) {
    $partName = "PP.APP_$sz"
    Write-Host "   Testing PBKM workflow creation for $partName (size $sz)..." -NoNewline
    $res = Run-Pfsshell @(
        "device $imgFile",
        "mkpart `"$partName`" $sz PFS"
    )
    if ($res.Stdout -notmatch "created") {
        Write-Host " FAILED!" -ForegroundColor Red
        throw "Failed to create ${partName}: $($res.Stdout)"
    }
    Write-Host " SUCCESS." -ForegroundColor Green
}

# Verify TOC and Diag with hdl_dump
Write-Host "`n[Part 3] Verifying APA Table with hdl_dump..." -ForegroundColor Yellow
$tocRes = Run-HdlDump @("toc", "`"$imgFile`"")
Write-Host $tocRes.Stdout

$diagRes = Run-HdlDump @("diag", "`"$imgFile`"")
if ($diagRes.ExitCode -ne 0 -or $diagRes.Stdout -match "error|warning|corrupt|invalid") {
    throw "FAIL: hdl_dump diag reported errors: $($diagRes.Stdout)"
}
Write-Host "   PASS: hdl_dump diag reported partition table is 100% CLEAN!" -ForegroundColor Green

# Cleanup
Remove-Item -Path $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  PHASE 8: ALL PBKM WORKFLOW VALIDATIONS PASSED!          " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
