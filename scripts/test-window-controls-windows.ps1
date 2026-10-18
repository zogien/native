param(
 [string]$Executable = (Join-Path $PSScriptRoot '../examples/window-controls/zig-out/bin/window-controls.exe'),
 [string]$ArtifactDirectory = (Join-Path $PSScriptRoot '../.zig-cache/window-controls-windows')
)
# Drives examples/window-controls with real input: page-drawn Minimize,
# Maximize/Restore and Close buttons reach Runtime.minimizeWindow,
# maximizeWindow, unmaximizeWindow and requestCloseWindow, and every page
# keeps showing the window's real maximized state, whoever changed it.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'window-drag-windows-native.cs')
. (Join-Path $PSScriptRoot 'window-resize-edges-windows.ps1')
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WindowControlsNative {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
 [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public uint Size; public Rect Monitor; public Rect Work; public uint Flags; }
 delegate bool MonitorEnumProc(IntPtr monitor,IntPtr hdc,ref Rect bounds,IntPtr data);
 [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc,IntPtr clip,MonitorEnumProc callback,IntPtr data);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h,uint flags);
 [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor,ref MonitorInfo info);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref Point p);
 public static Rect WorkArea(IntPtr h) {
  var info=new MonitorInfo();info.Size=(uint)Marshal.SizeOf(typeof(MonitorInfo));
  if(!GetMonitorInfo(MonitorFromWindow(h,2),ref info))throw new Exception("monitor unavailable");
  return info.Work;
 }
 public static Rect[] WorkAreas() {
  var areas=new System.Collections.Generic.List<Rect>();
  EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,delegate(IntPtr monitor,IntPtr hdc,ref Rect bounds,IntPtr data) {
   var info=new MonitorInfo();info.Size=(uint)Marshal.SizeOf(typeof(MonitorInfo));
   if(GetMonitorInfo(monitor,ref info))areas.Add(info.Work);
   return true;
  },IntPtr.Zero);
  return areas.ToArray();
 }
 public static Rect ClientOnScreen(IntPtr h) {
  Rect r;if(!GetClientRect(h,out r))throw new Exception("window unavailable");
  var origin=new Point();if(!ClientToScreen(h,ref origin))throw new Exception("client conversion failed");
  r.Left+=origin.X;r.Right+=origin.X;r.Top+=origin.Y;r.Bottom+=origin.Y;return r;
 }
}
'@
$exe=(Resolve-Path -LiteralPath $Executable).Path
$exampleRoot=Split-Path (Split-Path (Split-Path $exe -Parent) -Parent) -Parent
$artifactRoot=[System.IO.Path]::GetFullPath($ArtifactDirectory)
$artifacts=Join-Path $artifactRoot ('runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
$originalPointer=New-Object WindowDragNative+Point
[void][WindowDragNative]::GetCursorPos([ref]$originalPointer)
$ownedProcess=$null
$main=[IntPtr]::Zero
$failureWindow=[IntPtr]::Zero
$results=New-Object System.Collections.Generic.List[object]
function Pass([hashtable]$Result) {
 $results.Add($Result)
 Write-Output ('PASS '+$Result.test)
}
function Wait-Until([scriptblock]$Condition,[string]$Failure,[int]$Seconds=5) {
 $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
 while(-not (& $Condition)) {
  if($ownedProcess.HasExited){throw "fixture exited while waiting: $Failure"}
  if([DateTime]::UtcNow -ge $deadline){throw $Failure}
  Start-Sleep -Milliseconds 50
 }
}
# Foreground without ShowWindow: restoring here would undo the maximize
# under test.
function Focus-Window([IntPtr]$Handle) {
 $script:failureWindow=$Handle
 [void][WindowDragNative]::Foreground($Handle)
 Wait-Until {[WindowDragNative]::GetForegroundWindow() -eq $Handle} 'Cannot establish foreground ownership; native input was not sent.' 3
 Start-Sleep -Milliseconds 250
}
function Require-InputOwner([IntPtr]$Handle) {
 if([WindowDragNative]::GetForegroundWindow() -ne $Handle){throw 'Foreground ownership changed; input aborted.'}
}
function Click-At([IntPtr]$Handle,[int]$X,[int]$Y) {
 Require-InputOwner $Handle
 [void][WindowDragNative]::SetCursorPos($X,$Y)
 Require-InputOwner $Handle
 $pressed=$false
 try {
  [WindowDragNative]::Button($true);$pressed=$true
  Start-Sleep -Milliseconds 40
 } finally {if($pressed){[WindowDragNative]::Button($false)}}
}
function Find-Control([IntPtr]$Handle,[string]$Name) {
 $root=[System.Windows.Automation.AutomationElement]::FromHandle($Handle)
 $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$Name)
 return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
}
function Wait-Control([IntPtr]$Handle,[string]$Name,[int]$Seconds=5) {
 Wait-Until {$null -ne (Find-Control $Handle $Name)} "Page text not found: $Name" $Seconds
}
function Click-Control([IntPtr]$Handle,[string]$Name) {
 $element=Find-Control $Handle $Name
 if(-not $element){throw "Accessible control not found: $Name"}
 $bounds=$element.Current.BoundingRectangle
 Click-At $Handle ([int]($bounds.Left+$bounds.Width/2)) ([int]($bounds.Top+$bounds.Height/2))
 Start-Sleep -Milliseconds 200
}
function Double-Click-Client([IntPtr]$Handle,[int]$X,[int]$Y) {
 $point=New-Object WindowDragNative+Point
 $scale=[WindowDragNative]::GetDpiForWindow($Handle)/96.0
 $point.X=[int]($X*$scale);$point.Y=[int]($Y*$scale)
 if(-not [WindowDragNative]::ClientToScreen($Handle,[ref]$point)){throw 'Client coordinate conversion failed'}
 for($click=0;$click -lt 2;$click++){
  Click-At $Handle $point.X $point.Y
  Start-Sleep -Milliseconds 80
 }
}
function Same-Rect($A,$B) {
 return $A.Left -eq $B.Left -and $A.Top -eq $B.Top -and $A.Right -eq $B.Right -and $A.Bottom -eq $B.Bottom
}
function Format-Rect($R) {return "$($R.Left),$($R.Top)..$($R.Right),$($R.Bottom)"}
function Require-FillsWorkArea([IntPtr]$Handle,[string]$Name) {
 $work=[WindowControlsNative]::WorkArea($Handle)
 $client=[WindowControlsNative]::ClientOnScreen($Handle)
 if(-not (Same-Rect $client $work)){throw "$Name`: client $(Format-Rect $client) does not fill work area $(Format-Rect $work)"}
}
function Drag-Client([IntPtr]$Handle,[int]$X,[int]$Y,[int]$DX,[int]$DY) {
 $point=New-Object WindowDragNative+Point
 $scale=[WindowDragNative]::GetDpiForWindow($Handle)/96.0
 $point.X=[int]($X*$scale);$point.Y=[int]($Y*$scale)
 if(-not [WindowDragNative]::ClientToScreen($Handle,[ref]$point)){throw 'Client coordinate conversion failed'}
 Require-InputOwner $Handle
 [void][WindowDragNative]::SetCursorPos($point.X,$point.Y)
 Start-Sleep -Milliseconds 80
 $pressed=$false
 try {
  [WindowDragNative]::Button($true);$pressed=$true
  Start-Sleep -Milliseconds 100
  for($step=1;$step -le 8;$step++){
   [void][WindowDragNative]::SetCursorPos($point.X+[int]($DX*$step/8),$point.Y+[int]($DY*$step/8))
   Start-Sleep -Milliseconds 30
  }
 } finally {if($pressed){[WindowDragNative]::Button($false)}}
 Start-Sleep -Milliseconds 150
}
function Find-Window([string]$Title) {
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 do {
  if($ownedProcess.HasExited){throw ('fixture exited: '+(Get-Content (Join-Path $artifacts 'stderr.log') -Raw))}
  $handle=[WindowDragNative]::Find($ownedProcess.Id,$Title)
  if($handle -ne [IntPtr]::Zero){return $handle}
  Start-Sleep -Milliseconds 100
 } while([DateTime]::UtcNow -lt $deadline)
 throw "fixture window did not appear: $Title"
}

