#!/usr/bin/env python3
"""
ringo claude 起動シーンの合成 asciinema キャストを生成する。
"""
import json, random
from pathlib import Path

OUT = Path(__file__).parent / "demo-claude-launch.cast"

COLS, ROWS = 110, 34

header = {
    "version": 3,
    "width": COLS,
    "height": ROWS,
    "term": {"cols": COLS, "rows": ROWS},
    "title": "ringo claude — launch",
}

events = []
t = 0.0

def ev(data, delta=0.0):
    global t
    t += delta
    events.append([round(t, 4), "o", data])

ev("\x1b[2J\x1b[H", delta=0.1)
ev("❯ ", delta=0.3)

for ch in "ringo claude":
    delay = random.uniform(0.06, 0.13)
    ev(ch, delta=delay)

ev("\r\n", delta=0.25)
ev("\x1b[2mStarting Apple Foundation Models bridge…\x1b[0m\r\n", delta=0.18)
ev("\x1b[2mLoading model: claude-afm-local\x1b[0m\r\n", delta=0.55)
ev("\x1b[2mBridge ready  ✔\x1b[0m\r\n", delta=0.80)
ev("\r\n", delta=0.30)
ev("\x1b[2mLaunching Claude Code…\x1b[0m\r\n", delta=0.20)
ev("", delta=1.0)

with OUT.open("w") as f:
    f.write(json.dumps(header) + "\n")
    for row in events:
        f.write(json.dumps(row) + "\n")

total = round(t, 2)
print(f"✅ Generated: {OUT}  ({len(events)} events, {total}s)")
