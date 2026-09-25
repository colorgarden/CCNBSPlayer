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
#   powershell -File tests/tier2/run.ps1 -Assert                 # future: require STATUS ok only
#   powershell -File tests/tier2/run.ps1 -Assert -ExpectedFile tests/tier2/expected/v4.txt
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

    # Re-stated: passing -Assert requires the run to be a clean success.  A
    # future task can pass -ExpectedFile to compare the recorded call sequence.
    [switch]$Assert,

    [string]$ExpectedFile = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$ConsoleExe  = "D:\tools\CraftOS-PC\CraftOS-PC_console.exe"
$ScriptFile  = Join-Path $ScriptDir "record.lua"

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
        [string]$ExpectedFile
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
        Write-Host "emulator exit code: $emuExit"

        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            return Show-Failure 4 "result.txt was not written at $resultPath"
        }

        $resultText = Get-Content -LiteralPath $resultPath -Raw
        Write-Host "----- result.txt -----"
        Write-Host $resultText
        Write-Host "----------------------"

        $lines     = @($resultText -split "\r?\n" | Where-Object { $_ -ne "" })
        $callLines = @($lines | Where-Object { $_ -like "CALL *" })
        $status    = if ($lines.Count -gt 0) { $lines[$lines.Count - 1] } else { "" }
        $script:CallCount = $callLines.Count

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

$script:CallCount = 0
$fixturePath = Resolve-ProjectPath $Fixture
Write-Host "tier2: fixture = $fixturePath"
Write-Host "tier2: timeout = ${TimeoutSec}s"

$code = Invoke-Tier2 -FixturePath $fixturePath -TimeoutSec $TimeoutSec -Assert:$Assert -ExpectedFile $ExpectedFile

# ---------------------------------------------------------------------------
# Cleanup receipts and the zero-process assertion.
# ---------------------------------------------------------------------------
$temp = $script:TempDir
$tempGone = -not (Test-Path -LiteralPath $temp)
$survivors = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*CraftOS*" })
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
