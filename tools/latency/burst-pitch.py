#!/usr/bin/env python3
"""Pitch and spacing of latbeep's bursts in a raw recording.

    burst-pitch.py <file> [rate] [freq]     # float32 interleaved stereo, 48000, 1000

Band-passes around the burst tone, finds each burst, and reports its pitch
from interpolated zero crossings over the burst's steady middle (away from
the filter's ring-up, which pulls naive estimates toward the centre
frequency) and the sample distance to the previous burst. latbeep plays
1000 Hz every 96000 samples at 48 kHz; anything else means the recording
was resampled or retimed somewhere before this point.
"""
import array
import math
import sys

path = sys.argv[1]
rate = int(sys.argv[2]) if len(sys.argv) > 2 else 48000
freq = float(sys.argv[3]) if len(sys.argv) > 3 else 1000.0

data = array.array("f")
with open(path, "rb") as f:
    data.frombytes(f.read())
mono = [(data[i] + data[i + 1]) / 2 for i in range(0, len(data) - 1, 2)]


def bandpass(xs, f0, q=4.0):
    w = 2 * math.pi * f0 / rate
    alpha = math.sin(w) / (2 * q)
    a0 = 1 + alpha
    b0, b2, a1, a2 = alpha / a0, -alpha / a0, -2 * math.cos(w) / a0, (1 - alpha) / a0
    x1 = x2 = y1 = y2 = 0.0
    out = []
    for x in xs:
        y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


y = bandpass(bandpass(mono, freq), freq)
env, decay = 0.0, math.exp(-1 / (0.005 * rate))
onsets, armed, quiet = [], True, 0
for i, v in enumerate(y):
    env = max(abs(v), env * decay)
    if armed and env > 0.02:
        onsets.append(i)
        armed, quiet = False, 0
    elif not armed:
        quiet = quiet + 1 if env < 0.006 else 0
        if quiet >= rate // 10:
            armed = True

print(f"{len(mono)} frames ({len(mono) / rate:.2f} s at {rate}), {len(onsets)} bursts")
prev = None
for o in onsets:
    lo, hi = o + int(0.012 * rate), o + int(0.032 * rate)
    seg = y[lo:hi]
    cross = [lo + i + seg[i] / (seg[i] - seg[i + 1])
             for i in range(len(seg) - 1) if (seg[i] < 0) != (seg[i + 1] < 0)]
    hz = (len(cross) - 1) / 2 / ((cross[-1] - cross[0]) / rate) if len(cross) > 2 else 0
    gap = "" if prev is None else f"  +{o - prev} samples"
    print(f"burst at {o / rate:8.3f} s  {hz:7.1f} Hz{gap}")
    prev = o
