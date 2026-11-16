import json
import os
from pathlib import Path
import shutil
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
STATION_FIXTURE = Path(__file__).resolve().parent / "fixtures/station_state.json"


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
        # The station save contract (fixtures/station_state.json): levels z2.dmm and z3.dmm.
        return json.loads(STATION_FIXTURE.read_text())

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
        state = self.station_state()
        self.assertEqual(next_map, dict(state["map_config"], map_path="babylon/saved", map_file=["z2.dmm", "z3.dmm"],
                                        traits=[level["traits"] for level in state["levels"]]))
        self.assertTrue((self.root() / "data/babylon/resume-state.json").is_file())

    def test_station_restore_accepts_a_trait_list_per_level_file(self):
        # A level file holding several z carries one trait object per z, as a multi-z map json does.
        state = self.station_state()
        state["levels"][0]["traits"] = [{"Station": 1, "Up": 1}, {"Station": 1, "Down": 1}]
        self.save_generation(state, ["z2.dmm", "z3.dmm"])
        self.driver.prepare(self.world(), RUN)
        next_map = json.loads((self.root() / "data/next_map.json").read_text())
        self.assertEqual(next_map["traits"], [{"Station": 1, "Up": 1}, {"Station": 1, "Down": 1},
                                              state["levels"][1]["traits"]])

    def test_station_restore_rejects_malformed_traits(self):
        for traits in (["Station"], "Station", [], [{"Station": 1}, "Mining"], 5):
            saves = self.root() / "data/babylon/saves"
            shutil.rmtree(saves, ignore_errors=True)
            state = self.station_state()
            state["levels"][0]["traits"] = traits
            self.save_generation(state, ["z2.dmm", "z3.dmm"])
            with self.assertRaises(Denied, msg=repr(traits)):
                self.driver.prepare(self.world(), RUN)

    def test_station_restore_rejects_unsafe_level_names(self):
        state = self.station_state()
        state["levels"][0]["file"] = "../z2.dmm"
        self.save_generation(state, ["z3.dmm"])
        with self.assertRaises(Denied):
            self.driver.prepare(self.world(), RUN)

    def test_station_corrupt_or_non_dict_state_is_denied(self):
        for text in ("{not json", "[1, 2]", "5"):
            saves = self.root() / "data/babylon/saves"
            shutil.rmtree(saves, ignore_errors=True)
            self.save_generation({}, ["z2.dmm"])
            (saves / "save-20261109-120000-1/state.json").write_text(text)
            with self.assertRaises(Denied):
                self.driver.prepare(self.world(), RUN)

    def test_station_invalid_level_keeps_previous_saved_levels(self):
        saved = self.root() / "_maps/babylon/saved"
        saved.mkdir(parents=True)
        (saved / "keep.dmm").write_text("old")
        self.save_generation(self.station_state(), ["z2.dmm"])  # z3.dmm is missing
        with self.assertRaises(Denied):
            self.driver.prepare(self.world(), RUN)
        self.assertEqual((saved / "keep.dmm").read_text(), "old")
        self.assertFalse((saved.parent / "saved.staging").exists())

    @unittest.skipIf(os.name == "nt", "symlinks")
    def test_station_rejects_symlinked_level_file(self):
        self.save_generation(self.station_state(), ["z3.dmm"])
        generation = self.root() / "data/babylon/saves/save-20261109-120000-1"
        outside = Path(self.temp.name) / "outside.dmm"
        outside.write_text("secret")
        (generation / "z2.dmm").symlink_to(outside)
        with self.assertRaises(Denied):
            self.driver.prepare(self.world(), RUN)

    def test_babylon_snapshot_without_map_is_denied(self):
        self.generation(self.data / "tutorials/pending/tut1/save", [], {"save_count": 9})
        world = dict(self.world(), map="babylon", kind="tutorial", tutorial="tut1", persistent=0)
        with self.assertRaisesRegex(Denied, "map.dmm"):
            self.driver.prepare(world, RUN)

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


class Kill(DriverFixture):
    def test_kill_by_pid_waits_for_the_exit(self):
        alive = iter([True, True, True, False])
        with patch.object(self.driver, "alive", side_effect=lambda run: next(alive)), \
                patch("supervisor.os.kill") as kill, patch("supervisor.time.sleep"):
            self.driver.kill(dict(id="r", pid=4242))
        kill.assert_called_once()
        self.assertEqual(next(alive, "done"), "done")

    def test_kill_by_pid_gives_up_after_the_timeout(self):
        with patch.object(self.driver, "alive", return_value=True), patch("supervisor.os.kill"), \
                patch("supervisor.time.sleep"), patch("supervisor.time.monotonic", side_effect=[0, 0, 5, 40]):
            with self.assertRaises(TimeoutError):
                self.driver.kill(dict(id="r", pid=4242), timeout=30)


