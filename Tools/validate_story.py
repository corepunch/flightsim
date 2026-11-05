#!/usr/bin/env python3
"""Validate every game's levels, campaign references and the art shipped with its story.

A game is a folder in Games/. Its Levels/<name>.json are what the game module
builds; Campaign/campaign.json lists missions by level and carries their
briefings and debriefs; Story/ holds the cast and rooms; Briefing/ the art.
"""
import json
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAIN = CAST = PLAYER = PORTRAITS = ROOMS = None   # per game, set by load_game


def game_chain(game):
    """The game's folder, then its base's (game.json "base"), as the engine searches them."""
    chain = [game]
    while (chain[-1] / "game.json").is_file():
        base = json.loads((chain[-1] / "game.json").read_text()).get("base")
        if not base or ROOT / "Games" / base in chain:
            break
        chain.append(ROOT / "Games" / base)
    return chain


def art(relative):
    """Briefing art on the search path."""
    for folder in CHAIN:
        if (folder / "Briefing" / relative).is_file():
            return folder / "Briefing" / relative
    raise AssertionError(f"No art Briefing/{relative} in {[folder.name for folder in CHAIN]}")


def load_game(game):
    global CHAIN, CAST, PLAYER, PORTRAITS, ROOMS
    CHAIN = game_chain(game)
    CAST = json.loads((game / "Story/characters.json").read_text())
    PLAYER = CAST["player"]
    PORTRAITS = {character["portrait"] for character in CAST["characters"].values()}
    ROOMS = json.loads((game / "Story/rooms.json").read_text())["rooms"]
# The page kinds the engine registers (Sources/Story/Story.m).
PAGE_KINDS = {"dialogue", "situation", "tactical", "objectives", "intel"}


def check_art(path, transparent=False):
    with path.open("rb") as image:
        header = image.read(26)
    assert header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR", path
    width, height = struct.unpack(">II", header[16:24])
    assert width >= 256 and height >= 256, f"Undersized art: {path}"
    if transparent:
        assert header[25] in (4, 6), f"No alpha channel: {path}"
    return width, height


def check_expression(portrait, expression):
    assert isinstance(expression, str) and re.fullmatch(r"[a-z]+(?:-[a-z]+)*", expression), expression
    variant = art(f"Expressions/{portrait}-{expression}.png")
    assert check_art(variant, transparent=True) == check_art(art(f"{portrait}.png")), (
        f"Expression canvas differs from base portrait: {variant}"
    )


def check_place(index, place, map_ids):
    """A map place is a contact id or an [x, z] point in metres."""
    if isinstance(place, str):
        assert place in map_ids, (index, place)
    else:
        assert isinstance(place, list) and len(place) == 2, (index, place)
        assert all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in place), (index, place)


def check_camera_and_labels(index, step, map_ids):
    """Optional "camera": {center, span}, "labels": [{text, at}] and "seconds" on a tactical step."""
    if "seconds" in step:
        seconds = step["seconds"]
        assert isinstance(seconds, (int, float)) and not isinstance(seconds, bool) and 0 <= seconds <= 60, (index, step)
    camera = step.get("camera")
    if camera is not None:
        assert isinstance(camera, dict) and camera and set(camera) <= {"center", "span"}, (index, camera)
        if "center" in camera:
            check_place(index, camera["center"], map_ids)
        if "span" in camera:
            span = camera["span"]
            assert isinstance(span, (int, float)) and not isinstance(span, bool) and span >= 200, (index, camera)
        assert "schematic" not in step, (index, "a schematic has no map camera")
    for label in step.get("labels", []):
        assert set(label) == {"text", "at"} and label["text"].strip(), (index, label)
        check_place(index, label["at"], map_ids)
        assert "schematic" not in step, (index, "a schematic has no map labels")


