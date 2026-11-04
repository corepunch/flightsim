#!/usr/bin/env python3
"""Validate campaign references and the art shipped with its story."""
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "Resources/Briefing"
PORTRAITS = {"Varn", "Okafor", "MiraCaptain", "Orin", "Imani", "Juno",
             "Rhea", "Lusk", "Kesh", "Hale", "Korr", "Lancer2", "Lancer3", "Lancer4",
             "Lancer1", "Lancer5", "Lancer6"}


def check_art(path, transparent=False):
    with path.open("rb") as image:
        header = image.read(26)
    assert header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR", path
    width, height = struct.unpack(">II", header[16:24])
    assert width >= 256 and height >= 256, f"Undersized art: {path}"
    if transparent:
        assert header[25] in (4, 6), f"No alpha channel: {path}"


def validate_mission(mission):
    index = mission["id"]
    brief = mission["briefing"]
    scene = brief["dialogue"]
    cast = set(scene["cast"])
    epilogue = mission["debrief"]["dialogue"]
    assert len(scene["lines"]) >= 2 and epilogue, f"Mission {index}: missing story"
    assert cast == {line["portrait"] for line in scene["lines"]}, f"Mission {index}: cast mismatch"
    check_art(ART / f'{scene["room"]}.png')
    for line in scene["lines"] + epilogue:
        assert line["portrait"] in PORTRAITS, (index, line)
        assert line["speaker"].strip() and line["text"].strip(), (index, line)
        if line["portrait"] == "Lancer1":
            assert line in epilogue and line["listener"] in PORTRAITS - {"Lancer1"}, (index, line)
    assert all(mission["debrief"][key].strip() for key in ("win", "lose")), index

    entities = {entity["id"]: entity for entity in mission["entities"]}
    arrivals = mission["entities"] + mission.get("waves", [])
    groups = {item["group"] for item in mission["entities"] + mission.get("fields", []) if "group" in item}
    units = {item["id"] for item in arrivals} | groups
    navs = {item["id"] for item in mission.get("navs", [])}
    map_ids = units | navs | {"start"}
    assert scene["focus"] in map_ids and brief["steps"], index
    for step in brief["steps"]:
        refs = set(step.get("show", [])) | set(step.get("route", []))
        if "focus" in step:
            refs.add(step["focus"])
        assert step["caption"].strip() and refs <= map_ids, (index, step, refs - map_ids)
        if "schematic" in step:
            asset = entities[step["focus"]]["asset"]
            check_art(ART / "Schematics" / f'{asset}-{step["schematic"]}.png', transparent=True)

    objectives = mission["objectives"]
    objective_ids = {item["id"] for item in objectives}
    assert objectives and len(objective_ids) == len(objectives), index
    friendly_pilots = []
    for wave in mission.get("waves", []):
        name, count = wave.get("name"), wave.get("count", 1)
        callsigns = wave.get("callsigns")
        if callsigns is not None:
            assert len(callsigns) == count and all(call.strip() for call in callsigns), (index, wave)
        elif name:
            callsigns = [name] if count == 1 else [f"{name} {seat + 2}" for seat in range(count)]
        if wave["team"] == "friend":
            friendly_pilots.extend(callsigns or [])
    if casualty := mission.get("casualty"):
        assert friendly_pilots.count(casualty["pilot"]) == 1, (index, casualty)
        assert casualty["after"] in objective_ids and casualty["text"].strip() and casualty["from"].strip(), (index, casualty)
    for objective in objectives:
        assert set(objective.get("after", [])) <= objective_ids - {objective["id"]}, (index, objective)
        assert set(objective.get("targets", [])) <= units, (index, objective)
        assert set(objective.get("navs", [])) <= navs, (index, objective)
        assert set(objective.get("onComplete", {}).get("setTeam", {})) <= units, (index, objective)
    for trigger in arrivals + mission["messages"]:
        assert "after" not in trigger or trigger["after"] in objective_ids, (index, trigger)
        assert "nav" not in trigger or trigger["nav"] in navs, (index, trigger)
        assert "spawn" not in trigger or trigger["spawn"] in units, (index, trigger)
    return len(scene["lines"]) + len(epilogue), cast | {line["portrait"] for line in epilogue}


def main():
    campaign = json.loads((ROOT / "Resources/Missions/missions.json").read_text())
    missions = campaign["missions"]
    expected = list(range(1, 21))
    assert [mission["id"] for mission in missions] == expected
    assert [index for chapter in campaign["story"]["chapters"] for index in chapter["missions"]] == expected
    for portrait in PORTRAITS:
        check_art(ART / f"{portrait}.png", transparent=True)
    beats, cast = 0, set()
    for mission in missions:
        count, speakers = validate_mission(mission)
        beats += count
        cast |= speakers
    assert cast == PORTRAITS, f"Unused cast: {PORTRAITS - cast}"
    print(f"Validated {len(missions)} missions, {len(cast)} illustrated speakers and {beats} story beats")


if __name__ == "__main__":
    main()