try {
 $ownedProcess=Start-Process -FilePath $exe -WorkingDirectory $exampleRoot -PassThru -RedirectStandardError (Join-Path $artifacts 'stderr.log')
 $main=Find-Window 'Window Controls Main'
 $palette=Find-Window 'Window Controls Palette'
 $quitter=Find-Window 'Window Controls Quitter'
 foreach($handle in @($main,$palette,$quitter)){Wait-Control $handle 'Maximized: false' 15}

 # The page's own buttons drive the window, on every attached monitor:
 # a maximized chromeless window must fill exactly that monitor's work
 # area, taskbar left visible.
 $monitors=[WindowControlsNative]::WorkAreas()
 for($index=0;$index -lt $monitors.Length;$index++){
  $work=$monitors[$index]
  [void][WindowDragNative]::SetWindowPos($main,[IntPtr]::Zero,$work.Left+80,$work.Top+80,0,0,0x0001)
  Wait-Until {(Same-Rect ([WindowControlsNative]::WorkArea($main)) $work)} "main window did not move onto monitor $index"
  Focus-Window $main
  Click-Control $main 'Maximize'
  Wait-Until {[WindowDragNative]::IsZoomed($main)} "page Maximize did not maximize the native window on monitor $index"
  Wait-Control $main 'Maximized: true'
  Wait-Control $main 'Restore'
  Require-FillsWorkArea $main "page maximize on monitor $index"
  Pass @{test="page-maximize-monitor-$index";work=(Format-Rect $work)}
  Focus-Window $main
  Click-Control $main 'Restore'
  Wait-Until {-not [WindowDragNative]::IsZoomed($main)} "page Restore did not restore the native window on monitor $index"
  Wait-Control $main 'Maximized: false'
  Wait-Control $main 'Maximize'
  Pass @{test="page-restore-monitor-$index"}
 }

 # A system action the app did not request still reaches the page.
 Focus-Window $main
 Double-Click-Client $main 420 22
 Wait-Until {[WindowDragNative]::IsZoomed($main)} 'caption double-click did not maximize the native window'
 Wait-Control $main 'Maximized: true'
 Require-FillsWorkArea $main 'caption double-click maximize'
 Pass @{test='system-maximize-reaches-page'}

 # A page loading while maximized reads the state from the window list.
 Focus-Window $main
 Click-Control $main 'Clicks: 0'
 Wait-Control $main 'Clicks: 1'
 Click-Control $main 'Reload'
 Wait-Control $main 'Clicks: 0' 10
 Wait-Control $main 'Maximized: true' 10
 Pass @{test='reload-reads-maximized'}

 [void][WindowDragNative]::ShowWindow($main,9)
 Wait-Until {-not [WindowDragNative]::IsZoomed($main)} 'SW_RESTORE did not restore the native window'
 Wait-Control $main 'Maximized: false'
 Pass @{test='system-restore-reaches-page'}

 # The maximized-frame correction runs on every position change; a
 # restored window still moves with its drag region.
 Focus-Window $main
 $before=[WindowDragNative]::Bounds($main)
 Drag-Client $main 420 22 96 48
 $after=[WindowDragNative]::Bounds($main)
 $dx=$after.Left-$before.Left;$dy=$after.Top-$before.Top
 if([Math]::Abs($dx-96) -gt 8 -or [Math]::Abs($dy-48) -gt 8){throw "header drag did not move the restored window: $dx,$dy"}
 if(($after.Right-$after.Left) -ne ($before.Right-$before.Left) -or ($after.Bottom-$after.Top) -ne ($before.Bottom-$before.Top)){throw 'header drag resized the restored window'}
 Pass @{test='restored-window-drags';dx=$dx;dy=$dy}

 # A chromeless window hands its top frame to the client: the window
 # keeps the top resize band over the page, its buttons included.
 $failureWindow=$main
 Test-TopResizeEdges $main {param($result) Pass $result}

 Focus-Window $main
 Click-Control $main 'Minimize'
 Wait-Until {[WindowControlsNative]::IsIconic($main)} 'page Minimize did not minimize the native window'
 [void][WindowDragNative]::ShowWindow($main,9)
 Wait-Until {-not [WindowControlsNative]::IsIconic($main)} 'minimized window did not come back'
 Pass @{test='page-minimize'}

 # close_policy "hide": the page's Close hides the window and keeps its page.
 Focus-Window $palette
 Click-Control $palette 'Clicks: 0'
 Wait-Control $palette 'Clicks: 1'
 Click-Control $palette 'Close'
 Wait-Until {-not [WindowControlsNative]::IsWindowVisible($palette)} 'page Close did not hide the hide-policy window'
 if(-not [WindowControlsNative]::IsWindow($palette)){throw 'hide-policy window was destroyed'}
 if($ownedProcess.HasExited){throw 'fixture exited after a hide-policy close'}
 Focus-Window $main
 Click-Control $main 'Show palette'
 Wait-Until {[WindowControlsNative]::IsWindowVisible($palette)} 'Show palette did not re-show the hidden window'
 Wait-Control $palette 'Clicks: 1'
 if($null -eq (Find-Control $main 'Closed: none')){throw 'hiding a window reported a user close'}
 Pass @{test='request-close-hide-policy'}

 # A window the system cannot maximize refuses explicitly.
 Focus-Window $quitter
 Click-Control $quitter 'Maximize'
 Wait-Control $quitter 'Error: WindowNotResizable'
 if([WindowDragNative]::IsZoomed($quitter)){throw 'non-resizable window was maximized'}
 Pass @{test='maximize-refuses-fixed-window'}

 # close_policy "quit": the page's Close really closes the window, and
 # the app hears it as a user close.
 Focus-Window $quitter
 Click-Control $quitter 'Close'
 Wait-Until {-not [WindowControlsNative]::IsWindow($quitter)} 'page Close did not close the quit-policy window'
 if($ownedProcess.HasExited){throw 'fixture exited after closing one of its windows'}
 Wait-Control $main 'Closed: quitter'
 Pass @{test='request-close-quit-policy'}

 $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $artifactRoot 'results.json') -Encoding UTF8
} catch {
 $results.Add(@{test='failure';message=$_.Exception.Message})
 if($failureWindow -ne [IntPtr]::Zero -and [WindowControlsNative]::IsWindow($failureWindow)){
  Add-Type -AssemblyName System.Drawing
  $bounds=[WindowDragNative]::Bounds($failureWindow)
  $bitmap=New-Object System.Drawing.Bitmap(($bounds.Right-$bounds.Left),($bounds.Bottom-$bounds.Top))
  $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try {
   $graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size)
   $bitmap.Save((Join-Path $artifacts 'failure.png'))
  } finally {$graphics.Dispose();$bitmap.Dispose()}
 }
 throw
} finally {
 $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $artifacts 'results.json') -Encoding UTF8
 [void][WindowDragNative]::SetCursorPos($originalPointer.X,$originalPointer.Y)
 if($ownedProcess -and -not $ownedProcess.HasExited){Stop-Process -Id $ownedProcess.Id -ErrorAction SilentlyContinue}
}
