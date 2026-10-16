# Exercise the production input functions without touching the desktop.
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @"
using System;
public static class WindowDragNative {
 public struct Point {public int X,Y;}
 public static int Checks, FlipOnCheck, Down, Up, Moves;
 public static IntPtr GetForegroundWindow(){Checks++;return new IntPtr(FlipOnCheck>0 && Checks>=FlipOnCheck?2:1);}
 public static bool SetCursorPos(int x,int y){Moves++;return true;}
 public static uint GetDpiForWindow(IntPtr h){return 96;}
 public static bool ClientToScreen(IntPtr h,ref Point p){return true;}
 public static void Button(bool down){if(down)Down++;else Up++;}
 public static void Reset(int flip){Checks=Down=Up=Moves=0;FlipOnCheck=flip;}
}
"@
$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-window-drag-windows.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Production input harness does not parse'}
$names=@('Require-InputOwner','Screen-Point','Drag-At','Click-At')
$functions=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names},$true)
if($functions.Count -ne $names.Count){throw 'Input function extraction failed'}
foreach($function in $functions){Invoke-Expression $function.Extent.Text}
function Start-Sleep {param([int]$Milliseconds)}
function Expect-Counts([int]$Down,[int]$Up,[int]$Moves) {
 if([WindowDragNative]::Down -ne $Down -or [WindowDragNative]::Up -ne $Up -or [WindowDragNative]::Moves -ne $Moves){throw "Unexpected input counts: $([WindowDragNative]::Down),$([WindowDragNative]::Up),$([WindowDragNative]::Moves)"}
}
function Expect-Abort([scriptblock]$Operation) {
 $aborted=$false
 try {& $Operation} catch {if($_.Exception.Message -notmatch 'Foreground ownership changed'){throw};$aborted=$true}
 if(-not $aborted){throw 'Foreground change was not rejected'}
}
[WindowDragNative]::Reset(2)
Expect-Abort {Drag-At ([IntPtr]1) 20 30 60 25}
Expect-Counts 0 0 1
Write-Output 'PASS focus loss before down sends no button input'
[WindowDragNative]::Reset(5)
Expect-Abort {Drag-At ([IntPtr]1) 20 30 60 25}
Expect-Counts 1 1 3
Write-Output 'PASS focus loss mid-drag stops motion and releases the owned press'
[WindowDragNative]::Reset(0)
Drag-At ([IntPtr]1) 20 30 60 25
Expect-Counts 1 1 9
Write-Output 'PASS owned drag completes normally'
[WindowDragNative]::Reset(2)
Expect-Abort {Click-At ([IntPtr]1) 20 30}
Expect-Counts 0 0 1
Write-Output 'PASS focus loss before click sends no button input'
[WindowDragNative]::Reset(0)
Click-At ([IntPtr]1) 20 30
Expect-Counts 1 1 1
Write-Output 'PASS owned click releases its button'
