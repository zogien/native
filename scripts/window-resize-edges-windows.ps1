# Real-input checks for the top resize band of a window whose top frame
# lives inside its client area (hidden_inset/_tall and chromeless): the
# cursor shape and real resizing at the top edge, both top corners, and
# above the page's own window controls, then the double-click vertical
# maximize. Points are physical client pixels, because the band is a few
# device rows tall. Dot-source after window-drag-windows-native.cs is
# loaded; every failed check throws.

function Test-TopResizeEdges {
 param(
  [IntPtr]$Handle,
  # Receives each passed check as a hashtable.
  [scriptblock]$Record,
  # Physical pixels from the right client edge to a point above the
  # page's own window controls.
  [int]$ControlsInset=60
 )
 # Clear of the work area's top edge: a top-edge drag that reaches the
 # screen edge snaps to a vertical maximize instead of following it.
 $work=[WindowDragNative]::WorkArea($Handle)
 $bounds=[WindowDragNative]::Bounds($Handle)
 $frame=@{x=$work.Left+100;y=$work.Top+200;width=$bounds.Right-$bounds.Left;height=$bounds.Bottom-$bounds.Top}
 $restore={
  [void][WindowDragNative]::ShowWindow($Handle,9)
  [void][WindowDragNative]::SetWindowPos($Handle,[IntPtr]::Zero,$frame.x,$frame.y,$frame.width,$frame.height,0x0004)
  [void][WindowDragNative]::Foreground($Handle)
  $deadline=[DateTime]::UtcNow.AddSeconds(3)
  while([WindowDragNative]::GetForegroundWindow() -ne $Handle -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
  if([WindowDragNative]::GetForegroundWindow() -ne $Handle){throw 'Cannot establish foreground ownership; native input was not sent.'}
  Start-Sleep -Milliseconds 250
 }
 $requireOwner={if([WindowDragNative]::GetForegroundWindow() -ne $Handle){throw 'Foreground ownership changed; input aborted.'}}
 $bandPoint={
  param([int]$X)
  $point=New-Object WindowDragNative+Point
  $point.X=$X;$point.Y=2
  if(-not [WindowDragNative]::ClientToScreen($Handle,[ref]$point)){throw 'Client coordinate conversion failed'}
  # Enter the band from the content below so the cursor is re-evaluated.
  [void][WindowDragNative]::SetCursorPos($point.X,$point.Y+30)
  Start-Sleep -Milliseconds 120
  [void][WindowDragNative]::SetCursorPos($point.X,$point.Y)
  Start-Sleep -Milliseconds 250
  return $point
 }

 & $restore
 $width=[WindowDragNative]::ClientWidth($Handle)
 # IDC_SIZENS 32645, IDC_SIZENWSE 32642, IDC_SIZENESW 32643.
 $checks=@(
  @{test='top-edge-resize';x=[int]($width/2);cursor=32645;dx=0;dy=-40;left=$false;right=$false},
  @{test='top-left-resize';x=3;cursor=32642;dx=-40;dy=-40;left=$true;right=$false},
  @{test='top-right-resize';x=$width-3;cursor=32643;dx=40;dy=-40;left=$false;right=$true},
  @{test='top-above-controls-resize';x=$width-$ControlsInset;cursor=32645;dx=0;dy=-40;left=$false;right=$false}
 )
 foreach($check in $checks){
  & $restore
  $point=& $bandPoint $check.x
  if(-not [WindowDragNative]::CursorIs($check.cursor)){throw "$($check.test): the top band did not show the native resize cursor"}
  & $requireOwner
  $before=[WindowDragNative]::Bounds($Handle)
  $pressed=$false
  try {
   [WindowDragNative]::Button($true);$pressed=$true
   Start-Sleep -Milliseconds 100
   for($step=1;$step -le 8;$step++){
    [void][WindowDragNative]::SetCursorPos($point.X+[int]($check.dx*$step/8),$point.Y+[int]($check.dy*$step/8))
    Start-Sleep -Milliseconds 30
   }
  } finally {if($pressed){[WindowDragNative]::Button($false)}}
  Start-Sleep -Milliseconds 200
  $after=[WindowDragNative]::Bounds($Handle)
  $moved=@{left=$after.Left-$before.Left;top=$after.Top-$before.Top;right=$after.Right-$before.Right;bottom=$after.Bottom-$before.Bottom}
  $expected=@{left=$(if($check.left){$check.dx}else{0});top=$check.dy;right=$(if($check.right){$check.dx}else{0});bottom=0}
  foreach($edge in 'left','top','right','bottom'){
   if([Math]::Abs($moved[$edge]-$expected[$edge]) -gt 3){throw "$($check.test): edges moved $($moved.left),$($moved.top),$($moved.right),$($moved.bottom); expected $($expected.left),$($expected.top),$($expected.right),$($expected.bottom)"}
  }
  & $Record @{test=$check.test;left=$moved.left;top=$moved.top;right=$moved.right;bottom=$moved.bottom}
 }

 # A double-click on the top edge maximizes vertically, as on a standard
 # frame: the window spans the work area's height and keeps its width.
 & $restore
 [void](& $bandPoint ([int]($width/2)))
 $before=[WindowDragNative]::Bounds($Handle)
 for($click=0;$click -lt 2;$click++){
  & $requireOwner
  [WindowDragNative]::Button($true);Start-Sleep -Milliseconds 40;[WindowDragNative]::Button($false)
  Start-Sleep -Milliseconds 70
 }
 Start-Sleep -Milliseconds 500
 $after=[WindowDragNative]::Bounds($Handle)
 if([WindowDragNative]::IsZoomed($Handle)){throw 'top-edge double-click maximized the window instead of maximizing it vertically'}
 if($after.Top -gt $work.Top+1 -or $after.Bottom -lt $work.Bottom-1 -or $after.Left -ne $before.Left -or $after.Right -ne $before.Right){throw "top-edge double-click did not maximize vertically: $($after.Left),$($after.Top)..$($after.Right),$($after.Bottom)"}
 & $Record @{test='top-edge-double-click';top=$after.Top;bottom=$after.Bottom}
 & $restore
}
