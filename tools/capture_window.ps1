param(
    [int]$ProcId,
    [string]$OutPath,
    [int]$DelayMs = 500,
    [switch]$Focus
)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Cap {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
Add-Type -AssemblyName System.Drawing
$p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
if ($null -eq $p) { Write-Output "PROCESS_EXITED"; exit 1 }
$h = $p.MainWindowHandle
if ($Focus) { [Win32Cap]::SetForegroundWindow($h) | Out-Null }
Start-Sleep -Milliseconds $DelayMs
$r = New-Object Win32Cap+RECT
[Win32Cap]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$hh = $r.Bottom - $r.Top
if ($w -le 0 -or $hh -le 0) { Write-Output "BAD_RECT $w x $hh"; exit 1 }
$bmp = New-Object System.Drawing.Bitmap($w, $hh)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save($OutPath)
$g.Dispose(); $bmp.Dispose()
Write-Output "captured ${w}x${hh} -> $OutPath"
