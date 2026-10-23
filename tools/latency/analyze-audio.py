#!/usr/bin/env python3
"""Join one audio-out-latency run into per-burst end-to-end latency.

    analyze-audio.py <run-dir>

Inputs, all written by audio-out-latency.sh into <run-dir>:
  beeps.csv    latbeep: index,unix_ns - burst presented at the Mac's output (Mac clock)
  onsets.csv   LoopbackOnsets: unix_ns,amplitude - burst rendered by the client (client clock)
  sync.csv     LoopbackOnsets: phase,send_unix_ns,mac_unix_ns,recv_unix_ns clock exchange
               (absent for a --self-play run: bursts and onsets share one clock)
  macrdp.log   MacRDP's unified log, for its own RDPSND lag estimate (optional)
  vm-tz        the VM's UTC offset (`date +%z`), which its log timestamps are in

Prints a summary plus a per-burst table and writes latency.csv.
"""
import csv
import datetime
import os
import re
import statistics
import sys

run = sys.argv[1]


def rows(name):
    with open(os.path.join(run, name), newline="") as f:
        return list(csv.DictReader(f))


beeps = [(int(r["index"]), int(r["unix_ns"])) for r in rows("beeps.csv")]
onsets = sorted(int(r["unix_ns"]) for r in rows("onsets.csv"))
sync = rows("sync.csv") if os.path.exists(os.path.join(run, "sync.csv")) else []


# Clock offset (Mac minus client) from the min-RTT exchange of each phase,
# interpolated linearly between the two to absorb drift over the run.
def best(phase):
    samples = [r for r in sync if r["phase"] == phase]
    if not samples:
        return None
    r = min(samples, key=lambda r: int(r["recv_unix_ns"]) - int(r["send_unix_ns"]))
    send, mac, recv = (int(r[k]) for k in ("send_unix_ns", "mac_unix_ns", "recv_unix_ns"))
    mid = (send + recv) // 2
    return mid, mac - mid, recv - send


pre, post = best("pre"), best("post")
anchor = pre or post or (0, 0, 0)   # no exchange: one clock, offset 0


def to_client(t_mac):
    t = t_mac - anchor[1]
    if pre and post and post[0] != pre[0]:
        t = t_mac - (pre[1] + (t - pre[0]) * (post[1] - pre[1]) / (post[0] - pre[0]))
    return t


client_beeps = [(k, to_client(t)) for k, t in beeps]

# MacRDP's RDPSND lag samples, mapped onto the client clock.
tz = "+0000"
if os.path.exists(os.path.join(run, "vm-tz")):
    tz = open(os.path.join(run, "vm-tz")).read().strip() or tz
tz_s = (1 if tz[0] == "+" else -1) * (int(tz[1:3]) * 3600 + int(tz[3:5]) * 60)
lag_re = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+).*RDPSND progress: .*?lag=(-?\d+)ms .*?drift=(-?\d+)ms")
server = []
log_path = os.path.join(run, "macrdp.log")
for line in (open(log_path, errors="replace") if os.path.exists(log_path) else []):
    m = lag_re.search(line)
    if m:
        local = datetime.datetime.strptime(m[1], "%Y-%m-%d %H:%M:%S.%f")
        unix_ns = round((local - datetime.datetime(1970, 1, 1)).total_seconds() * 1e9) - tz_s * 10**9
        server.append((to_client(unix_ns), int(m[2]), int(m[3])))


def server_at(t):
    last = None
    for s in server:
        if s[0] > t:
            break
        last = s
    return last


# Pair onsets with bursts. Latency drifts slowly, so each onset takes the
# not-yet-paired burst whose latency is closest to the previous one; the
# first takes the latest burst before it. This survives dropped bursts and
# latency growing past the burst interval.
paired = {}
prev = None
for o in onsets:
    cands = [(k, t) for k, t in client_beeps if k not in paired and t - 50e6 <= o <= t + 30e9]
    if not cands:
        continue
    if prev is None:
        k, t = max((c for c in cands if c[1] <= o + 50e6), key=lambda c: c[1], default=cands[0])
    else:
        k, t = min(cands, key=lambda c: abs((o - c[1]) - prev))
    paired[k] = o
    prev = o - t

t0 = client_beeps[0][1] if client_beeps else 0
table = []
for k, t in client_beeps:
    o = paired.get(k)
    srv = server_at(o if o else t)
    table.append((k, (t - t0) / 1e9, (o - t) / 1e6 if o else None,
                  srv[1] if srv else None, srv[2] if srv else None))

with open(os.path.join(run, "latency.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["index", "t_s", "latency_ms", "server_lag_ms", "server_drift_ms"])
    for r in table:
        w.writerow([r[0], f"{r[1]:.2f}", "" if r[2] is None else f"{r[2]:.1f}",
                    "" if r[3] is None else r[3], "" if r[4] is None else r[4]])

lat = [r[2] for r in table if r[2] is not None]
if pre or post:
    print(f"clock: offset {anchor[1] / 1e6:+.1f} ms (rtt {anchor[2] / 1e6:.1f} ms)"
          + (f", drift over run {(post[1] - pre[1]) / 1e6:+.2f} ms" if pre and post else ""))
else:
    print("clock: single clock (self-play)")
print(f"bursts {len(table)}, heard {len(lat)}, missing {len(table) - len(lat)}, onsets {len(onsets)}")
if lat:
    q = max(1, len(lat) // 4)
    pts = [(r[1], r[2]) for r in table if r[2] is not None]
    mx, my = statistics.mean(p[0] for p in pts), statistics.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    slope = sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx * 60 if sxx else 0
    print(f"latency ms: min {min(lat):.0f}  median {statistics.median(lat):.0f}  "
          f"p90 {sorted(lat)[int(len(lat) * 0.9) - 1 if len(lat) > 1 else 0]:.0f}  max {max(lat):.0f}")
    print(f"trend: first quarter median {statistics.median(lat[:q]):.0f} ms -> last quarter "
          f"{statistics.median(lat[-q:]):.0f} ms, slope {slope:+.1f} ms/min")
print()
print(f"{'#':>4} {'t(s)':>7} {'e2e ms':>8} {'srv lag':>8} {'srv drift':>9}")
step = max(1, len(table) // 40)
for r in table[::step]:
    e2e = "  (miss)" if r[2] is None else f"{r[2]:8.0f}"
    print(f"{r[0]:>4} {r[1]:7.1f} {e2e} {'' if r[3] is None else r[3]:>8} {'' if r[4] is None else r[4]:>9}")
