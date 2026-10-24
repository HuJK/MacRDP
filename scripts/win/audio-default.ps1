# List audio endpoints, or make one the default device. Runs in the desktop
# session (through session-run.ps1). Reads audio-default.json next to this
# script:
#   {}                                       list: flow, default?, name, id
#   {"flow": "capture", "name": "CABLE Output"}  make the first active
#                                            capture endpoint whose name
#                                            contains it the default (all roles)
# Logs to audio-default.txt. Setting uses IPolicyConfig, the interface the
# Sound control panel itself uses (undocumented, stable since Windows 7).
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$req = Get-Content (Join-Path $dir 'audio-default.json') -Raw | ConvertFrom-Json
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class AudioDev {
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
  [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
  }
  [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceCollection { int GetCount(out int count); int Item(int i, out IMMDevice device); }
  [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    int OpenPropertyStore(int access, out IPropertyStore store);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
  }
  [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    int GetCount(out int n); int GetAt(int i, out PropertyKey k); int GetValue(ref PropertyKey k, out PropVariant v);
  }
  [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public int pid; }
  [StructLayout(LayoutKind.Explicit)] struct PropVariant { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr p; }
  [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClient { }
  [Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPolicyConfig {
    int GetMixFormat(); int GetDeviceFormat(); int ResetDeviceFormat(); int SetDeviceFormat();
    int GetProcessingPeriod(); int SetProcessingPeriod(); int GetShareMode(); int SetShareMode();
    int GetPropertyValue(); int SetPropertyValue();
    int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    int SetEndpointVisibility();
  }

  static string Name(IMMDevice d) {
    IPropertyStore ps; d.OpenPropertyStore(0, out ps);
    var key = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };   // PKEY_Device_FriendlyName
    PropVariant v; ps.GetValue(ref key, out v);
    return v.vt == 31 ? Marshal.PtrToStringUni(v.p) : "?";
  }

  // flow: 0 render, 1 capture. Active endpoints only.
  public static List<string[]> List() {
    var e = (IMMDeviceEnumerator)new MMDeviceEnumerator();
    var rows = new List<string[]>();
    for (int flow = 0; flow < 2; flow++) {
      IMMDevice def; string defId = null;
      if (e.GetDefaultAudioEndpoint(flow, 0, out def) == 0) def.GetId(out defId);
      IMMDeviceCollection c; e.EnumAudioEndpoints(flow, 1, out c);
      int n; c.GetCount(out n);
      for (int i = 0; i < n; i++) {
        IMMDevice d; c.Item(i, out d); string id; d.GetId(out id);
        rows.Add(new[] { flow == 0 ? "render" : "capture", id == defId ? "default" : "", Name(d), id });
      }
    }
    return rows;
  }

  public static string SetDefault(int flow, string nameContains) {
    foreach (var r in List()) {
      if (r[0] != (flow == 0 ? "render" : "capture") || r[2].IndexOf(nameContains, StringComparison.OrdinalIgnoreCase) < 0) continue;
      var pc = (IPolicyConfig)new PolicyConfigClient();
      for (int role = 0; role < 3; role++) Marshal.ThrowExceptionForHR(pc.SetDefaultEndpoint(r[3], role));   // console, multimedia, communications
      return r[2];
    }
    return null;
  }
}
'@
$out = @()
if ($req.name) {
  $flow = if ($req.flow -eq 'render') { 0 } else { 1 }
  $set = [AudioDev]::SetDefault($flow, [string]$req.name)
  $out += if ($set) { "default $($req.flow): $set" } else { "no active $($req.flow) endpoint matching '$($req.name)'" }
}
foreach ($r in [AudioDev]::List()) { $out += ('{0,-8} {1,-8} {2}  {3}' -f $r[0], $r[1], $r[2], $r[3]) }
$out | Out-File -Encoding utf8 (Join-Path $dir 'audio-default.txt')
