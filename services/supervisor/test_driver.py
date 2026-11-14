import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import parse_qs

from supervisor import Driver, Denied

CATALOG = {"maps": [
    {"id": "babylon", "name": "Babylon", "description": "d", "group": "babylon", "size": None, "build": "babylon",
     "map_json": None, "preview": None, "multiz": False},
    {"id": "box", "name": "Box", "description": "d", "group": "station", "size": None, "build": "station",
     "map_json": "box/box.json", "preview": None, "multiz": True}]}
BOX_JSON = '{"map_name": "Box", "map_path": "map_files/box", "map_file": ["a.dmm"]}'
RUN = {"id": "run", "port": 1400, "secret": "test-only"}


class DriverFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.data = base / "data"
        self.template = base / "template"
        (self.template / "_maps/babylon").mkdir(parents=True)
        (self.template / "_maps/box").mkdir()
        (self.template / "_maps/babylon/catalog.json").write_text(json.dumps(CATALOG))
        (self.template / "_maps/box/box.json").write_text(BOX_JSON)
        (self.template / "babylon.dmb").write_text("dmb")
        (self.template / "babylon-station.dmb").write_text("station dmb")
        config = base / "config"
        config.mkdir()
        self.driver = Driver(dict(data_directory=str(self.data), template_directory=str(self.template),
                                  config_directory=str(config), dreamdaemon="unused", listen_port=1360,
                                  lobby_address="byond://localhost:1361"))

    def world(self, **extra):
        return dict(dict(id="w1", owner="o", name="W", map="box", persistent=1, creative=0, kind="world",
                         tutorial=None), **extra)

    def root(self):
        return self.data / "worlds/w1"

    def generation(self, directory, files, state=None):
        directory.mkdir(parents=True)
        for name in files:
            (directory / name).write_text("map " + name)
        (directory / "state.json").write_text(json.dumps(state or {}))

    def station_state(self):
        return dict(levels=[{"file": "z2.dmm", "traits": ["Station"]}, {"file": "z3.dmm", "traits": ["Mining"]}],
                    map_config={"map_name": "Box", "map_path": "map_files/box", "map_file": ["a.dmm"], "extra": 1})

    def save_generation(self, state, files):
        saves = self.root() / "data/babylon/saves"
        self.generation(saves / "save-20261109-120000-1", files, state)
        (saves / "latest.json").write_text('{"generation": "save-20261109-120000-1"}')


class StationPrepare(DriverFixture):
    def test_prepare_station_fresh_writes_next_map(self):
        stale = self.root() / "_maps/babylon/saved"
        stale.mkdir(parents=True)
        (stale / "old.dmm").write_text("x")
        resume = self.root() / "data/babylon/resume-state.json"
        resume.parent.mkdir(parents=True)
        resume.write_text("{}")
        self.driver.prepare(self.world(), RUN)
        self.assertEqual((self.root() / "data/next_map.json").read_text(), BOX_JSON)
        self.assertFalse(resume.exists())
        self.assertFalse(stale.exists())

    def test_prepare_station_restore_multiz(self):
        self.save_generation(self.station_state(), ["z2.dmm", "z3.dmm"])
        self.driver.prepare(self.world(), RUN)
        saved = self.root() / "_maps/babylon/saved"
        self.assertEqual(sorted(p.name for p in saved.iterdir()), ["z2.dmm", "z3.dmm"])
        next_map = json.loads((self.root() / "data/next_map.json").read_text())
        self.assertEqual(next_map, {"map_name": "Box", "map_path": "babylon/saved", "map_file": ["z2.dmm", "z3.dmm"],
                                    "extra": 1, "traits": [["Station"], ["Mining"]]})
        self.assertTrue((self.root() / "data/babylon/resume-state.json").is_file())

    def test_station_restore_rejects_unsafe_level_names(self):
        state = self.station_state()
        state["levels"][0]["file"] = "../z2.dmm"
        self.save_generation(state, ["z3.dmm"])
        with self.assertRaises(Denied):
            self.driver.prepare(self.world(), RUN)

    def test_station_needs_dmb_and_map_file(self):
        (self.template / "babylon-station.dmb").unlink()
        with self.assertRaisesRegex(Denied, "Compile babylon-station.dme"):
            self.driver.prepare(self.world(), RUN)
        (self.template / "babylon-station.dmb").write_text("x")
        (self.template / "_maps/box/box.json").unlink()
        (self.root() / "_maps/box/box.json").unlink()
        with self.assertRaisesRegex(Denied, "box/box.json"):
            self.driver.prepare(self.world(), RUN)

    def test_non_persistent_station_ignores_saves(self):
        self.save_generation(self.station_state(), ["z2.dmm", "z3.dmm"])
        self.driver.prepare(self.world(persistent=0), RUN)
        self.assertEqual((self.root() / "data/next_map.json").read_text(), BOX_JSON)


