<#
.SYNOPSIS
    Windows equivalent of the Makefile: build, clean, and smoke-test the statusline.

.EXAMPLE
    .\build.ps1            # cargo build --release   (same as `make`)
.EXAMPLE
    .\build.ps1 -Clean     # cargo clean             (same as `make clean`)
.EXAMPLE
    .\build.ps1 -Test      # build, then run the smoke tests (same as `make test`)
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

function Invoke-Statusline([string]$Json) {
    return ($Json | & $Target | Out-String)
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
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $in1h = $now + 14400    # 1h elapsed into the 5h window
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

    Write-Host "Testing 7d never shows a burn flame (2d elapsed, 45% used)..."
    Assert-Output `
        -Json ('{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"seven_day":{"used_percentage":45,"resets_at":' + $in5d + '}}}') `
        -Needle "$([char]0xD83D)$([char]0xDD25)" -ShouldContain $false `
        -PassMessage "7d has no pace cue" -FailMessage "7d should not flag pace"

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
