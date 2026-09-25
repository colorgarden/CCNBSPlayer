# tests/tier2/edge_cases.ps1
#
# TIER-2 FAILURE / EDGE-CASE SPECS -- the HOST-DRIVEN (emulator) half.
#
# Runs the five required failure/edge cases through the real Tier-2 harness
# (tests/tier2/run.ps1 + record.lua) inside CraftOS-PC and asserts the recorded
# evidence.  The projector-level half -- cases that can be decided without the
# emulator -- lives in tests/tier2/failure_spec.lua and runs under
# `lua tests/run.lua`.
#
# Each harness invocation captures result.txt via run.ps1 -CaptureResult, so the
# assertions read the RAW file channel (never stdout) and inspect the child's
# real exit code.
#
# THE FIVE CASES
#   1. capacity_10.nbs + 2 speakers  -> balanced split, dropped 0 (emulator)
#   2. capacity_10.nbs + 1 speaker   -> 2 dropped tones + WARN[speakers] (emulator)
#   3. tests/corpus/malformed/*.nbs  -> non-zero exit + typed code, no hang (emulator)
#   4. compat_demo_song.nbs (in range) -> ZERO WARN[extended-range] (emulator);
#      the once-only extended-range assertion itself is projector-only because
#      the only extended-range fixture (simple.nbs, min_key 27) cannot be played
#      by the emulator's 0..24 pitch restriction (docs/COMPAT.md).
#   5. custom_mix.nbs                -> custom note: 0 calls + 1 WARN; vanilla plays (emulator)
#
# Usage (from the repository root):
#   powershell -ExecutionPolicy Bypass -File tests/tier2/edge_cases.ps1
#   powershell -ExecutionPolicy Bypass -File tests/tier2/edge_cases.ps1 -DeterminismRuns 10

[CmdletBinding()]
param(
    [int]$DeterminismRuns = 2,
    [string]$LuaExe = "lua"
)

$ErrorActionPreference = "Continue"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$RunPs1      = Join-Path $ScriptDir "run.ps1"

$Scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("ccnbs-tier2-edge-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Scratch -Force | Out-Null

$script:PassCount = 0
$script:Failures  = @()

function Assert-Case {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        Write-Host "PASS $Name" -ForegroundColor Green
        $script:PassCount++
    }
    else {
        Write-Host "FAIL $Name -- $Detail" -ForegroundColor Red
        $script:Failures += "$Name ($Detail)"
    }
}

function Count-Match {
    param([string]$Text, [string]$Pattern)
    return ([regex]::Matches($Text, $Pattern)).Count
}

# Playback calls only: the recorded file also carries the three discovery lines
# (getNames/getType/wrap), which are setup, not playback.
function Count-PlaybackCalls {
    param([string]$Text)
    return (Count-Match $Text "(?m)^CALL \S+ (?:playNote|playSound|stop)\b")
}

# Invoke-Harness: one bounded run.ps1 run, returning its exit code and the RAW
# result.txt text captured through run.ps1 -CaptureResult.
function Invoke-Harness {
    param(
        [string]$Fixture,
        [string]$Sides = "back",
        [switch]$Assert,
        [int]$Runs = 2
    )
    $capture = Join-Path $Scratch ("result-" + [guid]::NewGuid().ToString("N") + ".txt")
    $log     = Join-Path $Scratch ("log-" + [guid]::NewGuid().ToString("N") + ".txt")

    $childArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RunPs1,
        "-Fixture", $Fixture,
        "-SpeakerSides", $Sides,
        "-CaptureResult", $capture,
        "-LuaExe", $LuaExe
    )
    if ($Assert) {
        $childArgs += @("-Assert", "-DeterminismRuns", "$Runs")
    }

    # run.ps1 owns the native-process handling; we only capture ITS own output
    # to a log file (never a live truncate-pipe).
    & powershell @childArgs *> $log
    $code = $LASTEXITCODE

    $text = ""
    if (Test-Path -LiteralPath $capture) {
        # UTF-8 explicitly: PS 5.1's Get-Content defaults to ANSI and would
        # corrupt the WARN[...] Chinese (and possibly swallow a newline).
        $text = [System.IO.File]::ReadAllText($capture, [System.Text.Encoding]::UTF8)
    }
    return [pscustomobject]@{ ExitCode = $code; Result = $text; Log = $log }
}

Write-Host "tier2 edge cases: determinism runs = $DeterminismRuns"
Write-Host "tier2 edge cases: scratch = $Scratch"
Write-Host ""

