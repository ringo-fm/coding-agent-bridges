#!/usr/bin/env python3
"""
demo-launch.cast と demo-main.cast を結合して demo-merged.cast を生成する。
"""
import json, sys
from pathlib import Path

DOCS = Path(__file__).parent
LAUNCH = DOCS / "demo-launch.cast"
MAIN   = DOCS / "demo-main.cast"
OUT    = DOCS / "demo-merged.cast"
GAP    = 1.0  # 2 キャスト間の間隔（秒）

def read_cast(path):
    lines = path.read_text().splitlines()
    header = json.loads(lines[0])
    events = [json.loads(l) for l in lines[1:] if l.strip()]
    return header, events

def write_cast(path, header, events):
    with path.open("w") as f:
        f.write(json.dumps(header) + "\n")
        for ev in events:
            f.write(json.dumps(ev) + "\n")

h1, ev1 = read_cast(LAUNCH)
h2, ev2 = read_cast(MAIN)

# launch の最終タイムスタンプ
end1 = ev1[-1][0] if ev1 else 0.0
offset = end1 + GAP

# header は launch のものをベースに cols/rows を統一
header = dict(h1)
header["title"] = "ringo codex — Apple Foundation Models"
# demo-main の cols/rows で上書き（より正確）
header["term"] = {
    "cols": 80,
    "rows": 24,
}
header.pop("command", None)

# launch イベント
merged = [[t, typ, data] for t, typ, data in ev1]

# main イベントのタイムスタンプをシフト
for t, typ, data in ev2:
    merged.append([round(t + offset, 6), typ, data])

write_cast(OUT, header, merged)
print(f"✅ Merged: {OUT}  ({len(ev1)} + {len(ev2)} events, total {len(merged)})")
