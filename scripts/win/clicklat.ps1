# Click-to-photon latency through mstsc (tools\ClickLatency.exe) in the
# desktop session: reads clicklat.json ({"trials", "cx", "cy", "px", "py",
# "gap"}) next to this script, writes the per-trial latencies to
# runs\clicklat\latency.txt and the summary line to clicklat.txt.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Get-Content (Join-Path $dir 'clicklat.json') -Raw | ConvertFrom-Json
$out = Join-Path $dir 'runs\clicklat'
New-Item -ItemType Directory -Force $out | Out-Null
& (Join-Path $dir 'tools\ClickLatency.exe') (Join-Path $out 'latency.txt') $cfg.trials $cfg.cx $cfg.cy $cfg.px $cfg.py $cfg.gap 2>&1 |
  Out-File -Encoding ascii (Join-Path $dir 'clicklat.txt')
