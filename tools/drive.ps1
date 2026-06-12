# Sends a sequence of input actions to the odin_raytrace window.
# Usage: drive.ps1 -Actions "tab,500;mouse,0,-250;ctrl,500;key,35;ldown;lup;sleep,1000"
# Actions (semicolon-separated):
#   tab[,ms]       - tap Tab then sleep ms
#   key,HEXVK      - tap virtual key (hex, e.g. 35 = '5')
#   keyhold,HEXVK,ms - hold key for ms
#   ctrl,ms        - hold Ctrl for ms
#   mouse,dx,dy    - relative mouse move
#   ldown / lup / rdown / rup - mouse buttons
#   click,ms       - left click held ms
#   rclick,ms      - right click held ms
#   sleep,ms       - just wait
param([string]$Actions = "")
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class DrvNative {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    // Foreground-lock workaround: attach our thread's input queue to the
    // current foreground thread, then the OS allows SetForegroundWindow.
    public static bool ForceForeground(IntPtr h) {
        IntPtr fg = GetForegroundWindow();
        if (fg == h) return true;
        uint fgPid; uint fgTid = GetWindowThreadProcessId(fg, out fgPid);
        uint me = GetCurrentThreadId();
        AttachThreadInput(me, fgTid, true);
        bool ok = SetForegroundWindow(h);
        AttachThreadInput(me, fgTid, false);
        if (!ok) { ShowWindow(h, 6); ShowWindow(h, 9); ok = SetForegroundWindow(h); } // minimize+restore fallback
        return ok;
    }
}
'@
# Prefer the SDL window by class: when the app is launched detached, the
# process MainWindowHandle can be its console window instead.
$h = [DrvNative]::FindWindow("SDL_app", $null)
if ($h -eq [IntPtr]::Zero) {
    $p = Get-Process odin_raytrace | Select-Object -First 1
    $h = $p.MainWindowHandle
}
$fok = [DrvNative]::ForceForeground($h)
if (-not $fok) { Write-Output "WARN: could not take foreground" }
Start-Sleep -Milliseconds 400

function Tap([byte]$vk) {
    [DrvNative]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [DrvNative]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
}

foreach ($act in $Actions.Split(';')) {
    $parts = $act.Trim().Split(',')
    switch ($parts[0]) {
        "tab"     { Tap 0x09; if ($parts.Length -gt 1) { Start-Sleep -Milliseconds ([int]$parts[1]) } }
        "key"     { Tap ([byte][Convert]::ToInt32($parts[1], 16)) }
        "keyhold" { $vk = [byte][Convert]::ToInt32($parts[1], 16); [DrvNative]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds ([int]$parts[2]); [DrvNative]::keybd_event($vk, 0, 2, [UIntPtr]::Zero) }
        "ctrl"    { [DrvNative]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds ([int]$parts[1]); [DrvNative]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
        "ctrldown" { [DrvNative]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero) }
        "ctrlup"   { [DrvNative]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) }
        "wheel"    { [DrvNative]::mouse_event(0x0800, 0, 0, ([int]$parts[1]) * 120, [UIntPtr]::Zero) }
        "mouse"   { [DrvNative]::mouse_event(0x0001, [int]$parts[1], [int]$parts[2], 0, [UIntPtr]::Zero) }
        "ldown"   { [DrvNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) }
        "lup"     { [DrvNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) }
        "rdown"   { [DrvNative]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero) }
        "rup"     { [DrvNative]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero) }
        "click"   { [DrvNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds ([int]$parts[1]); [DrvNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) }
        "rclick"  { [DrvNative]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds ([int]$parts[1]); [DrvNative]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero) }
        "sleep"   { Start-Sleep -Milliseconds ([int]$parts[1]) }
        default   { }
    }
    Start-Sleep -Milliseconds 120
}
Write-Output "done"