class BabylonPrepare(DriverFixture):
    def test_prepare_non_persistent_ignores_saves(self):
        self.save_generation({"save_count": 1}, ["map.dmm"])
        world = dict(self.world(), map="babylon", persistent=0)
        with patch("supervisor.prepare_fresh_map") as fresh:
            self.driver.prepare(world, RUN)
        fresh.assert_called_once()
        self.assertIsNone(self.driver.restore_source(world))

    def test_damaged_latest_pointer_is_a_clear_denial(self):
        # Review C-M5: a damaged latest.json names what the owner can do, not a generic failure.
        saves = self.root() / "data/babylon/saves"
        saves.mkdir(parents=True)
        for text in ("{", "[]", "{}", '{"generation": 5}'):
            (saves / "latest.json").write_text(text)
            with self.assertRaisesRegex(Denied, "checkpoint pointer is damaged|Invalid checkpoint generation"):
                self.driver.restore_source(self.world())

    def test_persistent_babylon_restores_latest(self):
        self.save_generation({"save_count": 1}, ["map.dmm"])
        self.driver.prepare(dict(self.world(), map="babylon"), RUN)
        self.assertEqual((self.root() / "_maps/babylon/active.dmm").read_text(), "map map.dmm")

    def test_legacy_babylon_fixtures_are_staged(self):
        """The golden pre-rework checkpoints (fixtures/babylon_v7, babylon_v5) are staged unchanged;
        smoke_native.py restores them in a real world."""
        fixtures = Path(__file__).resolve().parent / "fixtures"
        for state_dir, version in (("babylon_v7", 7), ("babylon_v5", 5)):
            with self.subTest(version=version):
                state = json.loads((fixtures / state_dir / "state.json").read_text())
                self.assertEqual(state["version"], version)
                self.assertNotIn("levels", state)
                self.assertEqual("players" in state, version >= 6)
                self.assertEqual((state["builder"], state["generation"]), ("bb1620", "save-20261114-165619-1"))
                saves = self.root() / "data/babylon/saves"
                shutil.rmtree(saves, ignore_errors=True)
                generation = saves / state["generation"]
                generation.mkdir(parents=True)
                shutil.copy2(fixtures / "babylon_v7/map.dmm", generation / "map.dmm")
                shutil.copy2(fixtures / state_dir / "state.json", generation / "state.json")
                (saves / "latest.json").write_text(json.dumps({"generation": state["generation"]}))
                self.driver.prepare(dict(self.world(), map="babylon"), RUN)
                self.assertEqual((self.root() / "_maps/babylon/active.dmm").read_bytes(),
                                 (fixtures / "babylon_v7/map.dmm").read_bytes())
                self.assertEqual(json.loads((self.root() / "data/babylon/resume-state.json").read_text()), state)

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
        # Station worlds get their own autosave interval (default 30 minutes); Babylon keeps its 15.
        self.assertNotIn("babylon-autosave-minutes", params)
        _, params = self.launch(self.world())
        self.assertEqual(params["babylon-autosave-minutes"], ["30"])
        self.driver.config["station_autosave_minutes"] = 45
        _, params = self.launch(self.world())
        self.assertEqual(params["babylon-autosave-minutes"], ["45"])

    def test_tutorial_worlds_get_the_tutorial_title(self):
        # BabylonTutorialComplete shows the real title (babylon-tutorial-title), not the id.
        self.generation(self.data / "tutorials/pending/t1/save", ["z2.dmm", "z3.dmm"], self.station_state())
        (self.data / "tutorials/pending/t1/meta.json").write_text(json.dumps({"title": "First \u202eaid\n" + "x" * 80}))
        for kind in ("tutorial", "tutorial_edit"):
            _, params = self.launch(self.world(creative=1, persistent=0, kind=kind, tutorial="t1"))
            self.assertEqual(params["babylon-tutorial-title"], [("First aid " + "x" * 80)[:60]])
        # Ordinary worlds, unreadable meta and a linked meta.json give an empty title.
        _, params = self.launch(self.world())
        self.assertEqual(params["babylon-tutorial-title"], [""])
        (self.data / "tutorials/pending/t1/meta.json").write_text("{broken")
        _, params = self.launch(self.world(kind="tutorial", tutorial="t1"))
        self.assertEqual(params["babylon-tutorial-title"], [""])
        (self.data / "tutorials/pending/t1/meta.json").unlink()
        (self.data / "elsewhere.json").write_text(json.dumps({"title": "Linked"}))
        (self.data / "tutorials/pending/t1/meta.json").symlink_to(self.data / "elsewhere.json")
        _, params = self.launch(self.world(kind="tutorial", tutorial="t1"))
        self.assertEqual(params["babylon-tutorial-title"], [""])


if __name__ == "__main__":
    unittest.main()
