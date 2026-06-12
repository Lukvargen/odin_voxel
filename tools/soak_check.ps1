param([int]$ProcId, [int]$Iterations = 10, [int]$IntervalSec = 30)
# Periodically screenshots the game window and reports whether the scene
# region is entirely black (the bug signature) or still rendering.
$cap = Join-Path $PSScriptRoot "capture_window.ps1"
$tmp = Join-Path $PSScriptRoot "soak_frame.png"
Add-Type -AssemblyName System.Drawing
for ($i = 0; $i -lt $Iterations; $i++) {
    Start-Sleep -Seconds $IntervalSec
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if ($null -eq $p) { Write-Output "iter ${i}: PROCESS_EXITED"; exit 1 }
    & $cap -ProcId $ProcId -OutPath $tmp -DelayMs 100 | Out-Null
    $bmp = [System.Drawing.Bitmap]::FromFile($tmp)
    $lit = 0
    foreach ($pt in @(@(400,300), @(200,500), @(600,400), @(300,700), @(700,250), @(120,350))) {
        $c = $bmp.GetPixel($pt[0], $pt[1])
        if (($c.R + $c.G + $c.B) -gt 6) { $lit++ }
    }
    $bmp.Dispose()
    Write-Output "iter ${i}: lit_samples=$lit/6"
}
Write-Output "SOAK_DONE"
