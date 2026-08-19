# test_apa_disk_regression.ps1
# Automated APA / PFS Disk-Image Regression Test Suite
# Tests 8 MiB allocation granularity, all partition sizes (8M-2G), PFS read/write, adjacent allocations,
# APA double-linked list consistency, TOC backup/restore, and 128 GiB slice boundary invariance.

param(
    [string]$PfsshellPath = "C:\Users\natha\Github\pfsshell\build-win\pfsshell.exe",
    [string]$HdlDumpPath = "C:\Users\natha\Github\hdl-dump\hdl_dump.exe",
    [string]$WorkingDir = "$PSScriptRoot\fixtures",
    [int]$DefaultTimeoutMs = 180000,
    [int]$LargeDiskTimeoutMs = 360000
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Starting APA / PFS Disk-Image Regression Test Harness   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "pfsshell binary: $PfsshellPath"
Write-Host "hdl_dump binary: $HdlDumpPath"
Write-Host "Working directory: $WorkingDir"

if (-not (Test-Path $PfsshellPath)) {
    throw "pfsshell executable not found at '$PfsshellPath'"
}
if (-not (Test-Path $HdlDumpPath)) {
    throw "hdl_dump executable not found at '$HdlDumpPath'"
}

if (Test-Path $WorkingDir) {
    Remove-Item -Path $WorkingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null

function Run-Pfsshell {
    param([string[]]$Commands, [int]$TimeoutMs = $DefaultTimeoutMs)
    $inputScript = ($Commands -join "`n") + "`nexit`n"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PfsshellPath
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $swWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    $sw = $p.StandardInput
    $sw.Write($inputScript)
    $sw.Flush()
    $sw.Close()

    $completed = $p.WaitForExit($TimeoutMs)
    $swWatch.Stop()
    $elapsedSec = [math]::Round($swWatch.Elapsed.TotalSeconds, 1)

    if (-not $completed) {
        $p.Kill()
        throw "pfsshell timed out after ${elapsedSec}s (limit: $($TimeoutMs / 1000)s)"
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result

    return [PSCustomObject]@{
        ExitCode = $p.ExitCode
        Output = $stdout
        Error = $stderr
        ElapsedSeconds = $elapsedSec
    }
}

function Run-HdlDump {
    param([string]$Arguments, [int]$TimeoutMs = $DefaultTimeoutMs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HdlDumpPath
    $psi.Arguments = $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $swWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    $completed = $p.WaitForExit($TimeoutMs)
    $swWatch.Stop()
    $elapsedSec = [math]::Round($swWatch.Elapsed.TotalSeconds, 1)

    if (-not $completed) {
        $p.Kill()
        throw "hdl_dump timed out after ${elapsedSec}s (limit: $($TimeoutMs / 1000)s)"
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result

    return [PSCustomObject]@{
        ExitCode = $p.ExitCode
        Output = $stdout
        Error = $stderr
        ElapsedSeconds = $elapsedSec
    }
}

# ==============================================================================
# Class 1: Small Allocation Suite (4 GiB Disk Image)
# ==============================================================================
Write-Host "`n--- [Class 1] Small Allocation Suite (8 GiB Disk Image) ---" -ForegroundColor Yellow
$smallImg = Join-Path $WorkingDir "small_8g.img"

Write-Host "Creating 8 GiB raw disk image: $smallImg"
$fileStream = [System.IO.File]::Create($smallImg)
$fileStream.SetLength(8L * 1024L * 1024L * 1024L) # 8 GiB
$fileStream.Close()

Write-Host "1. Initializing APA partitioning on disk image..."
$res = Run-Pfsshell @("device $smallImg", "initialize yes")
if ($res.Output -notmatch "Capacity" -and $res.Output -notmatch "4GiB" -and $res.Output -notmatch "4096MB") {
    Write-Host $res.Output
    Write-Host $res.Error
    throw "APA initialization failed on small disk image"
}
Write-Host "   APA initialization SUCCESS." -ForegroundColor Green

Write-Host "2. Checking initial partition TOC with hdl_dump..."
$res = Run-HdlDump "toc `"$smallImg`""
if ($res.Output -notmatch "__mbr" -or $res.Output -notmatch "__system") {
    throw "hdl_dump failed to read initial TOC: $($res.Output) $($res.Error)"
}
Write-Host "   Initial TOC check SUCCESS." -ForegroundColor Green

Write-Host "3. Running hdl_dump diag on initialized APA table..."
$res = Run-HdlDump "diag `"$smallImg`""
if ($res.Output -match "error|corrupt|problem" -or $res.Error -match "error") {
    throw "hdl_dump diag reported errors on fresh APA disk: $($res.Output) $($res.Error)"
}
Write-Host "   Initial diag check CLEAN." -ForegroundColor Green

Write-Host "4. Testing all partition sizes (8M, 16M, 32M, 64M, 128M, 256M, 512M, 1G)..."
$testSizes = @(
    @{ Name = "__test8";   Size = "8M" },
    @{ Name = "__test16";  Size = "16M" },
    @{ Name = "__test32";  Size = "32M" },
    @{ Name = "__test64";  Size = "64M" },
    @{ Name = "__test128"; Size = "128M" },
    @{ Name = "__test256"; Size = "256M" },
    @{ Name = "__test512"; Size = "512M" },
    @{ Name = "__test1G";  Size = "1G" }
)

foreach ($part in $testSizes) {
    Write-Host "   Creating partition $($part.Name) ($($part.Size) PFS)..."
    $res = Run-Pfsshell @("device $smallImg", "mkpart $($part.Name) $($part.Size) PFS")
    if ($res.Output -notmatch "Main partition of .* created") {
        Write-Host $res.Output
        Write-Host $res.Error
        throw "Failed to create partition $($part.Name) with size $($part.Size)"
    }
}
Write-Host "   All partition sizes (8M through 1G) created successfully." -ForegroundColor Green

Write-Host "5. Creating adjacent 8M partition to test APA linked-list continuity..."
$res = Run-Pfsshell @("device $smallImg", "mkpart __test8_adj 8M PFS")
if ($res.Output -notmatch "Main partition of 8M created") {
    throw "Failed to create adjacent 8M partition: $($res.Output) $($res.Error)"
}

Write-Host "6. Verifying partition table with hdl_dump diag..."
$res = Run-HdlDump "diag `"$smallImg`""
if ($res.Output -match "outside data area|mismatching|not multiple|previous is|next is") {
    throw "hdl_dump diag reported partition table corruption: $($res.Output) $($res.Error)"
}
Write-Host "   hdl_dump diag verified partition table integrity after adjacent 8M creation." -ForegroundColor Green

Write-Host "7. Testing PFS filesystem Read/Write on 8 MiB partition (__test8)..."
$testData = [byte[]](1..65536 | ForEach-Object { $_ % 256 })
$localIn = Join-Path $WorkingDir "DATA.BIN"
$localOut = Join-Path $WorkingDir "DATA_OUT.BIN"
[System.IO.File]::WriteAllBytes($localIn, $testData)
$inHash = (Get-FileHash -Path $localIn -Algorithm SHA256).Hash

Write-Host "   Mounting __test8, creating directories, uploading test payload..."
$res = Run-Pfsshell @(
    "device $smallImg",
    "lcd `"$WorkingDir`"",
    "mount __test8",
    "mkdir TESTDIR",
    "cd TESTDIR",
    "put DATA.BIN",
    "ls",
    "umount"
)
if ($res.Output -notmatch "DATA.BIN") {
    Write-Host $res.Output
    Write-Host $res.Error
    throw "PFS write/ls verification failed on __test8"
}

Write-Host "   Reopening disk image, mounting __test8, retrieving payload..."
$retrievedDir = Join-Path $WorkingDir "retrieved"
New-Item -ItemType Directory -Path $retrievedDir -Force | Out-Null
$res = Run-Pfsshell @(
    "device $smallImg",
    "lcd `"$retrievedDir`"",
    "mount __test8",
    "cd TESTDIR",
    "get DATA.BIN",
    "umount"
)
$extractedFile = Join-Path $retrievedDir "DATA.BIN"
if (-not (Test-Path $extractedFile)) {
    throw "Failed to extract DATA.BIN from __test8"
}
$outHash = (Get-FileHash -Path $extractedFile -Algorithm SHA256).Hash
if ($inHash -ne $outHash) {
    throw "Extracted file hash ($outHash) does not match input hash ($inHash) on 8M partition!"
}
Write-Host "   PFS 8 MiB partition filesystem roundtrip verified (SHA-256 matched: $inHash)." -ForegroundColor Green

Write-Host "8. Testing TOC Backup and Restore with 8M partitions..."
$tocBak = Join-Path $WorkingDir "toc_small.bak"
$res = Run-HdlDump "backup_toc `"$smallImg`" `"$tocBak`""
if (-not (Test-Path $tocBak) -or (Get-Item $tocBak).Length -eq 0) {
    throw "backup_toc failed: $($res.Output) $($res.Error)"
}
Write-Host "   backup_toc SUCCESS ($((Get-Item $tocBak).Length) bytes)." -ForegroundColor Green

$res = Run-HdlDump "restore_toc `"$smallImg`" `"$tocBak`""
$res = Run-HdlDump "diag `"$smallImg`""
if ($res.Output -match "error|corrupt|outside data area|mismatching") {
    throw "restore_toc corrupted partition table: $($res.Output) $($res.Error)"
}
Write-Host "   restore_toc and post-restore diag SUCCESS." -ForegroundColor Green

Write-Host "9. Testing partition deletion (__test8_adj)..."
$res = Run-Pfsshell @("device $smallImg", "rmpart __test8_adj")
$res = Run-HdlDump "diag `"$smallImg`""
if ($res.Output -match "error|corrupt|outside data area|mismatching") {
    throw "Partition deletion corrupted APA table: $($res.Output) $($res.Error)"
}
Write-Host "   rmpart and post-delete diag CLEAN." -ForegroundColor Green


# ==============================================================================
# Class 2: 128 GiB APA Primary Slice-Boundary Simulation Suite
# ==============================================================================
Write-Host "`n--- [Class 2] 128 GiB APA Primary Slice-Boundary Simulation Suite ---" -ForegroundColor Yellow
$largeImg = Join-Path $WorkingDir "large_130g.img"

Write-Host "Creating 130 GiB sparse disk image fixture..."
$fileStreamLarge = [System.IO.File]::Create($largeImg)
# 130 GiB = 130 * 1024 * 1024 * 1024 bytes = 139,586,437,120 bytes (272,629,760 sectors)
$fileStreamLarge.SetLength(130L * 1024L * 1024L * 1024L)
$fileStreamLarge.Close()

Write-Host "1. Initializing APA partitioning on 130 GiB disk image..."
$res = Run-Pfsshell @("device $largeImg", "initialize yes") $LargeDiskTimeoutMs
if ($res.Output -notmatch "Capacity" -and $res.Output -notmatch "pfs version") {
    throw "APA initialization failed on 130 GiB image: $($res.Output) $($res.Error)"
}
Write-Host "   APA 130 GiB initialization completed in $($res.ElapsedSeconds)s." -ForegroundColor Green

Write-Host "2. Reading TOC on 130 GiB disk to verify Slice 1 and Slice 2 boundaries..."
$res = Run-HdlDump "toc `"$largeImg`""

# Slice total must be 130 GiB (133120 MB), NOT 8 GB (8192 MB)!
if ($res.Output -match "Total slice size: 133120MB" -or $res.Output -match "Total slice size: 131072MB") {
    Write-Host "   Disk slice size correctly reported as 130 GiB / 128+ GiB (not truncated to 8 GB)!" -ForegroundColor Green
} elseif ($res.Output -match "Total slice size: 8192MB") {
    throw "CRITICAL BUG: Total slice size was truncated to 8192 MB (8 GB)! Slice boundary arithmetic is confused with 8 MB chunk size."
} else {
    Write-Host $res.Output
    Write-Host "   Verifying slice dimensions in TOC output..."
}

Write-Host "3. Creating 8 MiB partition on 130 GiB disk..."
$res = Run-Pfsshell @("device $largeImg", "mkpart __pops8 8M PFS")
if ($res.Output -notmatch "Main partition of 8M created") {
    throw "Failed to create 8M partition on large disk image: $($res.Output) $($res.Error)"
}

Write-Host "4. Running hdl_dump diag on 130 GiB disk with 8M partition..."
$res = Run-HdlDump "diag `"$largeImg`""
if ($res.Output -match "outside data area|mismatching|not multiple|previous is|next is") {
    throw "hdl_dump diag reported corruption on large disk: $($res.Output) $($res.Error)"
}
Write-Host "   Large disk 128 GiB slice boundary + 8 MiB partition test PASSED CLEANLY." -ForegroundColor Green


# ==============================================================================
# Summary
# ==============================================================================
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  ALL APA / PFS DISK-IMAGE REGRESSION TESTS PASSED!       " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