# ---------------------------------------------------------------------------
# CASE 1: capacity overflow resolved by two speakers (emulator-verified)
# ---------------------------------------------------------------------------
Write-Host "--- CASE 1: capacity_10.nbs, TWO speakers (back,left) ---"
$case1 = Invoke-Harness -Fixture "tests/tier2/fixtures/capacity_10.nbs" -Sides "back,left" -Assert -Runs $DeterminismRuns
Assert-Case "case1 harness exit 0 (projection + determinism)" ($case1.ExitCode -eq 0) "exit=$($case1.ExitCode)"
Assert-Case "case1 ASSIGN required=2 found=2 dropped=0 warning=-" `
    ($case1.Result -match "(?m)^ASSIGN required=2 found=2 dropped=0 warning=-$")
Assert-Case "case1 SPLIT back 5" ($case1.Result -match "(?m)^SPLIT back 5$")
Assert-Case "case1 SPLIT left 5" ($case1.Result -match "(?m)^SPLIT left 5$")
Assert-Case "case1 ten recorded playback CALL lines" ((Count-PlaybackCalls $case1.Result) -eq 10) `
    "calls=$(Count-PlaybackCalls $case1.Result)"
Assert-Case "case1 no DROPPED lines" ((Count-Match $case1.Result "(?m)^DROPPED ") -eq 0)
Assert-Case "case1 no WARN[speakers] line" ((Count-Match $case1.Result "WARN\[speakers\]") -eq 0)
Write-Host "case1 result.txt:"
Write-Host $case1.Result
Write-Host ""

# ---------------------------------------------------------------------------
# CASE 2: same fixture, ONE speaker, deterministic degradation (emulator)
# ---------------------------------------------------------------------------
Write-Host "--- CASE 2: capacity_10.nbs, ONE speaker (back) ---"
$case2 = Invoke-Harness -Fixture "tests/tier2/fixtures/capacity_10.nbs" -Sides "back" -Assert -Runs $DeterminismRuns
Assert-Case "case2 harness exit 0 (projection + determinism)" ($case2.ExitCode -eq 0) "exit=$($case2.ExitCode)"
Assert-Case "case2 ASSIGN required=2 found=1 dropped=2 warning=speakers" `
    ($case2.Result -match "(?m)^ASSIGN required=2 found=1 dropped=2 warning=speakers$")
Assert-Case "case2 WARGS peak=10 required=2 found=1 dropped=2" `
    ($case2.Result -match "(?m)^WARGS peak=10 required=2 found=1 dropped=2$")
Assert-Case "case2 SPLIT back 8" ($case2.Result -match "(?m)^SPLIT back 8$")
Assert-Case "case2 eight recorded playback CALL lines" ((Count-PlaybackCalls $case2.Result) -eq 8) `
    "calls=$(Count-PlaybackCalls $case2.Result)"
Assert-Case "case2 drops layer 8 first" `
    ($case2.Result -match "(?m)^DROPPED tick=0 layer=8 note=1 kind=play_note$")
Assert-Case "case2 drops layer 9 second" `
    ($case2.Result -match "(?m)^DROPPED tick=0 layer=9 note=1 kind=play_note$")
Assert-Case "case2 WARN[speakers] exactly once" ((Count-Match $case2.Result "WARN\[speakers\]") -eq 1) `
    "count=$(Count-Match $case2.Result 'WARN\[speakers\]')"
Write-Host "case2 result.txt:"
Write-Host $case2.Result
Write-Host ""

# ---------------------------------------------------------------------------
# CASE 3: every malformed corpus file -> non-zero exit + typed code, no hang
# ---------------------------------------------------------------------------
Write-Host "--- CASE 3: malformed corpus (non-zero exit, typed code, no hang) ---"
$Malformed = @(
    [pscustomobject]@{ Name = "empty.nbs";                  Code = "E_TRUNCATED" },
    [pscustomobject]@{ Name = "one_byte.nbs";               Code = "E_TRUNCATED" },
    [pscustomobject]@{ Name = "truncated_header.nbs";       Code = "E_TRUNCATED" },
    [pscustomobject]@{ Name = "version_9.nbs";              Code = "E_UNSUPPORTED_VERSION" },
    [pscustomobject]@{ Name = "negative_tick_jump.nbs";     Code = "E_BAD_JUMP" },
    [pscustomobject]@{ Name = "layer_overflow.nbs";         Code = "E_LAYER_OVERFLOW" },
    [pscustomobject]@{ Name = "absurd_layer_count.nbs";     Code = "E_BAD_LAYER_COUNT" },
    [pscustomobject]@{ Name = "negative_layer_count.nbs";   Code = "E_BAD_LAYER_COUNT" },
    [pscustomobject]@{ Name = "max_unsigned_layer_count.nbs"; Code = "E_BAD_LAYER_COUNT" },
    [pscustomobject]@{ Name = "absurd_instrument_count.nbs"; Code = "E_BAD_INSTRUMENT_COUNT" },
    [pscustomobject]@{ Name = "truncated_notes.nbs";        Code = "E_TRUNCATED" },
    [pscustomobject]@{ Name = "cyclic_jumps.nbs";           Code = "E_TOO_MANY_TICKS" },
    [pscustomobject]@{ Name = "truncated_layers.nbs";       Code = "E_TRUNCATED" },
    [pscustomobject]@{ Name = "huge_declared_string.nbs";   Code = "E_TRUNCATED" }
)

