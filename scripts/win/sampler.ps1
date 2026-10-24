# Sample what mstsc shows (tools\MstscSampler.exe) in the desktop session:
# reads sampler.json ({"seconds", "interval"}) next to this script, writes
# runs\converge\samples.gz and the sampler's summary line to sampler.txt.
# Stops early once runs\converge\stop exists.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Get-Content (Join-Path $dir 'sampler.json') -Raw | ConvertFrom-Json
$out = Join-Path $dir 'runs\converge'
New-Item -ItemType Directory -Force $out | Out-Null
Remove-Item (Join-Path $out 'stop'), (Join-Path $out 'samples.gz') -ErrorAction SilentlyContinue
& (Join-Path $dir 'tools\MstscSampler.exe') (Join-Path $out 'samples.gz') $cfg.seconds $cfg.interval (Join-Path $out 'stop') 2>&1 |
  Out-File -Encoding ascii (Join-Path $dir 'sampler.txt')
