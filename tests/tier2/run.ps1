# tests/tier2/run.ps1
#
# TIER-2 INTEGRATION RUNNER (Windows host).
#
# Runs tests/tier2/record.lua inside CraftOS-PC's CONSOLE binary in headless
# mode, against a real .nbs fixture, on a real emulated speaker; records every
# peripheral call to result.txt; and exits 0 only when the run really passed.
#
# Usage:
#   powershell -File tests/tier2/run.ps1
#   powershell -File tests/tier2/run.ps1 tests/fixtures/new_file.nbs
#   powershell -File tests/tier2/run.ps1 -TimeoutSec 180
#   powershell -File tests/tier2/run.ps1 -Assert                 # project + compare + 10-run determinism
#   powershell -File tests/tier2/run.ps1 -Assert -Fixture tests/fixtures/compat_demo_song.nbs
#   powershell -File tests/tier2/run.ps1 -Assert -DeterminismRuns 3
#   powershell -File tests/tier2/run.ps1 -Assert -ExpectedFile tests/tier2/expected/v4.txt
#   powershell -File tests/tier2/run.ps1 -Fixture tests/tier2/fixtures/capacity_10.nbs -SpeakerSides "back,left" -Assert
#   powershell -File tests/tier2/run.ps1 -Fixture <file> -CaptureResult <path>   # copy result.txt out for a spec
#
# -SpeakerSides <csv>: the emulated speaker sides record.lua attaches and routes
#   through player.fanout.assign (default "back").  The SAME sides are handed to
#   the projection assertion, so a multi-speaker fixture compares like-for-like.
# -CaptureResult <path>: copy the recorded result.txt to <path> before the temp
#   directory is deleted.  Used by tests/tier2/edge_cases.ps1 to assert on the
#   raw file channel even when the run is EXPECTED to fail (malformed corpus).
#
# ASSERTION MODE (-Assert without -ExpectedFile):
#   * tests/tier2/assert_order.lua projects the expected ordered call sequence
#     from the fixture with the REAL player modules, and compares it EXACTLY
#     (no tolerance, no reordering) against the recorded result.txt.  The
#     three peripheral-discovery lines (getNames/getType/wrap) are ignored.
#   * the fixture is then run -DeterminismRuns (default 10) consecutive times
#     and the recorded CALL lines must be BYTE-IDENTICAL (SHA-256) every run.
#   * -Assert -ExpectedFile <path> keeps the original single-run comparison
#     against a checked-in recording.
#   A run WITHOUT -Assert is unchanged: it still just reports PASS.
#
# FOUR HARD-WON OPERATIONAL RULES (all reproduced, see the evidence file):
#   1. The CONSOLE binary is mandatory.  CraftOS-PC.exe (GUI subsystem) refuses
#      --headless, pops a MODAL dialog and blocks until a human clicks OK.
#   2. record.lua must call os.shutdown(N).  A script that returns without it
#      leaves the emulator in its shell and hangs forever -- hence the timeout
#      below and the kill-on-expiry.
#   3. stdout is NEVER truncate-piped.  It is redirected to a file (here, read
#      asynchronously into a string and written to emulator.log).  Piping a live
#      native stream into `Select-Object -First` kills it early and yields a
#      fake exit code of -1.
#   4. stdout is NEVER parsed.  It is a screen-diff stream.  The result channel
#      is result.txt inside the fresh temp --directory.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Fixture = "tests/fixtures/v4.nbs",

    [int]$TimeoutSec = 120,

    # -Assert enables the assertion mode:
    #   * -Assert with NO -ExpectedFile  -> PROJECT the expected call sequence
    #     from the fixture with tests/tier2/assert_order.lua and compare it
    #     EXACTLY against what was recorded, then re-run the fixture
    #     -DeterminismRuns times and require BYTE-IDENTICAL recorded CALL lines.
    #   * -Assert -ExpectedFile <path>   -> the pre-existing behaviour: compare
    #     the recorded CALL lines against a checked-in expected recording.
    [switch]$Assert,

    [string]$ExpectedFile = "",

    # Consecutive emulator runs used by the assertion mode's determinism check.
    # Each run of the SAME fixture must produce byte-identical recorded CALL
    # lines (SHA-256 hashed).  Measured ~2.6 s per run on the pinned binary, so
    # the default 10 is practical; lower it only if that ever stops being true.
    [int]$DeterminismRuns = 10,

    # Comma/space-separated speaker sides the emulated run attaches and routes
    # through player.fanout.assign.  Default keeps the historical single speaker.
    [string]$SpeakerSides = "back",

    # Optional: copy the recorded result.txt to this path before the temp
    # directory is removed (used by edge_cases.ps1 to assert on raw records).
    [string]$CaptureResult = "",

    # Lua interpreter used for the host-side projection/comparison.
    [string]$LuaExe = "lua"
)

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$ConsoleExe  = "D:\tools\CraftOS-PC\CraftOS-PC_console.exe"
$ScriptFile  = Join-Path $ScriptDir "record.lua"

