using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CodexWindowsFastPatch {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct TrayItem {
    [MarshalAs(UnmanagedType.LPWStr)] public string Exe;
    [MarshalAs(UnmanagedType.LPWStr)] public string Tip;
    public IntPtr Icon, Window;
    public uint Preference, Id;
    public Guid Guid;
  }

  // Explorer's Windows 8+ notification enumeration interface. No preference writes.
  [ComVisible(true), Guid("D782CCBA-AFB0-43F1-94DB-FDA3779EACCB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ITrayCallback {
    [PreserveSig] int Notify(uint action, IntPtr item);
  }
  [ComImport, Guid("D133CE13-3537-48BA-93A7-AFCD5D2053B4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITrayNotify8 {
    void RegisterCallback(ITrayCallback callback, out uint id);
    void UnregisterCallback(ref uint id);
  }
  [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
  public class TrayCallback : ITrayCallback {
    public readonly List<TrayItem> Items = new List<TrayItem>();
    public int Notify(uint action, IntPtr item) {
      // Input belongs to Explorer. A ref struct with strings marshals them back
      // and frees shell-owned memory; copy from the pointer instead.
      if (item != IntPtr.Zero)
        Items.Add((TrayItem)Marshal.PtrToStructure(item, typeof(TrayItem)));
      return 0;
    }
  }
  public static class MsixTray {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NotifyData {
      public uint Size;
      public IntPtr Window;
      public uint Id, Flags, Callback;
      public IntPtr Icon;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
      public uint State, StateMask;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
      public uint Timeout;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Title;
      public uint InfoFlags;
      public Guid Guid;
      public IntPtr BalloonIcon;
    }
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern bool Shell_NotifyIcon(uint message, ref NotifyData data);

    public static uint Owner(IntPtr window) {
      uint processId;
      GetWindowThreadProcessId(window, out processId);
      return processId;
    }
    public static TrayItem[] Read() {
      object instance = Activator.CreateInstance(Type.GetTypeFromCLSID(
        new Guid("25DEAD04-1EAC-4911-9E3A-AD0A4AB560FD")));
      try {
        var notify = (ITrayNotify8)instance;
        var callback = new TrayCallback();
        uint id = 0;
        try {
          notify.RegisterCallback(callback, out id);
          return callback.Items.ToArray();
        } finally {
          if (id != 0) notify.UnregisterCallback(ref id);
          GC.KeepAlive(callback);
        }
      } finally { Marshal.FinalReleaseComObject(instance); }
    }
    public static bool RemoveDead(TrayItem item) {
      if (item.Window == IntPtr.Zero || Owner(item.Window) != 0)
        throw new InvalidOperationException("Refusing to remove an empty or live tray window.");
      var data = new NotifyData();
      data.Size = (uint)Marshal.SizeOf(typeof(NotifyData));
      data.Window = item.Window;
      data.Id = item.Id;
      data.Guid = item.Guid;
      if (item.Guid != Guid.Empty) data.Flags = 0x20; // NIF_GUID
      return Shell_NotifyIcon(2, ref data); // NIM_DELETE, leaves user preferences intact
    }
  }
}
