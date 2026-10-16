param(
 [string]$Executable = (Join-Path $PSScriptRoot '../examples/window-drag/zig-out/bin/window-drag.exe'),
 [string]$ArtifactDirectory = (Join-Path $PSScriptRoot '../.zig-cache/window-drag-windows')
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'window-drag-windows-native.cs')
$exe=(Resolve-Path -LiteralPath $Executable).Path
$exampleRoot=Split-Path (Split-Path (Split-Path $exe -Parent) -Parent) -Parent
$artifactRoot=[System.IO.Path]::GetFullPath($ArtifactDirectory)
$artifacts=Join-Path $artifactRoot ('runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
$originalPointer=New-Object WindowDragNative+Point
[void][WindowDragNative]::GetCursorPos([ref]$originalPointer)
$ownedProcess=$null
$main=[IntPtr]::Zero
$results=New-Object System.Collections.Generic.List[object]
function Require-WindowForeground([IntPtr]$Handle) {
 [void][WindowDragNative]::ShowWindow($Handle,9)
 [void][WindowDragNative]::SetWindowPos($Handle,[IntPtr]::Zero,100,40,0,0,0x0001)
 [void][WindowDragNative]::Foreground($Handle)
 $focusDeadline=[DateTime]::UtcNow.AddSeconds(3)
 while([WindowDragNative]::GetForegroundWindow() -ne $Handle -and [DateTime]::UtcNow -lt $focusDeadline){Start-Sleep -Milliseconds 50}
 Start-Sleep -Milliseconds 250
 if([WindowDragNative]::GetForegroundWindow() -ne $Handle){throw 'Cannot establish foreground ownership; native input was not sent.'}
}
function Screen-Point([IntPtr]$Handle,[int]$X,[int]$Y) {
 $point=New-Object WindowDragNative+Point
 $scale=[WindowDragNative]::GetDpiForWindow($Handle)/96.0
 $point.X=[int]($X*$scale);$point.Y=[int]($Y*$scale)
 if(-not [WindowDragNative]::ClientToScreen($Handle,[ref]$point)){throw 'Client coordinate conversion failed'}
 return $point
}
function Require-InputOwner([IntPtr]$Handle) {
 if([WindowDragNative]::GetForegroundWindow() -ne $Handle){throw 'Foreground ownership changed; input aborted.'}
}
function Drag-At([IntPtr]$Handle,[int]$X,[int]$Y,[int]$DX,[int]$DY) {
 Require-InputOwner $Handle
 $point=Screen-Point $Handle $X $Y
 [void][WindowDragNative]::SetCursorPos($point.X,$point.Y)
 Start-Sleep -Milliseconds 80
 Require-InputOwner $Handle
 $pressed=$false
 try {
  [WindowDragNative]::Button($true);$pressed=$true
  Start-Sleep -Milliseconds 100
  for($step=1;$step -le 8;$step++){
   Require-InputOwner $Handle
   [void][WindowDragNative]::SetCursorPos($point.X+[int]($DX*$step/8),$point.Y+[int]($DY*$step/8))
   Start-Sleep -Milliseconds 30
  }
 } finally {if($pressed){[WindowDragNative]::Button($false)}}
 Start-Sleep -Milliseconds 150
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
 $element=$root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
 if(-not $element){throw "Accessible control not found: $Name"}
 return $element
}
function Click-Control([IntPtr]$Handle,[string]$Name) {
 if([WindowDragNative]::GetForegroundWindow() -ne $Handle){throw 'Foreground changed; input aborted.'}
 $element=Find-Control $Handle $Name
 $bounds=$element.Current.BoundingRectangle
 Click-At $Handle ([int]($bounds.Left+$bounds.Width/2)) ([int]($bounds.Top+$bounds.Height/2))
 Start-Sleep -Milliseconds 200
}
function Require-NoMove([IntPtr]$Handle,[int]$X,[int]$Y,[string]$Name) {
 $before=[WindowDragNative]::Bounds($Handle)
 Drag-At $Handle $X $Y 60 25
 $after=[WindowDragNative]::Bounds($Handle)
 if($before.Left -ne $after.Left -or $before.Top -ne $after.Top){throw "$Name unexpectedly moved the native window"}
 $results.Add(@{test=$Name;stationary=$true})
 Write-Output ('PASS '+$results[$results.Count-1].test)
}

try {
 $ownedProcess=Start-Process -FilePath $exe -WorkingDirectory $exampleRoot -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $artifacts 'stderr.log')
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 do {
  if($ownedProcess.HasExited){throw ('fixture exited: '+(Get-Content (Join-Path $artifacts 'stderr.log') -Raw))}
  $main=[WindowDragNative]::Find($ownedProcess.Id,'Native SDK Window Drag')
  if($main -ne [IntPtr]::Zero){break}
  Start-Sleep -Milliseconds 100
 } while([DateTime]::UtcNow -lt $deadline)
 if($main -eq [IntPtr]::Zero){throw 'fixture main window did not appear'}
 [void][WindowDragNative]::ShowWindow($main,9)
 $readyDeadline=[DateTime]::UtcNow.AddSeconds(15)
 do {
  $ready=$false
  try {
   $null=Find-Control $main 'Clicks: 0'
   $secondary=[WindowDragNative]::Find($ownedProcess.Id,'Native SDK Secondary Drag')
   $ready=$secondary -ne [IntPtr]::Zero
  } catch {if($ownedProcess.HasExited){throw 'fixture exited while loading'}}
  if(-not $ready){Start-Sleep -Milliseconds 100}
 } while(-not $ready -and [DateTime]::UtcNow -lt $readyDeadline)
 if(-not $ready){throw 'fixture documents did not become ready'}
 Require-WindowForeground $main
 $before=[WindowDragNative]::Bounds($main)
 Drag-At $main 180 55 96 48
 $after=[WindowDragNative]::Bounds($main)
 $dx=$after.Left-$before.Left;$dy=$after.Top-$before.Top
 if([Math]::Abs($dx-96) -gt 8 -or [Math]::Abs($dy-48) -gt 8){throw "header drag did not move native window: $dx,$dy"}
 $results.Add(@{test='main-header-drag';dx=$dx;dy=$dy})
 Write-Output ('PASS '+$results[$results.Count-1].test)
 Require-WindowForeground $main
 $secondary=[WindowDragNative]::Find($ownedProcess.Id,'Native SDK Secondary Drag')
 if($secondary -eq [IntPtr]::Zero){throw 'secondary window did not appear'}
 $otherBefore=[WindowDragNative]::Bounds($secondary)
 $before=[WindowDragNative]::Bounds($main)
 Drag-At $main 800 150 72 36
 $after=[WindowDragNative]::Bounds($main)
 $otherAfter=[WindowDragNative]::Bounds($secondary)
 if([Math]::Abs(($after.Left-$before.Left)-72) -gt 8){throw "child WebView drag did not move its native owner: $($after.Left-$before.Left),$($after.Top-$before.Top)"}
 if($otherAfter.Left -ne $otherBefore.Left -or $otherAfter.Top -ne $otherBefore.Top){throw 'child WebView moved another native window'}
 $results.Add(@{test='child-drag-owner';dx=$after.Left-$before.Left;dy=$after.Top-$before.Top})
 Write-Output ('PASS '+$results[$results.Count-1].test)
 Require-WindowForeground $main
 $point=Screen-Point $main 180 55
 [void][WindowDragNative]::SetCursorPos($point.X,$point.Y)
 for($click=0;$click -lt 2;$click++){
  Click-At $main $point.X $point.Y
  Start-Sleep -Milliseconds 80
 }
 $deadline=[DateTime]::UtcNow.AddSeconds(3)
 while(-not [WindowDragNative]::IsZoomed($main) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
 if(-not [WindowDragNative]::IsZoomed($main)){throw 'native titlebar double click did not maximize'}
 $results.Add(@{test='native-double-click';maximized=$true})
 Write-Output ('PASS '+$results[$results.Count-1].test)
 Require-WindowForeground $main
 Click-Control $main 'Clicks: 0'
 $null=Find-Control $main 'Clicks: 1'
 $results.Add(@{test='excluded-button-click';count=1})
 Write-Output ('PASS '+$results[$results.Count-1].test)
 Require-NoMove $main 250 316 'excluded-input-drag'
 Require-NoMove $main 600 180 'ordinary-content-stationary'
 Require-NoMove $main 800 530 'child-does-not-inherit-opt-in'
 Click-Control $main 'Add/remove a drag surface'
 $before=[WindowDragNative]::Bounds($main)
 Drag-At $main 180 470 64 24
 $after=[WindowDragNative]::Bounds($main)
 if([Math]::Abs(($after.Left-$before.Left)-64) -gt 8 -or [Math]::Abs(($after.Top-$before.Top)-24) -gt 8){throw 'Dynamically mounted drag region did not move its window'}
 $results.Add(@{test='dynamic-region';dx=$after.Left-$before.Left;dy=$after.Top-$before.Top})
 Write-Output ('PASS '+$results[$results.Count-1].test)
 Click-Control $main 'Add/remove a drag surface'
 Require-NoMove $main 180 470 'removed-region-stationary'
 Click-Control $main 'Reload'
 Start-Sleep -Seconds 1
 $null=Find-Control $main 'Clicks: 0'
 $before=[WindowDragNative]::Bounds($main)
 Drag-At $main 180 55 48 20
 $after=[WindowDragNative]::Bounds($main)
 if([Math]::Abs(($after.Left-$before.Left)-48) -gt 8 -or [Math]::Abs(($after.Top-$before.Top)-20) -gt 8){throw 'Reload lost the window drag adapter'}
 $results.Add(@{test='reload-drag';dx=$after.Left-$before.Left;dy=$after.Top-$before.Top})
 Write-Output ('PASS '+$results[$results.Count-1].test)
 Require-WindowForeground $main
 [void][WindowDragNative]::ShowWindow($main,3)
 Start-Sleep -Milliseconds 250
 if(-not [WindowDragNative]::IsZoomed($main)){throw 'maximize precondition failed'}
 Drag-At $main 180 55 96 72
 if([WindowDragNative]::IsZoomed($main)){throw 'dragging a maximized native window did not restore it'}
 $results.Add(@{test='maximized-drag-restores';restored=$true})
 Write-Output ('PASS '+$results[$results.Count-1].test)
 Require-WindowForeground $main
 $point=Screen-Point $main 180 55
 [void][WindowDragNative]::SetCursorPos($point.X,$point.Y)
 Require-InputOwner $main
 [WindowDragNative]::RightClick()
 Start-Sleep -Milliseconds 200
 Require-InputOwner $main
 $menuOpen=[WindowDragNative]::SystemMenuOpen($main)
 [WindowDragNative]::Escape()
 if(-not $menuOpen){throw 'right click did not open the owning native window system menu'}
 $results.Add(@{test='native-system-menu';owner=$true})
 Write-Output ('PASS '+$results[$results.Count-1].test)


 $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $artifactRoot 'results.json') -Encoding UTF8
 } catch {
 $results.Add(@{test='failure';message=$_.Exception.Message})
 if($main -ne [IntPtr]::Zero){
  Add-Type -AssemblyName System.Drawing
  $bounds=[WindowDragNative]::Bounds($main)
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
 if($ownedProcess -and -not $ownedProcess.HasExited){
  if([WindowDragNative]::GetForegroundWindow() -eq $main){[void][WindowDragNative]::SetCursorPos($originalPointer.X,$originalPointer.Y)}
  Stop-Process -Id $ownedProcess.Id -ErrorAction SilentlyContinue
 }
}
