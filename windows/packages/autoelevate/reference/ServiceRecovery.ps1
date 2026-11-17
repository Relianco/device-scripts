# Manual recovery building blocks only. Loading this file does not access SCM.
# Read README.md before calling Write: it changes service recovery configuration.
if (-not ('AeRecovery' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AeRecovery {
 [StructLayout(LayoutKind.Sequential)] public struct ActionItem { public int Type; public uint Delay; }
 [StructLayout(LayoutKind.Sequential)] struct NativeActions { public uint Reset; public IntPtr Message; public IntPtr Command; public uint Count; public IntPtr Items; }
 public class Snapshot { public uint Reset; public string Message; public string Command; public ActionItem[] Actions; public bool NonCrash; }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenSCManager(string machine,string database,uint access);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenService(IntPtr scm,string name,uint access);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool CloseServiceHandle(IntPtr h);
 [DllImport("advapi32.dll",EntryPoint="QueryServiceConfig2W",SetLastError=true)] static extern bool Query(IntPtr h,uint level,IntPtr data,uint size,out uint needed);
 [DllImport("advapi32.dll",EntryPoint="ChangeServiceConfig2W",SetLastError=true)] static extern bool Change(IntPtr h,uint level,IntPtr data);
 static IntPtr Open(string name,uint access) { IntPtr m=OpenSCManager(null,null,1);if(m==IntPtr.Zero)throw new Win32Exception();try {IntPtr h=OpenService(m,name,access);if(h==IntPtr.Zero)throw new Win32Exception();return h;}finally{CloseServiceHandle(m);} }
 static IntPtr Buffer(IntPtr h,uint level) {uint n;Query(h,level,IntPtr.Zero,0,out n);if(n<4||n>65536)throw new InvalidOperationException("Invalid config size");IntPtr p=Marshal.AllocHGlobal((int)n);if(!Query(h,level,p,n,out n)){Marshal.FreeHGlobal(p);throw new Win32Exception();}return p;}
 public static Snapshot Read(string name) {IntPtr h=Open(name,1);try {IntPtr p=Buffer(h,2);Snapshot s=new Snapshot();try {NativeActions a=(NativeActions)Marshal.PtrToStructure(p,typeof(NativeActions));if(a.Count>100)throw new InvalidOperationException();s.Reset=a.Reset;s.Message=Marshal.PtrToStringUni(a.Message)??"";s.Command=Marshal.PtrToStringUni(a.Command)??"";s.Actions=new ActionItem[a.Count];for(int i=0;i<a.Count;i++)s.Actions[i]=(ActionItem)Marshal.PtrToStructure(IntPtr.Add(a.Items,i*8),typeof(ActionItem));}finally{Marshal.FreeHGlobal(p);}p=Buffer(h,4);try{s.NonCrash=Marshal.ReadInt32(p)!=0;}finally{Marshal.FreeHGlobal(p);}return s;}finally{CloseServiceHandle(h);} }
 // SC_ACTION_RESTART additionally requires SERVICE_START (0x10).
 public static uint WriteAccess(Snapshot s) {foreach(ActionItem a in s.Actions)if(a.Type==1)return 18;return 2;}
 // Keep Items non-null even when Count is zero: null means leave actions unchanged.
 public static void Write(string name,Snapshot s) {IntPtr h=Open(name,WriteAccess(s));IntPtr items=IntPtr.Zero,msg=IntPtr.Zero,cmd=IntPtr.Zero,p=IntPtr.Zero,flag=IntPtr.Zero;try {items=Marshal.AllocHGlobal(Math.Max(1,s.Actions.Length)*8);for(int i=0;i<s.Actions.Length;i++)Marshal.StructureToPtr(s.Actions[i],IntPtr.Add(items,i*8),false);msg=Marshal.StringToHGlobalUni(s.Message??"");cmd=Marshal.StringToHGlobalUni(s.Command??"");NativeActions a=new NativeActions();a.Reset=s.Reset;a.Message=msg;a.Command=cmd;a.Count=(uint)s.Actions.Length;a.Items=items;p=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeActions)));Marshal.StructureToPtr(a,p,false);if(!Change(h,2,p))throw new Win32Exception();flag=Marshal.AllocHGlobal(4);Marshal.WriteInt32(flag,s.NonCrash?1:0);if(!Change(h,4,flag))throw new Win32Exception();}finally{foreach(IntPtr v in new IntPtr[]{items,msg,cmd,p,flag})if(v!=IntPtr.Zero)Marshal.FreeHGlobal(v);CloseServiceHandle(h);} }
 public static Snapshot Empty() {return new Snapshot{Reset=0,Message="",Command="",Actions=new ActionItem[0],NonCrash=false};}
}
'@
}
function Test-AeRecoveryClear($Snapshot){return ($Snapshot.Actions.Count -eq 0 -and -not $Snapshot.NonCrash)}
function Test-AeServiceIdentity($Service,$Process,[string]$ExpectedPath){
 return ($Service.Name -eq 'AutoElevateAgent' -and [int]$Service.ProcessId -gt 0 -and [int]$Service.ProcessId -eq [int]$Process.Id -and [string]$Process.Path -ieq $ExpectedPath -and ([string]$Service.PathName).Trim('"') -ieq $ExpectedPath)
}
function Get-AeStartupType([string]$Mode){switch($Mode){'Auto'{'Automatic'}'Manual'{'Manual'}'Disabled'{'Disabled'}default{throw 'Unknown original start mode'}}}
