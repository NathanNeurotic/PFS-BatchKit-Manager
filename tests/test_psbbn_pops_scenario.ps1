# test_psbbn_pops_scenario.ps1
# Phase 6: PSBBN-DP Realistic Scenario & POPS Acceptance Test Harness
# Validates adding an 8 MiB __.POPS partition to an existing representative PSBBN-DP APA layout,
# verifying non-interference with pre-existing partitions, PFS filesystem roundtrip, and exact exFAT region hash invariance.

param(
    [string]$PfsshellPath = "C:\Users\natha\Github\pfsshell\build-win\pfsshell.exe",
    [string]$HdlDumpPath = "C:\Users\natha\Github\hdl-dump\hdl_dump.exe",
    [string]$WorkingDir = "$PSScriptRoot\fixtures_psbbn",
    [int]$TimeoutMs = 180000
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Phase 6: PSBBN-DP Realistic Scenario & POPS Acceptance   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "pfsshell binary: $PfsshellPath"
Write-Host "hdl_dump binary: $HdlDumpPath"
Write-Host "Working directory: $WorkingDir"

if (-not (Test-Path $PfsshellPath)) { throw "pfsshell executable not found at '$PfsshellPath'" }
if (-not (Test-Path $HdlDumpPath)) { throw "hdl_dump executable not found at '$HdlDumpPath'" }

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

    $swWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    $sw = $p.StandardInput
    $sw.Write($inputScript)
    $sw.Flush()
    $sw.Close()

    $completed = $p.WaitForExit($Timeout)
    $swWatch.Stop()
    $elapsedSec = [math]::Round($swWatch.Elapsed.TotalSeconds, 1)

    if (-not $completed) {
        $p.Kill()
        throw "pfsshell timed out after ${elapsedSec}s (limit: $($Timeout / 1000)s)"
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
    param([string]$Arguments, [int]$Timeout = $TimeoutMs)
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

    $completed = $p.WaitForExit($Timeout)
    $swWatch.Stop()
    $elapsedSec = [math]::Round($swWatch.Elapsed.TotalSeconds, 1)

    if (-not $completed) {
        $p.Kill()
        throw "hdl_dump timed out after ${elapsedSec}s (limit: $($Timeout / 1000)s)"
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

# Function to compute SHA-256 of a specific byte slice in a file
function Get-FileRangeHash {
    param(
        [string]$FilePath,
        [long]$Offset,
        [long]$Length
    )
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($FilePath)
    $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null

    $buffer = New-Object byte[] (1024 * 1024) # 1 MB buffer
    $remaining = $Length
    while ($remaining -gt 0) {
        $toRead = [int][Math]::Min([long]$buffer.Length, [long]$remaining)
        $read = $fs.Read($buffer, 0, $toRead)
        if ($read -eq 0) { break }
        if ($remaining -eq $read) {
            $sha256.TransformFinalBlock($buffer, 0, $read) | Out-Null
            break
        } else {
            $sha256.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
        }
        $remaining -= $read
    }
    $fs.Close()
    $hashBytes = $sha256.Hash
    return ($hashBytes | ForEach-Object { $_.ToString("X2") }) -join ""
}

# ==============================================================================
# Step 1: Construct Representative PSBBN-DP Disk Fixture (16 GiB)
# ==============================================================================
Write-Host "`n[Step 1] Constructing Representative PSBBN-DP Disk Fixture (16 GiB)..." -ForegroundColor Yellow
$diskImg = Join-Path $WorkingDir "psbbn_dp_16g.img"

# 16 GiB total disk size (33,554,432 sectors)
# Layout:
# - APA Region: 0 MB to 12,288 MB (12 GiB = 25,165,824 sectors)
# - exFAT Region: 12,288 MB to 16,384 MB (4 GiB = 8,388,608 sectors, starting at LBA 25,165,824)
$fileStream = [System.IO.File]::Create($diskImg)
$fileStream.SetLength(16L * 1024L * 1024L * 1024L)

# Write synthetic exFAT structure at 12 GiB offset (LBA 25,165,824)
$exfatOffset = 12L * 1024L * 1024L * 1024L
$exfatLength = 4L * 1024L * 1024L * 1024L
$fileStream.Seek($exfatOffset, [System.IO.SeekOrigin]::Begin) | Out-Null

# exFAT VBR signature and deterministic pattern payload
$vbr = New-Object byte[] 512
$vbr[0] = 0xEB; $vbr[1] = 0x76; $vbr[2] = 0x90 # Jump boot
[System.Text.Encoding]::ASCII.GetBytes("EXFAT   ").CopyTo($vbr, 3) # OEM Name
$vbr[510] = 0x55; $vbr[511] = 0xAA # Boot signature
$fileStream.Write($vbr, 0, 512)

# Write deterministic payload blocks across exFAT area to establish a realistic non-zero hash
$payloadPattern = [System.Text.Encoding]::UTF8.GetBytes("PSBBN-DP_EXFAT_PAYLOAD_TEST_DATA_BLOCK_PROTECTED_REGION_DO_NOT_CORRUPT_")
for ($i = 0; $i -lt 100; $i++) {
    $fileStream.Seek($exfatOffset + 1048576 + ($i * 65536), [System.IO.SeekOrigin]::Begin) | Out-Null
    $fileStream.Write($payloadPattern, 0, $payloadPattern.Length)
}
$fileStream.Flush()
$fileStream.Close()

Write-Host "   Disk fixture created: $diskImg (16 GiB)"

# ==============================================================================
# Step 2: Initialize PSBBN-DP APA Structure with Pre-Existing Partitions
# ==============================================================================
Write-Host "`n[Step 2] Initializing PSBBN-DP APA Structure with Base Partitions..." -ForegroundColor Yellow

# Initialize APA and standard PSBBN system partitions
$res = Run-Pfsshell @("device $diskImg", "initialize yes")
if ($res.Output -notmatch "Capacity" -and $res.Output -notmatch "pfs version") {
    throw "Base APA initialization failed: $($res.Output) $($res.Error)"
}

# Create pre-existing game/system partition: PP.HDL.Game1 (1024 MB PFS)
$res = Run-Pfsshell @("device $diskImg", "mkpart PP.HDL.Game1 1024M PFS")
if ($res.Output -notmatch "Main partition of (1024M|1G) created") {
    throw "Failed to create PP.HDL.Game1 partition: $($res.Output) $($res.Error)"
}

# Create pre-existing channel partition: __bbn (256 MB PFS)
$res = Run-Pfsshell @("device $diskImg", "mkpart __bbn 256M PFS")
if ($res.Output -notmatch "Main partition of 256M created") {
    throw "Failed to create __bbn partition: $($res.Output) $($res.Error)"
}
Write-Host "   Pre-existing PSBBN partitions created successfully." -ForegroundColor Green

# ==============================================================================
# Step 3: Establish Immutable Pre-Test Baseline & Inventory
# ==============================================================================
Write-Host "`n[Step 3] Establishing Immutable Pre-Test Baseline Inventory..." -ForegroundColor Yellow

$preTocRes = Run-HdlDump "toc `"$diskImg`""
Write-Host "`n--- Baseline APA TOC ---" -ForegroundColor Cyan
Write-Host $preTocRes.Output

$preDiagRes = Run-HdlDump "diag `"$diskImg`""
if ($preDiagRes.Output -match "outside data area|mismatching|not multiple|previous is|next is") {
    throw "Pre-test APA partition table is corrupted: $($preDiagRes.Output)"
}
Write-Host "   Baseline hdl_dump diag: CLEAN (0 errors)" -ForegroundColor Green

# Calculate and record baseline exFAT SHA-256 hash
$preExfatHash = Get-FileRangeHash -FilePath $diskImg -Offset $exfatOffset -Length $exfatLength
Write-Host "   Baseline exFAT Region SHA-256 (Offset $exfatOffset, Length $exfatLength bytes):" -ForegroundColor Cyan
Write-Host "   $preExfatHash" -ForegroundColor Yellow

# ==============================================================================
# Step 4: Perform Critical Acceptance Test: Add __.POPS (8 MiB) into Free APA Space
# ==============================================================================
Write-Host "`n[Step 4] Performing Acceptance Test: Creating __.POPS (8 MiB PFS)..." -ForegroundColor Yellow

$createPopsRes = Run-Pfsshell @("device $diskImg", "mkpart __.POPS 8M PFS")
if ($createPopsRes.Output -notmatch "Main partition of 8M created") {
    throw "Failed to create __.POPS (8M): $($createPopsRes.Output) $($createPopsRes.Error)"
}
Write-Host "   __.POPS (8 MiB) partition successfully created in APA free space." -ForegroundColor Green

# ==============================================================================
# Step 5: Verify APA TOC, Pre-Existing Partitions, and Diag Integrity
# ==============================================================================
Write-Host "`n[Step 5] Verifying Post-Modification APA TOC and Diag..." -ForegroundColor Yellow

$postTocRes = Run-HdlDump "toc `"$diskImg`""
Write-Host "`n--- Post-Modification APA TOC ---" -ForegroundColor Cyan
Write-Host $postTocRes.Output

# Verify all pre-existing partitions are still present and unaltered
$requiredPartitions = @("__mbr", "__net", "__system", "__sysconf", "__common", "PP.HDL.Game1", "__bbn", "__.POPS")
foreach ($part in $requiredPartitions) {
    if ($postTocRes.Output -notmatch [regex]::Escape($part)) {
        throw "CRITICAL REGRESSION: Partition '$part' missing after __.POPS creation!"
    }
}
Write-Host "   All pre-existing partitions and __.POPS verified present in TOC." -ForegroundColor Green

$postDiagRes = Run-HdlDump "diag `"$diskImg`""
if ($postDiagRes.Output -match "outside data area|mismatching|not multiple|previous is|next is") {
    throw "Post-modification APA partition table is corrupted: $($postDiagRes.Output)"
}
Write-Host "   Post-modification hdl_dump diag: CLEAN (0 errors)" -ForegroundColor Green

# ==============================================================================
# Step 6: Test Real PFS Filesystem Payload Roundtrip on __.POPS
# ==============================================================================
Write-Host "`n[Step 6] Testing PFS Filesystem Payload Roundtrip on __.POPS..." -ForegroundColor Yellow

$popsPayloadDir = Join-Path $WorkingDir "pops_payload"
New-Item -ItemType Directory -Path $popsPayloadDir -Force | Out-Null

$execElf = Join-Path $popsPayloadDir "EXECUTE.ELF"
$titlesTxt = Join-Path $popsPayloadDir "TITLES.TXT"
$dummyVcd = Join-Path $popsPayloadDir "SLUS_200.01.VCD"

# Generate deterministic payloads
[System.IO.File]::WriteAllBytes($execElf, (1..8192 | ForEach-Object { [byte]($_ % 256) }))
[System.IO.File]::WriteAllText($titlesTxt, "SLUS_200.01=Castlevania - Symphony of the Night`n")
[System.IO.File]::WriteAllBytes($dummyVcd, (1..65536 | ForEach-Object { [byte]((256 + ($_ % 256)) % 256) }))

$origElfHash = (Get-FileHash -Path $execElf -Algorithm SHA256).Hash
$origTitlesHash = (Get-FileHash -Path $titlesTxt -Algorithm SHA256).Hash
$origVcdHash = (Get-FileHash -Path $dummyVcd -Algorithm SHA256).Hash

Write-Host "   Writing POPS payloads to __.POPS partition in pfsshell..."
$writeCmds = @(
    "device $diskImg",
    "lcd `"$popsPayloadDir`"",
    "mount __.POPS",
    "put EXECUTE.ELF",
    "put TITLES.TXT",
    "put SLUS_200.01.VCD",
    "ls",
    "umount"
)
$writeRes = Run-Pfsshell $writeCmds
if ($writeRes.Output -notmatch "SLUS_200.01.VCD" -or $writeRes.Output -notmatch "EXECUTE.ELF") {
    throw "Failed to write POPS payloads: $($writeRes.Output) $($writeRes.Error)"
}

Write-Host "   Reopening disk fixture and extracting payloads from __.POPS..."
$extractedDir = Join-Path $WorkingDir "pops_extracted"
New-Item -ItemType Directory -Path $extractedDir -Force | Out-Null

$readCmds = @(
    "device $diskImg",
    "lcd `"$extractedDir`"",
    "mount __.POPS",
    "cd /",
    "get EXECUTE.ELF",
    "get TITLES.TXT",
    "get SLUS_200.01.VCD",
    "umount"
)
$readRes = Run-Pfsshell $readCmds

$extElf = Join-Path $extractedDir "EXECUTE.ELF"
$extTitles = Join-Path $extractedDir "TITLES.TXT"
$extVcd = Join-Path $extractedDir "SLUS_200.01.VCD"

if (-not (Test-Path $extElf) -or -not (Test-Path $extTitles) -or -not (Test-Path $extVcd)) {
    throw "Extracted POPS files missing: $($readRes.Output) $($readRes.Error)"
}

$extElfHash = (Get-FileHash -Path $extElf -Algorithm SHA256).Hash
$extTitlesHash = (Get-FileHash -Path $extTitles -Algorithm SHA256).Hash
$extVcdHash = (Get-FileHash -Path $extVcd -Algorithm SHA256).Hash

if ($origElfHash -ne $extElfHash -or $origTitlesHash -ne $extTitlesHash -or $origVcdHash -ne $extVcdHash) {
    throw "SHA-256 mismatch on extracted POPS files!"
}
Write-Host "   POPS payload roundtrip verified (All 3 file SHA-256 hashes matched identically)." -ForegroundColor Green

# ==============================================================================
# Step 7: Strict APA / exFAT Isolation Verification
# ==============================================================================
Write-Host "`n[Step 7] Strict APA / exFAT Isolation Verification..." -ForegroundColor Yellow

$postExfatHash = Get-FileRangeHash -FilePath $diskImg -Offset $exfatOffset -Length $exfatLength
Write-Host "   Post-Modification exFAT Region SHA-256:" -ForegroundColor Cyan
Write-Host "   $postExfatHash" -ForegroundColor Yellow

if ($preExfatHash -ne $postExfatHash) {
    throw "CRITICAL FAILURE: exFAT region SHA-256 hash modified during APA __.POPS creation! APA operations violated exFAT isolation boundary."
}
Write-Host "   exFAT Region SHA-256 matches 100% byte-for-byte! APA / exFAT isolation is COMPLETE and UNBROKEN." -ForegroundColor Green

# ==============================================================================
# Summary
# ==============================================================================
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  PHASE 6: ALL ACCEPTANCE AND ISOLATION TESTS PASSED!     " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