# Normalise -SpeakerSides into a non-empty list of side names.
$script:SpeakerSideList = @($SpeakerSides -split "[,\s]+" | Where-Object { $_ -ne "" })
if ($script:SpeakerSideList.Count -eq 0) {
    $script:SpeakerSideList = @("back")
}

$script:TempDir = $null

function Resolve-ProjectPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $ProjectRoot $Path)
}

function Show-Failure {
    param([int]$Code, [string]$Message)
    Write-Host ""
    Write-Host "FAIL: $Message" -ForegroundColor Red
    return $Code
}

# Invoke-Tier2 performs one bounded emulator run and returns an exit code.
function Invoke-Tier2 {
    param(
        [string]$FixturePath,
        [int]$TimeoutSec,
        [switch]$Assert,
        [string]$ExpectedFile,
        [switch]$Quiet
    )

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("ccnbs-tier2-" + [guid]::NewGuid().ToString("N"))
    $script:TempDir = $temp
    $computerDir = Join-Path $temp "computer\0"
    $resultPath  = Join-Path $computerDir "result.txt"
    $logPath     = Join-Path $temp "emulator.log"
    $proc        = $null

    try {
        if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
            return Show-Failure 2 "fixture not found: $FixturePath"
        }
        if (-not (Test-Path -LiteralPath $ConsoleExe -PathType Leaf)) {
            return Show-Failure 2 "CraftOS-PC console binary not found: $ConsoleExe"
        }

        # A FRESH temp --directory per run: runs cannot bleed into each other.
        New-Item -ItemType Directory -Path $computerDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $ProjectRoot "nbs")    -Destination (Join-Path $computerDir "nbs")    -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $ProjectRoot "player") -Destination (Join-Path $computerDir "player") -Recurse -Force
        Copy-Item -LiteralPath $FixturePath                      -Destination (Join-Path $computerDir "fixture.nbs") -Force

        # The speaker sides record.lua must attach and route through.  record.lua
        # reads this file (falling back to "back" when absent), so the same Lua
        # drives one or many emulated speakers without a second script.
        Set-Content -LiteralPath (Join-Path $computerDir "speakers.txt") `
            -Value ($script:SpeakerSideList -join ",") -Encoding ASCII -NoNewline

        # No audio device is needed by the emulated speaker.
        $env:SDL_AUDIODRIVER = "dummy"

        $arguments = @(
            "--headless",
            "--directory", ('"' + $temp + '"'),
            "--id", "0",
            "--script", ('"' + $ScriptFile + '"'),
            "-o", "standardsMode=true",
            "-o", "maxNotesPerTick=8",
            "-o", "http_enable=true"
        ) -join " "

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $ConsoleExe
        $psi.Arguments              = $arguments
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        # Read both streams asynchronously so a full pipe buffer can never
        # deadlock the child.  The content is written to a log file afterwards.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            try { [void]$proc.WaitForExit(5000) } catch { }
            $stdout = ""
            $stderr = ""
            try { $stdout = $stdoutTask.Result } catch { }
            try { $stderr = $stderrTask.Result } catch { }
            $log = "=== TIMEOUT after ${TimeoutSec}s; process killed ===" + "`r`n" + $stdout + "`r`n=== STDERR ===`r`n" + $stderr
            Set-Content -LiteralPath $logPath -Value $log -Encoding UTF8
            $survivors = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*CraftOS*" })
            Write-Host "timeout; CraftOS survivors after kill: $($survivors.Count)"
            return Show-Failure 3 "emulator exceeded the ${TimeoutSec}s timeout and was killed"
        }

        $stdout    = $stdoutTask.Result
        $stderr    = $stderrTask.Result
        $emuExit   = $proc.ExitCode
        $log       = $stdout + "`r`n=== STDERR ===`r`n" + $stderr
        Set-Content -LiteralPath $logPath -Value $log -Encoding UTF8
        if (-not $Quiet) {
            Write-Host "emulator exit code: $emuExit"
        }

        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            return Show-Failure 4 "result.txt was not written at $resultPath"
        }

        # Read result.txt as UTF-8 EXPLICITLY.  PowerShell 5.1's Get-Content
        # defaults to the ANSI code page, which mis-decodes the WARN[...] Chinese
        # prose; worse, a GBK lead byte can consume the following 0x0A, merging
        # the WARN line with STATUS and making the status check fail.  The
        # emulator writes correct UTF-8; the host must decode it as such.
        $resultText = [System.IO.File]::ReadAllText($resultPath, [System.Text.Encoding]::UTF8)
        if (-not $Quiet) {
            Write-Host "----- result.txt -----"
            Write-Host $resultText
            Write-Host "----------------------"
        }

        $lines     = @($resultText -split "\r?\n" | Where-Object { $_ -ne "" })
        $callLines = @($lines | Where-Object { $_ -like "CALL *" })
        $status    = if ($lines.Count -gt 0) { $lines[$lines.Count - 1] } else { "" }
        $script:CallCount = $callLines.Count

        # Hand the recorded evidence back to the caller so the assertion mode can
        # hash it and compare it without re-reading the (about to be deleted)
        # emulator temp directory.
        $script:LastCallLines  = $callLines
        $script:LastResultText = $resultText

        if ($emuExit -ne 0) {
            return Show-Failure 5 "emulator exit code was $emuExit (expected 0)"
        }
        if ($status -ne "STATUS ok") {
            return Show-Failure 6 "missing 'STATUS ok' -- last line was '$status'"
        }

        if ($Assert -and $ExpectedFile -ne "") {
            $expectedPath = Resolve-ProjectPath $ExpectedFile
            if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
                return Show-Failure 7 "expected recording not found: $expectedPath"
            }
            $expectedCalls = @(Get-Content -LiteralPath $expectedPath | Where-Object { $_ -like "CALL *" })
            if ($expectedCalls.Count -ne $callLines.Count) {
                return Show-Failure 8 ("recorded call count $($callLines.Count) does not match expected $($expectedCalls.Count)")
            }
            for ($i = 0; $i -lt $callLines.Count; $i++) {
                if ($callLines[$i] -ne $expectedCalls[$i]) {
                    return Show-Failure 9 ("call #$($i + 1) differs: got '$($callLines[$i])' expected '$($expectedCalls[$i])'")
                }
            }
            Write-Host "assert: recorded call sequence matches $expectedPath"
        }

        return 0
    }
    catch {
        return Show-Failure 1 "unexpected harness error: $($_.Exception.Message)"
    }
    finally {
        if ($proc -ne $null) {
            try {
                if (-not $proc.HasExited) {
                    $proc.Kill()
                    [void]$proc.WaitForExit(5000)
                }
            } catch { }
        }
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Assertion-mode helpers
# ---------------------------------------------------------------------------

# Get-CallLinesHash: SHA-256 (lower-case hex) of the recorded CALL lines joined
# by LF.  Two runs are "byte-identical" iff their hashes are equal.
function Get-CallLinesHash {
    param([string[]]$CallLines)
    if ($null -eq $CallLines) { $CallLines = @() }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($CallLines -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return (($digest | ForEach-Object { $_.ToString("x2") }) -join "")
}

# Invoke-SequenceAssertion: project the fixture with tests/tier2/assert_order.lua
# and compare it EXACTLY against the recorded text, in a child `lua` process.
# Returns 0 on a match; a non-zero harness code otherwise.  The recorded text is
# written to a temp file outside the (already deleted) emulator directory and is
# removed again in the finally block.
function Invoke-SequenceAssertion {
    param(
        [string]$FixturePath,
        [string]$ResultText,
        [string]$LuaExe
    )

    if ($null -eq (Get-Command $LuaExe -ErrorAction SilentlyContinue)) {
        return Show-Failure 13 "Lua interpreter not found on PATH: $LuaExe"
    }
    $assertOrderPath = Join-Path $ScriptDir "assert_order.lua"
    if (-not (Test-Path -LiteralPath $assertOrderPath -PathType Leaf)) {
        return Show-Failure 13 "assert_order.lua not found: $assertOrderPath"
    }

    $tmpResult = Join-Path ([System.IO.Path]::GetTempPath()) ("ccnbs-tier2-assert-" + [guid]::NewGuid().ToString("N") + ".txt")
    try {
        # Write the recorded text EXACTLY (no BOM, no newline mangling).
        [System.IO.File]::WriteAllText($tmpResult, $ResultText)

        Write-Host ""
        Write-Host "--- projection assertion (child: $LuaExe assert_order.lua) ---"
        $luaArgs = @($assertOrderPath, "--assert", $FixturePath, $tmpResult) + $script:SpeakerSideList
        # A native child that writes its assertion failure to stderr must NOT be
        # treated as a terminating PowerShell error: only its EXIT CODE decides
        # the result, so a genuine mismatch reaches exit 12 below.
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $LuaExe @luaArgs 2>&1 | ForEach-Object { Write-Host $_ }
            $luaExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
        if ($luaExit -ne 0) {
            return Show-Failure 12 "projected sequence does not match the recorded sequence (lua exit $luaExit)"
        }
        return 0
    }
    finally {
        if (Test-Path -LiteralPath $tmpResult) {
            Remove-Item -LiteralPath $tmpResult -Force -ErrorAction SilentlyContinue
        }
    }
}

$script:CallCount = 0
$script:LastCallLines = @()
$script:LastResultText = ""
$fixturePath = Resolve-ProjectPath $Fixture
Write-Host "tier2: fixture = $fixturePath"
Write-Host "tier2: timeout = ${TimeoutSec}s"

# PROJECTION mode is requested when -Assert is given without an explicit
# -ExpectedFile; it also enables the determinism loop.  Everything else (a plain
# run, or the legacy -Assert -ExpectedFile comparison) stays a SINGLE run.
$projectionMode = ($Assert -and ($ExpectedFile -eq ""))
$code = 0

if (-not $projectionMode) {
    $code = Invoke-Tier2 -FixturePath $fixturePath -TimeoutSec $TimeoutSec -Assert:$Assert -ExpectedFile $ExpectedFile
}
else {
    $runs = $DeterminismRuns
    if ($runs -lt 1) { $runs = 1 }
    Write-Host "tier2: assertion mode = projection + $runs-run determinism"

    $hashes = @()
    $firstText = $null

    for ($run = 1; $run -le $runs; $run++) {
        Write-Host ""
        Write-Host "tier2: determinism run $run / $runs"
        $quiet = ($run -gt 1)
        $runCode = Invoke-Tier2 -FixturePath $fixturePath -TimeoutSec $TimeoutSec -Quiet:$quiet
        if ($runCode -ne 0) {
            $code = $runCode
            break
        }
        if ($run -eq 1) { $firstText = $script:LastResultText }
        $hash = Get-CallLinesHash -CallLines $script:LastCallLines
        $hashes += $hash
        Write-Host "tier2: run $run recorded $($script:LastCallLines.Count) CALL line(s), sha256=$hash"
    }

    # (1) EXACT ordered projection-vs-recording assertion.
    if ($code -eq 0) {
        $code = Invoke-SequenceAssertion -FixturePath $fixturePath -ResultText $firstText -LuaExe $LuaExe
    }

    # (2) BYTE-IDENTICAL determinism across the consecutive runs.
    if ($code -eq 0) {
        $allEqual = $true
        for ($i = 1; $i -lt $hashes.Count; $i++) {
            if ($hashes[$i] -ne $hashes[0]) { $allEqual = $false }
        }
        Write-Host ""
        if ($allEqual) {
            Write-Host "=== DETERMINISM OK ($($hashes.Count) runs, byte-identical CALL lines) ===" -ForegroundColor Green
        }
        else {
            $code = Show-Failure 14 "recorded CALL lines were not byte-identical across $($hashes.Count) runs"
        }
    }
}

# ---------------------------------------------------------------------------
# Optional result capture (before the temp directory is deleted).
# ---------------------------------------------------------------------------
if ($CaptureResult -ne "" -and $script:LastResultText -ne "") {
    $capturePath = Resolve-ProjectPath $CaptureResult
    $captureDir  = Split-Path -Parent $capturePath
    if ($captureDir -ne "" -and -not (Test-Path -LiteralPath $captureDir)) {
        New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($capturePath, $script:LastResultText)
    Write-Host "captured result.txt -> $capturePath"
}

# ---------------------------------------------------------------------------
# Cleanup receipts and the zero-process assertion.
# ---------------------------------------------------------------------------
$temp = $script:TempDir
$tempGone = -not (Test-Path -LiteralPath $temp)
# Process teardown on Windows can lag a tick after WaitForExit; settle briefly
# before declaring a survivor.  A REAL leak persists well past this window.
$survivors = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*CraftOS*" })
for ($attempt = 0; $attempt -lt 5 -and $survivors.Count -ne 0; $attempt++) {
    Start-Sleep -Milliseconds 200
    $survivors = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*CraftOS*" })
}
Write-Host "temp dir removed: $tempGone ($temp)"
Write-Host "surviving CraftOS processes: $($survivors.Count)"

if (-not $tempGone) {
    $code = Show-Failure 10 "temp directory was not removed: $temp"
}
if ($survivors.Count -ne 0) {
    $code = Show-Failure 11 "a CraftOS process is still running: $($survivors.Name -join ', ')"
}

if ($code -eq 0) {
    Write-Host ""
    Write-Host "=== PASS: tier2 harness ok ($($script:CallCount) recorded call(s)) ===" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "=== FAIL: tier2 harness (exit $code) ===" -ForegroundColor Red
}

exit $code
