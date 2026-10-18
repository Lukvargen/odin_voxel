# Rebuilds the game and restarts the entity sandbox (sandbox.odin) whenever a
# .odin file is saved, so a change to a model or an animation shows in a few
# seconds. The sandbox comes back to the same view (saves/sandbox.txt), and
# after the first start its window doesn't take the keyboard from the editor.
#
#   tools\sandbox_watch.ps1 [-Creature goblin] [-Anim chop]
#
# A debug build (~1 s; an optimized one takes ~20) goes to sandbox_next.exe;
# only if it builds is the running sandbox stopped and the new one put in
# its place, so a broken build leaves the last good one running (and prints
# why). Always the same sandbox.exe: the GPU driver caches the compiled
# shaders per executable path, and a path it hasn't seen costs ~35 s on its
# first start (as does any change to the shaders).
#
# The game's own output goes to saves/sandbox.log. Shaders (.hlsl) aren't
# watched: build.bat compiles those. Ctrl+C stops it.
param([string]$Creature = "", [string]$Anim = "")

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$script:proc = $null
$script:first = $true

function Restart-Sandbox {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $out = & odin build . -debug "-out:sandbox_next.exe" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($out | Out-String) -ForegroundColor Red
        Write-Host "Build failed: the sandbox keeps running the last good build." -ForegroundColor Yellow
        return
    }
    if ($script:proc -and -not $script:proc.HasExited) {
        $script:proc.Kill()
        $script:proc.WaitForExit()
    }
    Move-Item -Force sandbox_next.exe sandbox.exe
    # The creature and animation asked for only the first time: after that
    # the sandbox keeps whatever was picked in it.
    $argv = @("sandbox")
    if ($script:first -and $Creature) { $argv += $Creature }
    if ($script:first -and $Anim) { $argv += "anim=$Anim" }
    if (-not $script:first) { $argv += "nofocus" }
    New-Item -ItemType Directory -Force saves | Out-Null
    $script:proc = Start-Process -FilePath (Join-Path $root "sandbox.exe") -ArgumentList $argv -NoNewWindow -PassThru -RedirectStandardOutput "saves\sandbox.log"
    $script:first = $false
    Write-Host ("{0:HH:mm:ss}  built in {1:N1} s, sandbox restarted" -f (Get-Date), $clock.Elapsed.TotalSeconds) -ForegroundColor Green
}

# The newest .odin file and its time, and how many there are (one gone or
# added is a change too). Polled: a FileSystemWatcher's waits miss changes.
function Get-Sources {
    $files = Get-ChildItem -Path $root -Filter *.odin -File
    $newest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    return "$($files.Count) $($newest.Name) $($newest.LastWriteTimeUtc.Ticks)"
}

try {
    Restart-Sandbox
    Write-Host "Watching *.odin; Ctrl+C stops."
    $seen = Get-Sources
    while ($true) {
        Start-Sleep -Milliseconds 300
        $now = Get-Sources
        if ($now -eq $seen) { continue }
        # Editors (and Claude) save in bursts: wait for it to go quiet.
        do { $seen = $now; Start-Sleep -Milliseconds 300; $now = Get-Sources } while ($now -ne $seen)
        Write-Host "$(($now -split ' ')[1]) changed"
        Restart-Sandbox
    }
} finally {
    if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill() }
}
