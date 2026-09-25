# Drives darger.exe with PostMessage key events (no focus needed) and screenshots each step.
# Usage: powershell -File testsdrive.ps1 <workdir> <file>   (ASCII only: PS 5.1 reads BOM-less files as ANSI)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public struct RECT { public int L, T, R, B; }
public class W {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  static void Ev(IntPtr h, ushort vk, bool up, bool ext) {
    uint sc = MapVirtualKey(vk, 0);
    long l = (sc << 16) | 1 | (ext ? (1L << 24) : 0) | (up ? (3L << 30) : 0);
    PostMessage(h, up ? 0x0101u : 0x0100u, (IntPtr)vk, (IntPtr)l);
  }
  public static void Chord(IntPtr h, int mods, ushort vk, bool ext) {
    if ((mods & 1) != 0) Ev(h, 0xA2, false, false); if ((mods & 2) != 0) Ev(h, 0xA4, false, false); if ((mods & 4) != 0) Ev(h, 0xA0, false, false);
    Ev(h, vk, false, ext); Ev(h, vk, true, ext); System.Threading.Thread.Sleep(120);
    if ((mods & 4) != 0) Ev(h, 0xA0, true, false); if ((mods & 2) != 0) Ev(h, 0xA4, true, false); if ((mods & 1) != 0) Ev(h, 0xA2, true, false);
    System.Threading.Thread.Sleep(80);
  }
  public static void Text(IntPtr h, string s) {
    foreach (char c in s) { PostMessage(h, 0x0102u, (IntPtr)c, (IntPtr)1); }
    System.Threading.Thread.Sleep(80);
  }
}
"@
function K([string]$spec) {
  $mods = 0; $parts = $spec.Split('-'); $name = $parts[-1]
  if ($parts.Length -gt 1) { foreach ($m in $parts[0..($parts.Length-2)]) { if ($m -eq 'C') {$mods = $mods -bor 1}; if ($m -eq 'M') {$mods = $mods -bor 2}; if ($m -eq 'S') {$mods = $mods -bor 4} } }
  $ext = $false
  switch ($name) {
    'Enter' { $vk = 0x0D } 'Space' { $vk = 0x20 } 'Backspace' { $vk = 0x08 } 'Tab' { $vk = 0x09 }
    'End' { $vk = 0x23; $ext = $true } 'Home' { $vk = 0x24; $ext = $true } 'Left' { $vk = 0x25; $ext = $true } 'Up' { $vk = 0x26; $ext = $true }
    'Right' { $vk = 0x27; $ext = $true } 'Down' { $vk = 0x28; $ext = $true } 'Delete' { $vk = 0x2E; $ext = $true } 'PageDown' { $vk = 0x22; $ext = $true } 'PageUp' { $vk = 0x21; $ext = $true }
    'Minus' { $vk = 0xBD } 'Slash' { $vk = 0xBF } 'Comma' { $vk = 0xBC } 'Period' { $vk = 0xBE }
    default { $vk = [int][char]$name.ToUpper() }
  }
  [W]::Chord($script:h, $mods, [uint16]$vk, $ext)
}
function T([string]$s) { [W]::Text($script:h, $s) }
function Shot([string]$out) {
  $r = New-Object RECT; [void][W]::GetWindowRect($script:h, [ref]$r); $w = $r.R - $r.L; $hh = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap $w, $hh; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size); $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
}
$outdir = $args[0]; $file = $args[1]
$p = Start-Process -FilePath (Join-Path $PSScriptRoot "..\darger.exe") -ArgumentList $file -WorkingDirectory $outdir -PassThru
Start-Sleep -Seconds 3
if ($p.HasExited) { "EXITED code=$($p.ExitCode)"; exit 1 }
$p.Refresh(); $script:h = $p.MainWindowHandle
T "alpha beta"; K Enter; T "gamma delta"; K Enter; T "third"
K C-p; K C-a; K C-Space; K C-e; K M-w
K C-n; K C-e; K Enter; K C-y
K C-p; K C-p; K C-p; K C-a; K M-f; K M-d
Start-Sleep -Milliseconds 300; Shot "$outdir\k1.png"
K C-Slash
Start-Sleep -Milliseconds 300; Shot "$outdir\k2.png"
K C-x; K C-s
Start-Sleep -Milliseconds 300; Shot "$outdir\k3.png"
K C-s; T "delta"
Start-Sleep -Milliseconds 300; Shot "$outdir\k4.png"
K C-g; K C-x; K C-c
Start-Sleep -Seconds 1
"exited=$($p.HasExited)"
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; "had to kill" }
