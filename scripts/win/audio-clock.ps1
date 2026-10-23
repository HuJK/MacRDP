# Independent check of the default render device's clock: time PlaySync of
# a 2 s and a 32 s WAV of 48 kHz audio with a Stopwatch. The difference
# cancels the player's fixed start/drain overhead, so 30 s of audio over the
# extra wall time is the device's effective rate. Also lists the render
# endpoints so the default one can be told apart. Runs in the desktop
# session (through session-run.ps1, needs ~45 s); writes audio-clock.txt.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rate = 48000

function Time-Play($seconds) {
$wav = Join-Path $dir "clock-test-$seconds.wav"
# 16-bit mono 1 kHz tone at -20 dBFS.
$frames = $seconds * $rate
$ms = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $ms
$w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $frames * 2))
$w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1)
$w.Write([int]$rate); $w.Write([int]($rate * 2)); $w.Write([int16]2); $w.Write([int16]16)
$w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]($frames * 2))
for ($i = 0; $i -lt $frames; $i++) { $w.Write([int16](3276 * [Math]::Sin(2 * [Math]::PI * 1000 * $i / $rate))) }
[IO.File]::WriteAllBytes($wav, $ms.ToArray())

$player = New-Object Media.SoundPlayer $wav
$player.Load()
$sw = [Diagnostics.Stopwatch]::StartNew()
$player.PlaySync()
$sw.Stop()
$sw.Elapsed.TotalSeconds
}

$short = Time-Play 2
$long = Time-Play 32
$out = @("2 s took $($short.ToString('F3')) s, 32 s took $($long.ToString('F3')) s -> device clock ~$([int]($rate * 30 / ($long - $short))) Hz")
$out += Get-PnpDevice -Class AudioEndpoint | Where-Object Status -eq OK | ForEach-Object { "$($_.FriendlyName)  $($_.InstanceId)" }
$out | Out-File -Encoding ascii (Join-Path $dir 'audio-clock.txt')
