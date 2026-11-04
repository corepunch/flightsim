#!/usr/bin/env python3
"""Lightweight campaign consistency checks; no Apple SDK required."""
import json
from pathlib import Path

campaign = json.loads((Path(__file__).resolve().parents[1] / "Resources/Missions/missions.json").read_text())
missions = campaign["missions"]
assert len(missions) == 20, "Existing 20-mission campaign must be preserved"
known_portraits = {"Varn", "Okafor", "MiraCaptain", "Orin", "Imani", "Juno", "Rhea", "Lusk", "Kesh"}
for index, m in enumerate(missions, start=1):
    assert m["id"] == index, "Mission identifiers must remain sequential"
    assert m["objectives"] and m["briefing"]["steps"], f"Missing gameplay in mission {index}"
    lines = m["briefing"]["dialogue"]["lines"]
    assert len(lines) >= 2, f"Mission {index}: too few speaking beats"
    assert m["debrief"]["dialogue"], f"Mission {index}: missing post-mission story"
    for line in lines + m["debrief"]["dialogue"]:
        assert line["speaker"] and line["text"].strip(), f"Mission {index}: empty dialogue"
        assert line["portrait"] in known_portraits, f"Mission {index}: unknown cast {line['portrait']}"
    for step in m["briefing"]["steps"]:
        assert step["caption"], f"Mission {index}: missing tactical caption"
assert campaign["story"]["chapters"][-1]["missions"][-1] == 20
print(f"Validated {len(missions)} missions and {sum(len(m['briefing']['dialogue']['lines']) + len(m['debrief']['dialogue']) for m in missions)} story beats")