class BabylonPrepare(DriverFixture):
    def test_prepare_non_persistent_ignores_saves(self):
        self.save_generation({"save_count": 1}, ["map.dmm"])
        world = dict(self.world(), map="babylon", persistent=0)
        with patch("supervisor.prepare_fresh_map") as fresh:
            self.driver.prepare(world, RUN)
        fresh.assert_called_once()
        self.assertIsNone(self.driver.restore_source(world))

    def test_persistent_babylon_restores_latest(self):
        self.save_generation({"save_count": 1}, ["map.dmm"])
        self.driver.prepare(dict(self.world(), map="babylon"), RUN)
        self.assertEqual((self.root() / "_maps/babylon/active.dmm").read_text(), "map map.dmm")

    def test_prepare_tutorial_uses_snapshot(self):
        snapshot = self.data / "tutorials/pending/tut1/save"
        self.generation(snapshot, ["map.dmm"], {"save_count": 9})
        self.save_generation({"save_count": 1}, ["map.dmm"])
        world = dict(self.world(), map="babylon", kind="tutorial", tutorial="tut1", persistent=0)
        self.assertEqual(self.driver.restore_source(world), snapshot.resolve())
        self.driver.prepare(world, RUN)
        self.assertEqual(json.loads((self.root() / "data/babylon/resume-state.json").read_text())["save_count"], 9)
        published = self.data / "tutorials/published/tut1/save"
        self.generation(published, ["map.dmm"], {"save_count": 10})
        self.assertEqual(self.driver.restore_source(world), published.resolve())

    def test_tutorial_station_snapshot_and_missing(self):
        world = self.world(kind="tutorial_edit", tutorial="tut1")
        with self.assertRaises(Denied):
            self.driver.restore_source(world)
        self.generation(self.data / "tutorials/published/tut1/save", ["z2.dmm", "z3.dmm"], self.station_state())
        self.driver.prepare(world, RUN)
        self.assertTrue((self.root() / "_maps/babylon/saved/z3.dmm").is_file())
        with self.assertRaises(Denied):
            self.driver.restore_source(dict(world, tutorial="../x"))


@unittest.skipIf(os.name == "nt", "symlinks")
class SharedCharacters(DriverFixture):
    def test_prepare_links_player_saves(self):
        local = self.root() / "data/player_saves/a/alice"
        local.mkdir(parents=True)
        (local / "alice.sav").write_text("local")
        (local / "extra.sav").write_text("extra")
        central = self.data / "player_saves/a/alice"
        central.mkdir(parents=True)
        (central / "alice.sav").write_text("central")
        self.driver.prepare(self.world(), RUN)
        link = self.root() / "data/player_saves"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), (self.data / "player_saves").resolve())
        self.assertEqual((central / "alice.sav").read_text(), "central")
        self.assertEqual((central / "extra.sav").read_text(), "extra")
        self.driver.prepare(self.world(), RUN)
        self.assertTrue(link.is_symlink())


class Params(DriverFixture):
    def launch(self, world):
        with patch("supervisor.subprocess.Popen", return_value=SimpleNamespace(pid=1)) as popen, \
                patch("supervisor.Follower"):
            self.driver.start(world, RUN)
        arguments = popen.call_args.args[0]
        return arguments, parse_qs(arguments[arguments.index("-params") + 1], keep_blank_values=True)

    def test_start_params_include_flags(self):
        self.generation(self.data / "tutorials/pending/t1/save", ["z2.dmm", "z3.dmm"], self.station_state())
        arguments, params = self.launch(self.world(creative=1, persistent=0, kind="tutorial", tutorial="t1"))
        self.assertEqual(arguments[1], "babylon-station.dmb")
        self.assertEqual({k: v[0] for k, v in params.items() if k.startswith("babylon-") and k in (
            "babylon-build", "babylon-persistent", "babylon-creative", "babylon-kind", "babylon-tutorial",
            "babylon-map")}, {"babylon-build": "station", "babylon-persistent": "0", "babylon-creative": "1",
                              "babylon-kind": "tutorial", "babylon-tutorial": "t1", "babylon-map": "box"})
        with patch("supervisor.prepare_fresh_map"):
            arguments, params = self.launch(dict(self.world(), map="babylon"))
        self.assertEqual(arguments[1], "babylon.dmb")
        self.assertEqual((params["babylon-build"], params["babylon-tutorial"], params["babylon-persistent"]),
                         (["babylon"], [""], ["1"]))


if __name__ == "__main__":
    unittest.main()
