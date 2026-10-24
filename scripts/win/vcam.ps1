# Make sure the test webcam is running: smourier/VCamSample, a Windows 11
# Media Foundation virtual camera (MFCreateVirtualCamera) that draws a
# frame-counter test pattern, so mstsc can redirect it over RDPECAM. Runs
# in the desktop session (through session-run.ps1); writes vcam.txt.
#
# One-time install (admin), into a folder the Frame Server service can read:
#   $d = 'C:\ProgramData\MacRDPTest\vcam'
#   Invoke-WebRequest https://github.com/smourier/VCamSample/releases/download/v1.0.0.0/VCamSample.zip -OutFile $d\VCamSample.zip
#   Expand-Archive $d\VCamSample.zip $d; regsvr32 /s $d\VCamSampleSource.dll
# The camera exists only while VCamSample.exe runs (its "Close" stops it).
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = 'C:\ProgramData\MacRDPTest\vcam\VCamSample.exe'
$out = Join-Path $dir 'vcam.txt'
if (-not (Test-Path $exe)) { "not installed: $exe" | Out-File -Encoding ascii $out; exit 1 }
if (-not (Get-Process VCamSample -ErrorAction SilentlyContinue)) {
  Start-Process $exe -WindowStyle Minimized   # its window would otherwise sit over mstsc
  Start-Sleep 3
}
$p = Get-Process VCamSample -ErrorAction SilentlyContinue
if ($p) { "running $($p.Id)" | Out-File -Encoding ascii $out } else { 'failed to start' | Out-File -Encoding ascii $out; exit 1 }
