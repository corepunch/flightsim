#!/usr/bin/env python3
"""Exercise chronology failures that ordinary file/reference validation cannot catch."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("validate_story", Path(__file__).with_name("validate_story.py"))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
GAME = validator.ROOT / "Games/KestrelFrontier"


class ContinuityChecks(unittest.TestCase):
    def setUp(self):
        self.entries = json.loads((GAME / "Campaign/campaign.json").read_text())["missions"]
        self.rules = json.loads((GAME / "Story/continuity.json").read_text())
        self.cast = json.loads((GAME / "Story/characters.json").read_text())["characters"]

    def validate(self):
        validator.validate_continuity(self.entries, self.rules, self.cast)

    def test_shipped_campaign(self):
        self.validate()

    def test_rescue_witness_cannot_speak_before_pickup(self):
        line = copy.deepcopy(self.entries[6]["debrief"]["dialogue"][0])
        self.entries[0]["briefing"]["dialogue"]["lines"].append(line)
        with self.assertRaisesRegex(AssertionError, "Juno appears outside"):
            self.validate()

    def test_dead_wingman_cannot_return_as_a_listener(self):
        self.entries[19]["debrief"]["dialogue"][-1]["listener"] = "Lancer2"
        with self.assertRaisesRegex(AssertionError, "Lancer2 appears outside"):
            self.validate()

    def test_rescued_character_must_return(self):
        for phase in (self.entries[10]["briefing"]["dialogue"]["lines"], self.entries[10]["debrief"]["dialogue"]):
            phase[:] = [line for line in phase if line["portrait"] != "Juno" and line.get("listener") != "Juno"]
        with self.assertRaisesRegex(AssertionError, "missing Juno"):
            self.validate()

    def test_remote_prisoner_can_speak_during_rescue(self):
        self.rules["characters"] = {"Kesh": self.rules["characters"]["Kesh"]}
        self.validate()

    def test_unknown_scene_is_rejected(self):
        self.rules["characters"]["Juno"]["availableFrom"]["level"] = "missing"
        with self.assertRaisesRegex(AssertionError, "unknown level"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
