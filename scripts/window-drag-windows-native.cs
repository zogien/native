using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WindowDragNative {
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct MouseInput { public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra; }
 [StructLayout(LayoutKind.Sequential)] public struct KeyboardInput { public ushort Key,Scan; public uint Flags,Time; public UIntPtr Extra; }
 [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyboardInput Keyboard; }
 [StructLayout(LayoutKind.Sequential)] public struct GuiThreadInfo { public uint Size,Flags; public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret; public Rect CaretRect; }
 [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread,ref GuiThreadInfo info);
 [StructLayout(LayoutKind.Sequential)] public struct Input { public uint Type; public InputUnion Value; }
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback,IntPtr p);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder text,int count);
 [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h,ref Point p);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from,uint to,bool attach);
 public static bool Foreground(IntPtr h) {
  uint unused;uint foregroundThread=GetWindowThreadProcessId(GetForegroundWindow(),out unused);
  uint current=GetCurrentThreadId();bool attached=current!=foregroundThread && AttachThreadInput(current,foregroundThread,true);
  try { return SetForegroundWindow(h); }
  finally {if(attached)AttachThreadInput(current,foregroundThread,false);}
 }
 [DllImport("user32.dll",SetLastError=true)] public static extern uint SendInput(uint count,Input[] inputs,int size);
 public static IntPtr Find(int processId,string title) {
  IntPtr result=IntPtr.Zero;
  EnumWindows(delegate(IntPtr h,IntPtr p) {
   uint owner;GetWindowThreadProcessId(h,out owner);if(owner!=(uint)processId)return true;
   var text=new StringBuilder(256);GetWindowText(h,text,256);
   if(text.ToString()==title){result=h;return false;}return true;
  },IntPtr.Zero);return result;
 }
 public static bool SystemMenuOpen(IntPtr owner) {
  var info=new GuiThreadInfo();info.Size=(uint)Marshal.SizeOf(typeof(GuiThreadInfo));
  return GetGUIThreadInfo(0,ref info) && info.MenuOwner==owner && (info.Flags&4)!=0;
 }
 public static void Escape() {
  var input=new Input();input.Type=1;input.Value.Keyboard.Key=0x1b;
  if(SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))!=1)throw new Exception("keyboard input failed");
  input.Value.Keyboard.Flags=2;
  if(SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))!=1)throw new Exception("keyboard release failed");
 }
 public static void RightClick() {
  var input=new Input();input.Value.Mouse.Flags=8;
  if(SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))!=1)throw new Exception("right button input failed");
  input.Value.Mouse.Flags=16;
  if(SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))!=1)throw new Exception("right button release failed");
 }
 public static void Button(bool down) {
  var input=new Input();input.Value.Mouse.Flags=down?2u:4u;
  if(SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))!=1)throw new Exception("SendInput failed: "+Marshal.GetLastWin32Error());
 }
 public static Rect Bounds(IntPtr h){Rect r;if(!GetWindowRect(h,out r))throw new Exception("window unavailable");return r;}
 [StructLayout(LayoutKind.Sequential)] public struct CursorInfo { public int Size,Flags; public IntPtr Cursor; public Point Position; }
 [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public uint Size; public Rect Monitor; public Rect Work; public uint Flags; }
 [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CursorInfo info);
 [DllImport("user32.dll")] static extern IntPtr LoadCursor(IntPtr instance,IntPtr name);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h,uint flags);
 [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor,ref MonitorInfo info);
 // A shared system cursor (IDC_* id) is the one on screen right now.
 public static bool CursorIs(int systemCursor) {
  var info=new CursorInfo();info.Size=Marshal.SizeOf(typeof(CursorInfo));
  return GetCursorInfo(ref info) && info.Cursor==LoadCursor(IntPtr.Zero,(IntPtr)systemCursor);
 }
 public static int ClientWidth(IntPtr h){Rect r;if(!GetClientRect(h,out r))throw new Exception("window unavailable");return r.Right;}
 public static Rect WorkArea(IntPtr h) {
  var info=new MonitorInfo();info.Size=(uint)Marshal.SizeOf(typeof(MonitorInfo));
  if(!GetMonitorInfo(MonitorFromWindow(h,2),ref info))throw new Exception("monitor unavailable");
  return info.Work;
 }
}
