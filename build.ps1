<#
.SYNOPSIS
    Windows equivalent of the Makefile: build, clean, and smoke-test the statusline.

.EXAMPLE
    .\build.ps1            # cargo build --release   (same as `make`)
.EXAMPLE
    .\build.ps1 -Clean     # cargo clean             (same as `make clean`)
.EXAMPLE
    .\build.ps1 -Test      # build, then run cargo test + the smoke tests (same as `make test`)
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$Test
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# The binary emits UTF-8 (emoji) and ANSI escapes. Without this, a non-UTF-8 console
# code page mangles the emoji on capture and the flame assertions fail on encoding
# rather than on behavior.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = $PSScriptRoot
$Target = Join-Path $RepoRoot "target\release\claude_statusline.exe"

function Get-Cargo {
    $cmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # rustup edits the *user* PATH, which shells started before the install never see.
    $fallback = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
    if (Test-Path $fallback) { return $fallback }

    throw "cargo not found. Install the Rust toolchain from https://rustup.rs, then reopen your shell."
}

function Invoke-Build {
    $cargo = Get-Cargo
    & $cargo build --release --manifest-path (Join-Path $RepoRoot "Cargo.toml")
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
}

function Invoke-Clean {
    $cargo = Get-Cargo
    & $cargo clean --manifest-path (Join-Path $RepoRoot "Cargo.toml")
    if ($LASTEXITCODE -ne 0) { throw "cargo clean failed with exit code $LASTEXITCODE" }
}

# --- Smoke tests -------------------------------------------------------------
# Mirrors the `test` target in the Makefile. Keep the two in sync: the burn-rate
# thresholds are asserted here, in the Makefile, and defined in src/main.rs.

$script:Failures = 0
$ESC = [char]27

function Invoke-Statusline([string]$Json, [string[]]$Arguments = @()) {
    return ($Json | & $Target @Arguments | Out-String)
}

# Runs the binary with NO stdin attached and a hard timeout, so that a --version that
# blocks waiting on a pipe fails the run instead of hanging it forever. Returns exit code
# and stdout, or TimedOut.
function Invoke-NoStdin([string[]]$Arguments, [int]$TimeoutMs = 5000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Target
    foreach ($arg in $Arguments) { $psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    # WaitForExit before ReadToEnd, deliberately: ReadToEnd blocks until stdout closes, so
    # reading first would hang on the very case this guard exists to catch. Safe only
    # because the output is one short line, far under the pipe buffer.
    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill() } catch { }
        return @{ TimedOut = $true; Output = ""; ExitCode = -1 }
    }
    $out = $proc.StandardOutput.ReadToEnd()
    $code = $proc.ExitCode
    $proc.Dispose()
    return @{ TimedOut = $false; Output = $out; ExitCode = $code }
}

