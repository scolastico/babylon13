"""The station save contract: fixtures/station_state.json is one station checkpoint's state.json.

Both sides are held to it: the supervisor's restore (Driver.prepare_station) must accept it, and the
DM save engine's version constants must match it. fixtures/README.md documents every key.
"""
import json
from pathlib import Path
import re
import tempfile
import unittest

from supervisor import Driver

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIXTURE = HERE / "fixtures/station_state.json"
README = HERE / "fixtures/README.md"
DEFINES = ROOT / "modular_babylon/__DEFINES/babylon.dm"
KEYS = {"version", "generation", "next_id", "save_count", "records", "turfs", "levels", "map_config", "round",
        "players", "characters", "sun", "play_time"}
CHARACTER_KEYS = {"id", "type", "x", "y", "z", "on_shuttle", "real_name", "gender", "physique", "age", "species", "dna",
                  "job", "balance", "stat", "ghost", "bodyparts", "tox", "oxy", "records"}
CATALOG = {"maps": [
    {"id": "babylon", "name": "Babylon", "description": "d", "group": "babylon", "size": None, "build": "babylon",
     "map_json": None, "preview": None, "multiz": False},
    {"id": "fixture", "name": "Fixture Station", "description": "d", "group": "station", "size": None,
     "build": "station", "map_json": "fixture/fixture.json", "preview": None, "multiz": True}]}


def load_fixture():
    return json.loads(FIXTURE.read_text())


def dm_define(name):
    match = re.search(r"^#define %s (\d+)" % name, DEFINES.read_text(), re.M)
    return int(match.group(1)) if match else None


def level_z(level):
    return int(re.fullmatch(r"z(\d+)\.dmm", level["file"]).group(1))


class FixtureShape(unittest.TestCase):
    def test_top_level_keys(self):
        self.assertEqual(set(load_fixture()), KEYS)

    def test_every_key_is_documented(self):
        text = README.read_text()
        for key in KEYS:
            self.assertIn("| `%s` |" % key, text)

    def test_version_matches_the_dm_constants(self):
        self.assertEqual(load_fixture()["version"], dm_define("BABYLON_STATION_STATE_VERSION"))
        self.assertEqual(dm_define("BABYLON_STATION_STATE_VERSION"), 8)
        self.assertEqual(dm_define("BABYLON_STATE_VERSION"), 7)

    def test_layout_is_not_decided_by_version(self):
        """The layout (one map.dmm or z<N>.dmm per level) is writes_level_files(), never a version
        comparison: a Babylon format bump must not switch it to the station layout."""
        code = ROOT / "modular_babylon/code"
        for path in code.rglob("*.dm"):
            text = path.read_text()
            self.assertNotRegex(text, r"save_format_version\(\)\s*[<>]=?\s*BABYLON_STATION_STATE_VERSION", path.name)
            self.assertNotRegex(text, r"version\"?\]?\s*\|\|\s*1\)\s*[<>]=?\s*BABYLON_STATION_STATE_VERSION", path.name)
        engine = (code / "persistence.dm").read_text()
        self.assertRegex(engine, r"/datum/babylon_save/proc/writes_level_files\(\)\n\treturn FALSE")
        self.assertIn('return writes_level_files() ? "z[z].dmm" : "map.dmm"', engine)
        station = (code / "persistence_levels.dm").read_text()
        self.assertRegex(station, r"/datum/babylon_save/writes_level_files\(\)\n\treturn TRUE")

    def test_generation_name(self):
        state = load_fixture()
        self.assertRegex(state["generation"], r"^save-\d{8}-\d{6}-%d$" % state["save_count"])

    def test_levels(self):
        levels = load_fixture()["levels"]
        self.assertTrue(levels)
        for level in levels:
            self.assertEqual(set(level), {"file", "traits"})
            self.assertRegex(level["file"], r"^z\d+\.dmm$")
            # One entry of a tg map json's "traits": an object of z-level traits.
            self.assertIsInstance(level["traits"], dict)

    def test_records_and_turfs_name_a_saved_level(self):
        state = load_fixture()
        saved = {level_z(level) for level in state["levels"]}
        ids = {record["id"] for record in state["records"]}
        for record in state["records"]:
            self.assertLessEqual({"id", "type", "parent", "x", "y", "z", "fields", "references"}, set(record))
            self.assertIn(record["z"], saved)
            self.assertTrue(record["parent"] is None or record["parent"] in ids)
        for turf in state["turfs"]:
            self.assertLessEqual({"x", "y", "z", "temperature"}, set(turf))
            self.assertIn(turf["z"], saved)

    def test_round_and_characters(self):
        state = load_fixture()
        self.assertEqual(set(state["round"]), {"started", "station_time"})
        self.assertIsInstance(state["characters"], dict)
        self.assertIsInstance(state["players"], dict)
        record_ids = {record["id"] for record in state["records"]}
        ids = set(record_ids)
        for ckey, character in state["characters"].items():
            self.assertEqual(set(character), CHARACTER_KEYS)
            # A player's character, or a body left behind ("#<save id>", no player).
            if ckey.startswith("#"):
                self.assertEqual(ckey, "#" + character["id"])
            else:
                self.assertIn(ckey, state["players"])
            # A character and its items are kept apart from the levels' records (a reused level
            # must never carry them), in the same id space.
            own = {character["id"]} | {record["id"] for record in character["records"]}
            self.assertEqual(own & ids, set())
            ids |= own
            self.assertTrue(all(int(i[2:]) < state["next_id"] for i in own))
            parents = {character["id"]} | {record["id"] for record in character["records"]}
            for record in character["records"]:
                self.assertIn(record["parent"], parents)
            worn = [record for record in character["records"] if record["parent"] == character["id"]]
            self.assertTrue(all(("slot" in record) != ("hand" in record) for record in worn))

    def test_map_config_is_a_tg_map_json(self):
        config = load_fixture()["map_config"]
        for key in ("map_name", "map_path", "map_file"):
            self.assertIn(key, config)