def validate_mission(mission):
    index = mission["level"]
    brief = mission["briefing"]
    scene = brief["dialogue"]
    cast = set(scene["cast"])
    epilogue = mission["debrief"]["dialogue"]
    assert len(scene["lines"]) >= 2 and epilogue, f"Mission {index}: missing story"
    assert cast == {line["portrait"] for line in scene["lines"]}, f"Mission {index}: cast mismatch"
    assert PLAYER in cast, f"Mission {index}: the player never speaks in the briefing"
    assert brief.get("officer", "") in CAST["characters"], f"Mission {index}: unknown officer"
    assert set(brief.get("pages", [])) <= PAGE_KINDS, f"Mission {index}: unknown page kind"
    for room in {scene.get("room"), mission["debrief"].get("room")} - {None}:
        assert room in ROOMS, f"Mission {index}: unknown room {room}"
    for conversation in (scene["lines"], epilogue):
        listeners = {line["portrait"] for line in conversation} - {PLAYER}
        for line in conversation:
            assert line["portrait"] in PORTRAITS, (index, line)
            assert line["speaker"].strip() and line["text"].strip(), (index, line)
            if line["portrait"] == PLAYER:
                assert line["listener"] in listeners, (index, line)
            if "expression" in line:
                check_expression(line["portrait"], line["expression"])
            if "listenerExpression" in line:
                listener = line["listener"] if line["portrait"] == PLAYER else PLAYER
                check_expression(listener, line["listenerExpression"])
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
        check_camera_and_labels(index, step, map_ids)
        if "schematic" in step:
            asset = entities[step["focus"]]["asset"]
            check_art(art(f'Schematics/{asset}-{step["schematic"]}.png'), transparent=True)

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
    for objective in objectives:
        assert set(objective.get("after", [])) <= objective_ids - {objective["id"]}, (index, objective)
        assert set(objective.get("targets", [])) <= units, (index, objective)
        assert set(objective.get("navs", [])) <= navs, (index, objective)
    # Events (level format v2): every name they use exists, and every held
    # unit has an event that spawns it. The mission runtime checks types,
    # triggers and actions (Tools/UnitChecks.m).
    named = units | set(friendly_pilots)
    # Units with an "arrival" spawn themselves; other held units need an event.
    held = {item["id"] for item in arrivals if item.get("hold") and "arrival" not in item}
    spawned_by_events = set()

    def check_when(when):
        for key, value in when.items():
            if key in ("all", "any"):
                for sub in value:
                    check_when(sub)
            elif key == "not":
                check_when(value)
            elif key == "objective":
                assert value in objective_ids, (index, when)
            elif key == "nav":
                assert value in navs, (index, when)
            elif key in ("spawned", "destroyed"):
                assert set([value] if isinstance(value, str) else value) <= named, (index, when)

    for item in arrivals:
        for cue in ("arrival", "departure"):
            if cue in item:
                check_when(item[cue]["when"])
    for wave in mission.get("waves", []):
        assert "mothership" not in wave or wave["mothership"] in entities, (index, wave)
    for event in mission.get("events", []):
        check_when(event["when"])
        for action in event["do"]:
            (kind, value), = action.items()
            if kind == "spawn":
                names = [value] if isinstance(value, str) else value
                assert set(names) <= held, (index, action)
                spawned_by_events.update(names)
            elif kind == "radio":
                assert value["text"].strip() and value["from"].strip(), (index, action)
            elif kind == "set_team":
                assert set(value) <= named, (index, action)
            elif kind == "destroy":
                assert set([value] if isinstance(value, str) else value) <= named, (index, action)
    assert held <= spawned_by_events, (index, held - spawned_by_events)
    return len(scene["lines"]) + len(epilogue), cast | {line["portrait"] for line in epilogue}


def load_levels(game):
    levels = {}
    for path in sorted((game / "Levels").glob("*.json")):
        level = json.loads(path.read_text())
        assert level.get("name") == path.stem, f"{path}: name differs from the file name"
        assert level.get("title", "").strip(), f"{path}: no title"
        levels[path.stem] = level
    assert levels, f"{game}: no levels"
    return levels


def validate_game(game):
    levels = load_levels(game)
    campaign_file = game / "Campaign/campaign.json"
    if not campaign_file.is_file():
        print(f"{game.name}: validated {len(levels)} levels (no campaign)")
        return
    load_game(game)
    campaign = json.loads(campaign_file.read_text())
    entries = campaign["missions"]
    names = [entry["level"] for entry in entries]
    assert len(set(names)) == len(names), f"{game.name}: a level appears twice in the campaign"
    assert set(names) <= set(levels), f"{game.name}: unknown levels {set(names) - set(levels)}"
    expected = list(range(1, len(entries) + 1))
    assert [index for chapter in campaign["story"]["chapters"] for index in chapter["missions"]] == expected
    defaults = campaign["storyDefaults"]
    assert defaults["officer"] in CAST["characters"] and defaults["room"] in ROOMS
    assert set(defaults["briefingPages"]) <= PAGE_KINDS
    for name, room in ROOMS.items():
        width, height = check_art(art(f'{room["image"]}.png'))
        assert room["size"] == [width, height], f"Room {name}: size differs from its art"
        assert len(room["bezel"]) >= 3 and all(0 <= x <= width and 0 <= y <= height for x, y in room["bezel"]), name
    for character in CAST["characters"].values():
        assert character["faces"] in ("left", "right") and character["name"].strip(), character
    for portrait in PORTRAITS:
        check_art(art(f"{portrait}.png"), transparent=True)
    beats, cast = 0, set()
    for entry in entries:
        count, speakers = validate_mission({**levels[entry["level"]], **entry})
        beats += count
        cast |= speakers
    assert cast == PORTRAITS, f"Unused cast: {PORTRAITS - cast}"
    print(f"{game.name}: validated {len(levels)} levels, {len(entries)} missions, "
          f"{len(cast)} illustrated speakers and {beats} story beats")


def main():
    games = sorted(path for path in (ROOT / "Games").iterdir() if path.is_dir())
    assert games, "no games in Games/"
    for game in games:
        validate_game(game)


if __name__ == "__main__":
    main()