$malformedRows = @()
foreach ($entry in $Malformed) {
    $r = Invoke-Harness -Fixture ("tests/corpus/malformed/" + $entry.Name) -Sides "back"
    $statusMatch = [regex]::Match($r.Result, "(?m)^STATUS (.*)$")
    $statusText = if ($statusMatch.Success) { $statusMatch.Groups[1].Value } else { "(no STATUS line)" }

    $notHanging = ($r.ExitCode -ne 3)
    $typedCode  = ($statusText -like ("fail:*" + $entry.Code + "*"))
    $nonZero    = ($r.ExitCode -ne 0)
    $cleanFail  = ($statusText -like "fail:*")

    Assert-Case ("case3 " + $entry.Name + " non-zero exit") $nonZero "exit=$($r.ExitCode)"
    Assert-Case ("case3 " + $entry.Name + " no timeout/hang") $notHanging "exit=$($r.ExitCode)"
    Assert-Case ("case3 " + $entry.Name + " clean STATUS fail:<reason>") $cleanFail "status=$statusText"
    Assert-Case ("case3 " + $entry.Name + " carries " + $entry.Code) $typedCode "status=$statusText"

    $malformedRows += [pscustomobject]@{
        File   = $entry.Name
        Code   = $entry.Code
        Exit   = $r.ExitCode
        Status = $statusText
    }
}
Write-Host ""
Write-Host "case3 per-file code table:"
$malformedRows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ""

# ---------------------------------------------------------------------------
# CASE 4 (emulator half): in-range fixture -> ZERO extended-range warnings
# ---------------------------------------------------------------------------
Write-Host "--- CASE 4: compat_demo_song.nbs (in range) -> zero WARN[extended-range] ---"
$case4 = Invoke-Harness -Fixture "tests/fixtures/compat_demo_song.nbs" -Sides "back" -Assert -Runs $DeterminismRuns
Assert-Case "case4 harness exit 0" ($case4.ExitCode -eq 0) "exit=$($case4.ExitCode)"
Assert-Case "case4 recorded some playback CALL lines" ((Count-PlaybackCalls $case4.Result) -gt 0)
Assert-Case "case4 ZERO WARN[extended-range] lines" ((Count-Match $case4.Result "WARN\[extended-range\]") -eq 0) `
    "count=$(Count-Match $case4.Result 'WARN\[extended-range\]')"
Write-Host "case4 WARN[extended-range] count = $(Count-Match $case4.Result 'WARN\[extended-range\]')"
Write-Host ""

# ---------------------------------------------------------------------------
# CASE 5: custom instruments are refused (emulator-verified)
# ---------------------------------------------------------------------------
Write-Host "--- CASE 5: custom_mix.nbs -> custom refused, vanilla plays ---"
$case5 = Invoke-Harness -Fixture "tests/tier2/fixtures/custom_mix.nbs" -Sides "back" -Assert -Runs $DeterminismRuns
Assert-Case "case5 harness exit 0 (projection + determinism)" ($case5.ExitCode -eq 0) "exit=$($case5.ExitCode)"
Assert-Case "case5 exactly two playback CALL lines (vanilla only)" ((Count-PlaybackCalls $case5.Result) -eq 2) `
    "calls=$(Count-PlaybackCalls $case5.Result)"
Assert-Case "case5 harp (vanilla) plays" ($case5.Result -match "(?m)^CALL back playNote harp 3 12$")
Assert-Case "case5 bass (vanilla) plays" ($case5.Result -match "(?m)^CALL back playNote bass 3 12$")
Assert-Case "case5 zero CALL lines naming a custom instrument" ((Count-Match $case5.Result "(?m)^CALL .*custom") -eq 0)
Assert-Case "case5 WARN[custom-instrument] exactly once" ((Count-Match $case5.Result "WARN\[custom-instrument\]") -eq 1) `
    "count=$(Count-Match $case5.Result 'WARN\[custom-instrument\]')"
Write-Host "case5 result.txt:"
Write-Host $case5.Result
Write-Host ""

# ---------------------------------------------------------------------------
# Cleanup receipts and zero-process assertion
# ---------------------------------------------------------------------------
$survivors = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*CraftOS*" })
Assert-Case "no surviving CraftOS process" ($survivors.Count -eq 0) "survivors=$($survivors.Count)"

if (Test-Path -LiteralPath $Scratch) {
    Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue
}
$scratchGone = -not (Test-Path -LiteralPath $Scratch)
Assert-Case "scratch directory removed" $scratchGone "path=$Scratch"

Write-Host ""
if ($script:Failures.Count -eq 0) {
    Write-Host "=== PASS: tier2 edge cases ($($script:PassCount) assertions) ===" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "=== FAIL: tier2 edge cases ($($script:Failures.Count) failure(s)) ===" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}