class SupervisorReadsTheFixture(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        base = Path(temp.name)
        self.data = base / "data"
        template = base / "template"
        (template / "_maps/babylon").mkdir(parents=True)
        (template / "_maps/fixture").mkdir()
        (template / "_maps/babylon/catalog.json").write_text(json.dumps(CATALOG))
        (template / "_maps/fixture/fixture.json").write_text(json.dumps(load_fixture()["map_config"]))
        (template / "babylon-station.dmb").write_text("station dmb")
        config = base / "config"
        config.mkdir()
        self.driver = Driver(dict(data_directory=str(self.data), template_directory=str(template),
                                  config_directory=str(config), dreamdaemon="unused", listen_port=1360,
                                  lobby_address="byond://localhost:1361"))
        self.state = load_fixture()
        saves = self.data / "worlds/w1/data/babylon/saves"
        generation = saves / self.state["generation"]
        generation.mkdir(parents=True)
        for level in self.state["levels"]:
            (generation / level["file"]).write_text("map " + level["file"])
        (generation / "state.json").write_text(FIXTURE.read_text())
        (saves / "latest.json").write_text(json.dumps({"generation": self.state["generation"]}))

    def prepare(self):
        world = dict(id="w1", owner="o", name="W", map="fixture", persistent=1, creative=0, kind="world",
                     tutorial=None)
        self.driver.prepare(world, {"id": "run", "port": 1400, "secret": "test-only"})
        return self.data / "worlds/w1"

    def test_restore_stages_the_saved_levels(self):
        root = self.prepare()
        files = [level["file"] for level in self.state["levels"]]
        self.assertEqual(sorted(p.name for p in (root / "_maps/babylon/saved").iterdir()), sorted(files))
        next_map = json.loads((root / "data/next_map.json").read_text())
        expected = dict(self.state["map_config"], map_path="babylon/saved", map_file=files,
                        traits=[level["traits"] for level in self.state["levels"]])
        self.assertEqual(next_map, expected)
        self.assertEqual(json.loads((root / "data/babylon/resume-state.json").read_text()), self.state)


if __name__ == "__main__":
    unittest.main()