# Runs the binary from inside a throwaway directory holding a synthetic .git/HEAD. The
# branch is read relative to the working directory, so this is what makes the detached-HEAD
# path assertable without touching the real repo. $Target is absolute, so it still resolves.
function Invoke-StatuslineWithHead([string]$HeadContent, [string]$Json) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("statusline_head_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force (Join-Path $dir ".git") | Out-Null
    try {
        Set-Content (Join-Path $dir ".git\HEAD") $HeadContent -NoNewline
        Push-Location $dir
        try { return ($Json | & $Target | Out-String) } finally { Pop-Location }
    } finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-True([bool]$Condition, [string]$PassMessage, [string]$FailMessage) {
    if ($Condition) {
        Write-Host "PASS: $PassMessage"
    } else {
        Write-Host "FAIL: $FailMessage"
        $script:Failures++
    }
}

# Asserts that $Json produces output which does (or does not) contain $Needle.
# $PassMessage / $FailMessage are the Makefile's strings verbatim, so output is
# comparable across platforms.
function Assert-Output {
    param(
        [string]$Json,
        [string]$Needle,
        [bool]$ShouldContain,
        [string]$PassMessage,
        [string]$FailMessage
    )
    $output = Invoke-Statusline $Json
    if ($output.Contains($Needle) -eq $ShouldContain) {
        Write-Host "PASS: $PassMessage"
    } else {
        Write-Host "FAIL: $FailMessage"
        $script:Failures++
    }
}

function Invoke-Test {
    # Unit tests first: they cover the threshold boundaries the smoke assertions below can
    # only sample, and they fail in milliseconds without spawning a process per case.
    Write-Host "Running unit tests..."
    $cargo = Get-Cargo
    & $cargo test --quiet --manifest-path (Join-Path $RepoRoot "Cargo.toml")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: unit tests failed."
        exit 1
    }
    Write-Host ""

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $in1h = $now + 14400    # 1h elapsed into the 5h window
    $in7m = $now + 17580    # 7m elapsed, just past the 6m floor
    $in16m = $now + 17040   # 16m elapsed, inside the gap gate's suppression zone
    $in2h30 = $now + 9000
    $in5d = $now + 432000   # 2d elapsed into the 7d window

    # Write-Host, not bare output: returning to the pipeline would buffer every demo
    # to the end of the run instead of interleaving them with their headings.
    Write-Host "Testing basic functionality (line 1 only)..."
    Write-Host (Invoke-Statusline '{"model":{"display_name":"Claude 3.5 Sonnet"},"workspace":{"current_dir":"/home/user/my-project"}}')

    Write-Host "Testing with all fields (2 lines)..."
    Write-Host (Invoke-Statusline '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/home/user/project"},"context_window":{"used_percentage":42,"total_input_tokens":50000,"total_output_tokens":12000}}')

    Write-Host "Testing with current directory..."
    Write-Host (Invoke-Statusline ('{"model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"' + $RepoRoot.Replace('\', '\\') + '"},"context_window":{"used_percentage":75,"total_input_tokens":1200000,"total_output_tokens":300000}}'))

    Write-Host "Testing reasoning effort level..."
    Write-Host (Invoke-Statusline '{"model":{"display_name":"Opus"},"effort":{"level":"high"},"workspace":{"current_dir":"/home/user/project"}}')

    Write-Host "Testing clickable usage link on rate limit countdown..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":50,"total_input_tokens":1000,"total_output_tokens":500},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":' + $in2h30 + '}}}') `
        -Needle '8;;https://claude.ai/settings/usage' -ShouldContain $true `
        -PassMessage "usage link present" -FailMessage "usage link missing"

    Write-Host "Testing burn rate over budget (1h elapsed, 35% used = 35%/h)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":35,"resets_at":' + $in1h + '}}}') `
        -Needle "$([char]0xD83D)$([char]0xDD25)" -ShouldContain $true `
        -PassMessage "flame shown over 28%/h" -FailMessage "flame missing"

    Write-Host "Testing burn rate on budget (1h elapsed, 10% used = 10%/h)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":' + $in1h + '}}}') `
        -Needle "$([char]0xD83D)$([char]0xDD25)" -ShouldContain $false `
        -PassMessage "no flame under 28%/h" -FailMessage "unexpected flame"

    Write-Host "Testing yellow band has no flame (1h elapsed, 27% used = 1.35x)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":27,"resets_at":' + $in1h + '}}}') `
        -Needle "$([char]0xD83D)$([char]0xDD25)" -ShouldContain $false `
        -PassMessage "27%/h is yellow without flame" -FailMessage "flame too early in yellow band"

    Write-Host "Testing exactly-on-budget does not warn (1h elapsed, 20% used = 20%/h)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":' + $in1h + '}}}') `
        -Needle "$ESC[33m" -ShouldContain $false `
        -PassMessage "on-budget stays plain" -FailMessage "on-budget should not be yellow"

    Write-Host "Testing over-budget warns (1h elapsed, 24% used = 24%/h)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":' + $in1h + '}}}') `
        -Needle "$ESC[33m" -ShouldContain $true `
        -PassMessage "yellow at 24%/h" -FailMessage "missing yellow"

    Write-Host "Testing red threshold (1h elapsed, 40% used = 2.00x)..."
    $red = '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":' + $in1h + '}}}'
    Assert-Output -Json $red -Needle "$ESC[31m" -ShouldContain $true `
        -PassMessage "red at 2.00x" -FailMessage "missing red"
    Assert-Output -Json $red -Needle "dry in" -ShouldContain $true `
        -PassMessage "dry-in shown at red" -FailMessage "dry-in missing"

    Write-Host "Testing 1.50x is no longer red (1h elapsed, 30% used)..."
    $yellow = '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":' + $in1h + '}}}'
    Assert-Output -Json $yellow -Needle "$ESC[31m" -ShouldContain $false `
        -PassMessage "1.50x stays yellow" -FailMessage "1.50x should be yellow"
    Assert-Output -Json $yellow -Needle "dry in" -ShouldContain $false `
        -PassMessage "no dry-in below red" -FailMessage "dry-in below red"

    Write-Host "Testing the gap gate surfaces an early overspend (7m elapsed, 5% used = 2.14x)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":' + $in7m + '}}}') `
        -Needle "dry in" -ShouldContain $true `
        -PassMessage "red 7m in, once past the 6m floor" -FailMessage "early overspend still blacked out"

    Write-Host "Testing sub-point drift stays plain (16m elapsed, 6.3% used = 1.18x, gap 0.97)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":6.3,"resets_at":' + $in16m + '}}}') `
        -Needle "$ESC[33m" -ShouldContain $false `
        -PassMessage "1.18x under the gap stays plain" -FailMessage "under a point of lead should not warn"

    Write-Host "Testing 7d never shows a burn flame (2d elapsed, 45% used)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"seven_day":{"used_percentage":45,"resets_at":' + $in5d + '}}}') `
        -Needle "$([char]0xD83D)$([char]0xDD25)" -ShouldContain $false `
        -PassMessage "7d has no pace cue" -FailMessage "7d should not flag pace"

    # Code points, not literals, matching the flame assertions above — they all rely
    # on the UTF-8 capture forced at the top of this file. 💾 is astral so it needs a
    # surrogate pair; ⏳ and ⚡ are BMP and take a single char.
    $Floppy = "$([char]0xD83D)$([char]0xDCBE)"
    $Hourglass = "$([char]0x23F3)"
    $Bolt = "$([char]0x26A1)"

    Write-Host "Testing healthy cache ratio is uncolored (60% context, 95k read / 5k write)..."
    Assert-Output `
        -Json '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":{"cache_read_input_tokens":95000,"cache_creation_input_tokens":5000}}}' `
        -Needle "| $Floppy 95%" -ShouldContain $true `
        -PassMessage "cache 95% shown plain" -FailMessage "cache ratio missing or colored"

    Write-Host "Testing cache miss is red (60% context, 20k read / 80k write)..."
    Assert-Output `
        -Json '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":{"cache_read_input_tokens":20000,"cache_creation_input_tokens":80000}}}' `
        -Needle "$ESC[31m$Floppy 20%" -ShouldContain $true `
        -PassMessage "red at 20% hit rate" -FailMessage "missing red on cache miss"

    Write-Host "Testing cache indicator hidden below the context floor (10% context)..."
    Assert-Output `
        -Json '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":10,"current_usage":{"cache_read_input_tokens":20000,"cache_creation_input_tokens":80000}}}' `
        -Needle $Floppy -ShouldContain $false `
        -PassMessage "no cache cue under 30% context" -FailMessage "cold start should not flag a miss"

    Write-Host "Testing cache indicator hidden when current_usage is null (post-/compact)..."
    Assert-Output `
        -Json '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":null}}' `
        -Needle $Floppy -ShouldContain $false `
        -PassMessage "no cache cue without usage" -FailMessage "null usage should render nothing"

    Write-Host "Testing session age warns and shows activity (5h02m wall, 5m API)..."
    $longSession = '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_duration_ms":18120000,"total_api_duration_ms":300000}}'
    Assert-Output -Json $longSession -Needle "$ESC[33m5h02m" -ShouldContain $true `
        -PassMessage "yellow age past 4h" -FailMessage "missing yellow age"
    Assert-Output -Json $longSession -Needle "${Bolt}2%" -ShouldContain $true `
        -PassMessage "activity shown on long session" -FailMessage "activity missing"

    Write-Host "Testing a short session shows age but no activity (10m wall)..."
    $shortSession = '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_duration_ms":600000,"total_api_duration_ms":120000}}'
    Assert-Output -Json $shortSession -Needle "$Hourglass 10m" -ShouldContain $true `
        -PassMessage "10m age shown plain" -FailMessage "age missing"
    Assert-Output -Json $shortSession -Needle $Bolt -ShouldContain $false `
        -PassMessage "no activity cue under 1h" -FailMessage "activity meaningless under 1h"

    Write-Host "Testing activity clamps at 100% (parallel subagents sum past wall clock)..."
    Assert-Output `
        -Json '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_duration_ms":7200000,"total_api_duration_ms":18000000}}' `
        -Needle "${Bolt}100%" -ShouldContain $true `
        -PassMessage "activity clamped to 100%" -FailMessage "activity exceeded 100%"

    # --- Detached HEAD ----------------------------------------------------------
    $headJson = '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}'
    $Herb = "$([char]0xD83C)$([char]0xDF3F)"

    Write-Host "Testing a detached HEAD shows the short SHA..."
    Assert-True ((Invoke-StatuslineWithHead "1234567890abcdef1234567890abcdef12345678" $headJson).Contains("@1234567")) `
        "detached HEAD shows @1234567" "detached HEAD did not render the short SHA"

    Write-Host "Testing a worktree gitdir pointer renders no branch..."
    Assert-True (-not (Invoke-StatuslineWithHead "gitdir: /some/worktree/path" $headJson).Contains($Herb)) `
        "gitdir pointer stays silent" "gitdir pointer rendered a branch"

    Write-Host "Testing a normal ref still renders the branch name..."
    Assert-True ((Invoke-StatuslineWithHead "ref: refs/heads/some-branch" $headJson).Contains("some-branch")) `
        "ref renders branch name" "ref did not render the branch name"

    # --- Version ----------------------------------------------------------------
    # Mirrors the --version block in the Makefile. Every call here runs with stdin
    # closed, which is the regression that matters: the arg check has to happen before
    # the stdin read or --version blocks forever on a pipe that never arrives.

    Write-Host "Testing --version prints name, semver and build SHA..."
    $ver = Invoke-NoStdin @("--version")
    Assert-True (-not $ver.TimedOut) "returns without stdin" "--version blocked waiting on stdin"
    Assert-True ($ver.Output.Trim() -match '^claude_statusline \d+\.\d+\.\d+ \(.+\)$') `
        "version format" "bad version format: '$($ver.Output.Trim())'"

    Write-Host "Testing --version exits 0..."
    Assert-True ($ver.ExitCode -eq 0) "exit 0" "non-zero exit: $($ver.ExitCode)"

    Write-Host "Testing -V matches --version..."
    $short = Invoke-NoStdin @("-V")
    Assert-True (-not $short.TimedOut) "-V returns without stdin" "-V blocked waiting on stdin"
    Assert-True ($short.Output -ceq $ver.Output) "-V is an alias" "-V differs from --version"

    # Compares against the no-arg run rather than grepping for a needle: the dir basename
    # is wrapped in a color escape ("\e[36mtmp"), so "unknown arg renders identically" is
    # both easier to assert and a stronger claim than any substring match.
    Write-Host "Testing an unrecognized argument still renders a statusline..."
    $strayJson = '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}'
    Assert-True ((Invoke-Statusline $strayJson @("--not-a-flag")) -ceq (Invoke-Statusline $strayJson)) `
        "unknown arg ignored" "unknown arg changed the output"

    Write-Host ""
    if ($script:Failures -gt 0) {
        # Unlike the Makefile, a failing assertion fails the run.
        Write-Host "$script:Failures test(s) failed."
        exit 1
    }
    Write-Host "All tests passed."
}

# --- Entry point -------------------------------------------------------------

if ($Clean) {
    Invoke-Clean
    return
}

Invoke-Build

if ($Test) {
    Invoke-Test
}
