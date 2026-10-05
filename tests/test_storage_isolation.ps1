# test_storage_isolation.ps1
# Phase 9: Comprehensive Storage-Isolation & Multi-Size Workflow Regression Test Harness
# Validates that:
# 1. Dual-storage layout (12 GiB APA + 4 GiB exFAT) remains completely isolated.
# 2. Sequential creation of 8M, 16M, 32M, 64M, 128M user partitions and 128M fixed PSBBN resource partitions
#    preserves pre-existing APA partitions and preserves exFAT region byte-for-byte.
# 3. After every single operation, APA TOC integrity, hdl_dump diag, and exFAT SHA-256 are verified.
# 4. PFS filesystem read/write roundtrip functions properly on small partitions without touching exFAT.

param(
    [string]$PfsshellPath = "$PSScriptRoot\..\PFS-BatchKit-Manager\BAT\pfsshell.exe",
    [string]$HdlDumpPath = "$PSScriptRoot\..\PFS-BatchKit-Manager\BAT\hdl_dump.exe",
    [string]$WorkingDir = "$PSScriptRoot\fixtures_isolation",
    [int]$TimeoutMs = 180000
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
Write-Host " Phase 9: Storage Isolation & Multi-Size Regression Harness " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "pfsshell binary: $PfsshellPath"
Write-Host "hdl_dump binary: $HdlDumpPath"
Write-Host "Working directory: $WorkingDir"

Assert-PeArchitectureX86 $PfsshellPath
Assert-PeArchitectureX86 $HdlDumpPath
Write-Host "Verified PE Architecture: both binaries are native x86 32-bit (0x014C)." -ForegroundColor Green

if (Test-Path $WorkingDir) {
    Remove-Item -Path $WorkingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null

function Run-Pfsshell {
    param([string[]]$Commands, [int]$Timeout = $TimeoutMs)
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
    $p.WaitForExit($Timeout)

    return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Run-HdlDump {
    param([string[]]$ArgsList, [int]$Timeout = $TimeoutMs)
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
    $p.WaitForExit($Timeout)

    return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Get-RegionHash {
    param([string]$FilePath, [long]$Offset, [long]$Length)
    $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    
    $buffer = New-Object byte[] (4 * 1024 * 1024)
    $bytesRemaining = $Length
    while ($bytesRemaining -gt 0) {
        $toRead = [int][Math]::Min($bytesRemaining, $buffer.Length)
        $read = $fs.Read($buffer, 0, $toRead)
        if ($read -le 0) { break }
        if ($read -eq $bytesRemaining) {
            $sha256.TransformFinalBlock($buffer, 0, $read) | Out-Null
        } else {
            $sha256.TransformBlock($buffer, 0, $read, $null, 0) | Out-Null
        }
        $bytesRemaining -= $read
    }
    $fs.Close()
    return ([System.BitConverter]::ToString($sha256.Hash) -replace "-", "")
}

# -------------------------------------------------------------
# Step 1: Construct 16 GiB Dual-Layout Disk Image Fixture
# -------------------------------------------------------------
Write-Host "`n[Step 1] Constructing 16 GiB Dual-Storage Fixture (12 GiB APA + 4 GiB exFAT)..." -ForegroundColor Yellow
$diskImg = Join-Path $WorkingDir "psbbn_isolation_16g.img"
$totalBytes = 16L * 1024L * 1024L * 1024L
$apaBytes   = 12L * 1024L * 1024L * 1024L
$exfatBytes = 4L * 1024L * 1024L * 1024L
$exfatOffset = $apaBytes

$fs = [System.IO.File]::Create($diskImg)
$fs.SetLength($totalBytes)

# Populate exFAT mock region (12..16 GiB) with high-entropy pattern
Write-Host "   Writing mock exFAT filesystem data to offset $exfatOffset ($exfatBytes bytes)..."
$fs.Seek($exfatOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
$chunk = New-Object byte[] (1024 * 1024)
for ($i = 0; $i -lt $chunk.Length; $i += 16) {
    $chunk[$i + 0] = 0xEB; $chunk[$i + 1] = 0x76; $chunk[$i + 2] = 0x90 # exFAT VBR JMP
    $chunk[$i + 3] = 0x45; $chunk[$i + 4] = 0x58; $chunk[$i + 5] = 0x46; $chunk[$i + 6] = 0x41; $chunk[$i + 7] = 0x54 # "EXFAT   "
    $chunk[$i + 8] = ($i -band 0xFF); $chunk[$i + 9] = (($i -shr 8) -band 0xFF)
    $chunk[$i + 10] = 0xAA; $chunk[$i + 11] = 0x55; $chunk[$i + 12] = 0xDE; $chunk[$i + 13] = 0xAD; $chunk[$i + 14] = 0xBE; $chunk[$i + 15] = 0xEF
}
$mbWritten = 0
while ($mbWritten -lt 4096) {
    $fs.Write($chunk, 0, $chunk.Length)
    $mbWritten++
}
$fs.Flush()
$fs.Close()
Write-Host "   Dual-storage fixture created: $diskImg"

# -------------------------------------------------------------
# Step 2: Initialize APA and Base Partitions
# -------------------------------------------------------------
Write-Host "`n[Step 2] Initializing Base PSBBN-DP APA Structure..." -ForegroundColor Yellow
$initCommands = @(
    "device $diskImg",
    "initialize yes",
    "mkpart __net 128M PFS",
    "mkpart __system 256M PFS",
    "mkpart __sysconf 512M PFS",
    "mkpart __common 1024M PFS",
    "mkpart PP.HDL.Game1 1024M HDL",
    "mkpart __bbn 256M PFS"
)
$initRes = Run-Pfsshell $initCommands
if ($initRes.ExitCode -ne 0) {
    throw "FAIL: Base APA initialization failed: $($initRes.Stdout)"
}
Write-Host "   Base PSBBN-DP partitions created successfully."

# -------------------------------------------------------------
# Step 3: Establish Baseline Inventory
# -------------------------------------------------------------
Write-Host "`n[Step 3] Establishing Immutable Pre-Test Baseline..." -ForegroundColor Yellow

$baseToc = Run-HdlDump @("toc", "`"$diskImg`"")
Write-Host "`n--- Baseline APA TOC ---" -ForegroundColor Cyan
Write-Host $baseToc.Stdout

$baseDiag = Run-HdlDump @("diag", "`"$diskImg`"")
if ($baseDiag.ExitCode -ne 0 -or $baseDiag.Stdout -match "error|warning|corrupt|invalid") {
    throw "FAIL: Baseline diag check failed: $($baseDiag.Stdout)"
}
Write-Host "   Baseline hdl_dump diag: CLEAN (0 errors, 0 warnings)" -ForegroundColor Green

$baselineExfatHash = Get-RegionHash -FilePath $diskImg -Offset $exfatOffset -Length $exfatBytes
Write-Host "   Baseline exFAT Region SHA-256: $baselineExfatHash" -ForegroundColor Green

# Baseline partition map: Name -> Expected size
$expectedBaseParts = @{
    "__mbr" = "128MB"
    "__net" = "128MB"
    "__system" = "256MB"
    "__sysconf" = "512MB"
    "__common" = "1024MB"
    "PP.HDL.Game1" = "1024MB"
    "__bbn" = "256MB"
}

function Assert-PartitionTableIntegrity {
    param([string]$StepName, [hashtable]$ExpectedPartitions)
    
    $toc = Run-HdlDump @("toc", "`"$diskImg`"")
    foreach ($pName in $ExpectedPartitions.Keys) {
        $expSize = $ExpectedPartitions[$pName]
        if ($toc.Stdout -notmatch "$expSize\s+$([regex]::Escape($pName))") {
            throw "FAIL [$StepName]: Expected partition '$pName' ($expSize) missing or corrupted in TOC!`nTOC output:`n$($toc.Stdout)"
        }
    }
    
    $diag = Run-HdlDump @("diag", "`"$diskImg`"")
    if ($diag.ExitCode -ne 0 -or $diag.Stdout -match "error|warning|corrupt|invalid") {
        throw "FAIL [$StepName]: hdl_dump diag reported errors!`nDiag output:`n$($diag.Stdout)"
    }
    
    $currentExfatHash = Get-RegionHash -FilePath $diskImg -Offset $exfatOffset -Length $exfatBytes
    if ($currentExfatHash -ne $baselineExfatHash) {
        throw "FAIL [$StepName]: exFAT region hash MODIFIED! Expected: $baselineExfatHash, Actual: $currentExfatHash"
    }
    
    Write-Host "   [$StepName] TOC valid, pre-existing partitions intact, diag clean, exFAT hash MATCHED." -ForegroundColor Green
}

# -------------------------------------------------------------
# Step 4: Sequential PBKM Workflow Operations & Validation
# -------------------------------------------------------------
Write-Host "`n[Step 4] Executing Sequential PBKM Workflow Operations..." -ForegroundColor Yellow

$currentExpectedParts = $expectedBaseParts.Clone()

# Test 4.1: 8M User Partition (PP.UAPP-00001..APP8)
Write-Host "`n--- Operation 4.1: Create 8M Partition (PP.UAPP-00001..APP8) ---" -ForegroundColor Cyan
$op8Res = Run-Pfsshell @("device $diskImg", "mkpart PP.UAPP-00001..APP8 8M PFS")
if ($op8Res.Stdout -notmatch "created") { throw "FAIL: Failed to create 8M partition: $($op8Res.Stdout)" }
$currentExpectedParts["PP.UAPP-00001..APP8"] = "8MB"
Assert-PartitionTableIntegrity -StepName "4.1: 8M Partition" -ExpectedPartitions $currentExpectedParts

# Test 4.2: 16M User Partition (PP.UAPP-00002..APP16)
Write-Host "`n--- Operation 4.2: Create 16M Partition (PP.UAPP-00002..APP16) ---" -ForegroundColor Cyan
$op16Res = Run-Pfsshell @("device $diskImg", "mkpart PP.UAPP-00002..APP16 16M PFS")
if ($op16Res.Stdout -notmatch "created") { throw "FAIL: Failed to create 16M partition: $($op16Res.Stdout)" }
$currentExpectedParts["PP.UAPP-00002..APP16"] = "16MB"
Assert-PartitionTableIntegrity -StepName "4.2: 16M Partition" -ExpectedPartitions $currentExpectedParts

# Test 4.3: 32M User Partition (PP.UAPP-00003..APP32)
Write-Host "`n--- Operation 4.3: Create 32M Partition (PP.UAPP-00003..APP32) ---" -ForegroundColor Cyan
$op32Res = Run-Pfsshell @("device $diskImg", "mkpart PP.UAPP-00003..APP32 32M PFS")
if ($op32Res.Stdout -notmatch "created") { throw "FAIL: Failed to create 32M partition: $($op32Res.Stdout)" }
$currentExpectedParts["PP.UAPP-00003..APP32"] = "32MB"
Assert-PartitionTableIntegrity -StepName "4.3: 32M Partition" -ExpectedPartitions $currentExpectedParts

# Test 4.4: 64M User Partition (PP.UAPP-00004..APP64)
Write-Host "`n--- Operation 4.4: Create 64M Partition (PP.UAPP-00004..APP64) ---" -ForegroundColor Cyan
$op64Res = Run-Pfsshell @("device $diskImg", "mkpart PP.UAPP-00004..APP64 64M PFS")
if ($op64Res.Stdout -notmatch "created") { throw "FAIL: Failed to create 64M partition: $($op64Res.Stdout)" }
$currentExpectedParts["PP.UAPP-00004..APP64"] = "64MB"
Assert-PartitionTableIntegrity -StepName "4.4: 64M Partition" -ExpectedPartitions $currentExpectedParts

# Test 4.5: Retained 128M User Partition (PP.UAPP-00005..APP128)
Write-Host "`n--- Operation 4.5: Create 128M Partition (PP.UAPP-00005..APP128) ---" -ForegroundColor Cyan
$op128Res = Run-Pfsshell @("device $diskImg", "mkpart PP.UAPP-00005..APP128 128M PFS")
if ($op128Res.Stdout -notmatch "created") { throw "FAIL: Failed to create 128M partition: $($op128Res.Stdout)" }
$currentExpectedParts["PP.UAPP-00005..APP128"] = "128MB"
Assert-PartitionTableIntegrity -StepName "4.5: 128M Partition" -ExpectedPartitions $currentExpectedParts

# Test 4.6: Fixed-size 128M PSBBN Resource Header Partition (PP.HDL.Game1.RES)
Write-Host "`n--- Operation 4.6: Create Fixed 128M PSBBN Resource Partition ---" -ForegroundColor Cyan
$opResHeader = Run-Pfsshell @("device $diskImg", "mkpart PP.HDL.Game1.RES 128M PFS")
if ($opResHeader.Stdout -notmatch "created") { throw "FAIL: Failed to create PSBBN resource partition: $($opResHeader.Stdout)" }
$currentExpectedParts["PP.HDL.Game1.RES"] = "128MB"
Assert-PartitionTableIntegrity -StepName "4.6: Fixed 128M PSBBN Resource" -ExpectedPartitions $currentExpectedParts

# -------------------------------------------------------------
# Step 5: PFS Filesystem Read/Write Roundtrip on Small Partitions
# -------------------------------------------------------------
Write-Host "`n[Step 5] Testing PFS Filesystem Read/Write Payload Roundtrip..." -ForegroundColor Yellow

$payload1 = Join-Path $WorkingDir "EXECUTE.ELF"
$payload2 = Join-Path $WorkingDir "CONFIG.DAT"
[System.IO.File]::WriteAllBytes($payload1, (New-Object byte[] 65536))
[System.IO.File]::WriteAllBytes($payload2, (New-Object byte[] 32768))

$p1Hash = (Get-FileHash -Path $payload1 -Algorithm SHA256).Hash
$p2Hash = (Get-FileHash -Path $payload2 -Algorithm SHA256).Hash

Write-Host "   Writing payloads to 8M partition (PP.UAPP-00001..APP8)..."
$pfsWriteRes = Run-Pfsshell @(
    "device $diskImg",
    "mount PP.UAPP-00001..APP8",
    "lcd `"$WorkingDir`"",
    "put EXECUTE.ELF",
    "put CONFIG.DAT",
    "umount"
)
if ($pfsWriteRes.ExitCode -ne 0) { throw "FAIL: PFS write to 8M partition failed: $($pfsWriteRes.Stdout)" }

Write-Host "   Reopening disk image and extracting payloads..."
$extractDir = Join-Path $WorkingDir "extracted"
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

$pfsReadRes = Run-Pfsshell @(
    "device $diskImg",
    "mount PP.UAPP-00001..APP8",
    "lcd `"$extractDir`"",
    "get EXECUTE.ELF",
    "get CONFIG.DAT",
    "umount"
)
if ($pfsReadRes.ExitCode -ne 0) { throw "FAIL: PFS read from 8M partition failed: $($pfsReadRes.Stdout)" }

$ext1Hash = (Get-FileHash -Path (Join-Path $extractDir "EXECUTE.ELF") -Algorithm SHA256).Hash
$ext2Hash = (Get-FileHash -Path (Join-Path $extractDir "CONFIG.DAT") -Algorithm SHA256).Hash

if ($ext1Hash -ne $p1Hash -or $ext2Hash -ne $p2Hash) {
    throw "FAIL: PFS payload roundtrip hash mismatch on 8M partition!"
}
Write-Host "   PFS 8M payload roundtrip verified: All file SHA-256 hashes matched." -ForegroundColor Green

# -------------------------------------------------------------
# Step 6: Final Storage-Isolation Verification
# -------------------------------------------------------------
Write-Host "`n[Step 6] Final Full-Span Storage-Isolation Verification..." -ForegroundColor Yellow

$finalToc = Run-HdlDump @("toc", "`"$diskImg`"")
Write-Host "`n--- Final APA TOC ---" -ForegroundColor Cyan
Write-Host $finalToc.Stdout

$finalDiag = Run-HdlDump @("diag", "`"$diskImg`"")
if ($finalDiag.ExitCode -ne 0 -or $finalDiag.Stdout -match "error|warning|corrupt|invalid") {
    throw "FAIL: Final diag reported errors!`n$($finalDiag.Stdout)"
}
Write-Host "   Final hdl_dump diag: CLEAN (0 errors, 0 warnings)" -ForegroundColor Green

$finalExfatHash = Get-RegionHash -FilePath $diskImg -Offset $exfatOffset -Length $exfatBytes
Write-Host "`n   Baseline exFAT Hash: $baselineExfatHash"
Write-Host "   Final exFAT Hash:    $finalExfatHash"

if ($finalExfatHash -ne $baselineExfatHash) {
    throw "FATAL: exFAT storage region was modified during APA operations!"
}
Write-Host "   exFAT SHA-256 MATCHES 100% BYTE-FOR-BYTE! Full storage independence PROVEN." -ForegroundColor Green

# Cleanup
Remove-Item -Path $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  PHASE 9: ALL STORAGE ISOLATION & REGRESSION TESTS PASSED! " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
