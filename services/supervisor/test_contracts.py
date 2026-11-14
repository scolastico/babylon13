"""Contracts between the supervisor and the DM code that talks to it."""
import json
import re
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import parse_qs

import test_driver
import test_supervisor
import itertools

from constants import WORLD_KINDS, world_policy
from supervisor import CHILD_ACTIONS, Denied, Supervisor

DM = Path(__file__).resolve().parents[2] / "modular_babylon/code"

# Child actions the supervisor offers before any world code calls them. The tutorial submit and
# save-back actions are built and unit-tested on the supervisor side first; the DM side lands in
# G1b, which removes them from this list.
NOT_YET_CALLED = {"tutorial_submit_check", "tutorial_submit", "tutorial_save_back"}

# Child parameters a world is given on purpose even though no world code reads them by name.
# (empty: every parameter the Driver writes is read by the DM code, and vice versa)
WRITTEN_NOT_READ = set()
# Parameters the DM code reads that the Driver does not write. babylon-test is supplied by the
# smoke tests and is read through a different expression, so it needs no entry here.
READ_NOT_WRITTEN = set()


def dm_sources():
    return {path: path.read_text(encoding="utf-8") for path in sorted(DM.rglob("*.dm"))}


ACTION = re.compile(r'"action"\s*=\s*"([a-z_]+)"')


def dm_actions():
    """Every "action" literal in files that call babylon_supervisor_request, mapped to a file."""
    found = {}
    for path, text in dm_sources().items():
        if "babylon_supervisor_request" in text:
            for action in ACTION.findall(text):
                found.setdefault(action, path.name)
    return found


class ChildActions(unittest.TestCase):
    def test_every_dm_action_literal_is_a_child_action(self):
        found = dm_actions()
        self.assertTrue({"redeem", "ahelp", "world_manage", "round_ended"} <= set(found), found)
        self.assertEqual({a: f for a, f in found.items() if a not in CHILD_ACTIONS}, {})

    def test_every_child_action_is_called_by_the_dm_code(self):
        self.assertEqual(set(CHILD_ACTIONS) - set(dm_actions()) - NOT_YET_CALLED, set())

    def test_actions_awaiting_their_dm_side_are_not_called_yet(self):
        # Once the DM code calls one, it must leave NOT_YET_CALLED (and so be checked above).
        self.assertTrue(NOT_YET_CALLED <= set(CHILD_ACTIONS))
        self.assertEqual(NOT_YET_CALLED & set(dm_actions()), set())

    def test_every_child_action_rejects_bad_credentials(self):
        with tempfile.TemporaryDirectory() as temp:
            service = Supervisor(dict(data_directory=temp, template_directory=temp, config_directory=temp,
                                      dreamdaemon="x", listen_port=1, port_first=1400, port_last=1410,
                                      max_running_worlds=2, max_players_per_world=4, max_worlds_per_player=3,
                                      max_running_worlds_per_player=1, kept_save_points_per_world=4,
                                      empty_grace_seconds=60, startup_timeout_seconds=60,
                                      ticket_lifetime_seconds=60, map_catalog=str(write_catalog(temp))),
                                 driver=test_supervisor.FakeDriver())
            service.db.execute("INSERT INTO worlds(id,owner,name,description,visibility,max_players,created,last_used)"
                               " VALUES('w','o','W','','public',4,0,0)")
            service.db.execute("INSERT INTO runs(id,world,port,secret,state,started) VALUES('r','w',1400,'right-secret','running',0)")
            service.db.commit()
            for action, handler in CHILD_ACTIONS.items():
                for run, secret in (("r", "wrong"), ("unknown", "right-secret"), (None, "")):
                    with self.assertRaises(Denied, msg="%s accepted run=%r secret=%r" % (action, run, secret)):
                        handler(service, {"action": action, "run": run, "secret": secret, "actor": "o",
                                          "ticket": "t", "op": "kick", "target": "x", "kind": "new"})


def write_catalog(temp):
    path = Path(temp) / "catalog.json"
    path.write_text(json.dumps(test_driver.CATALOG))
    return path


class ChildParams(test_driver.DriverFixture):
    def test_driver_params_match_what_the_dm_code_reads(self):
        music = Path(self.temp.name) / "music"
        music.mkdir()
        self.driver.config["music_directory"] = str(music)
        with patch("supervisor.subprocess.Popen", return_value=SimpleNamespace(pid=1)) as popen, \
                patch("supervisor.Follower"), patch("supervisor.prepare_fresh_map"):
            self.driver.start(dict(self.world(), map="babylon"), test_driver.RUN)
            babylon_arguments = popen.call_args.args[0]
            # Station worlds get their own parameters too (babylon-autosave-minutes).
            self.driver.start(self.world(), test_driver.RUN)
            station_arguments = popen.call_args.args[0]
        written = set()
        for arguments in (babylon_arguments, station_arguments):
            written |= {k for k in parse_qs(arguments[arguments.index("-params") + 1], keep_blank_values=True)
                        if k.startswith("babylon-")}
        read = set()
        for text in dm_sources().values():
            read |= set(re.findall(r'\bparams\["(babylon-[a-z-]+)"\]', text))
        self.assertTrue(len(written) > 10 and len(read) > 10)
        self.assertEqual(written - read - WRITTEN_NOT_READ, set(), "written but never read by the DM code")
        self.assertEqual(read - written - READ_NOT_WRITTEN, set(), "read by the DM code but never written")

    def test_dm_world_kinds_match_the_supervisor(self):
        text = (DM / "world_flags.dm").read_text(encoding="utf-8")
        kinds = re.search(r'requested_kind in list\(([^)]*)\)', text).group(1)
        self.assertEqual(tuple(re.findall(r'"([a-z_]+)"', kinds)), WORLD_KINDS)


def dm_policy():
    """The world-type policy table of world_flags.dm: method name -> its return expression."""
    text = (DM / "world_flags.dm").read_text(encoding="utf-8")
    return dict(re.findall(r"^/datum/babylon_world/proc/(\w+)\(\)\n\treturn (.+)$", text, re.M))


def dm_evaluate(policy, name, world):
    """Evaluates one DM policy expression (&&, ||, !, ==, fields and other policy methods)."""
    expression = policy[name]
    expression = re.sub(r"is_tutorial\(\)", "(kind in ('tutorial', 'tutorial_edit'))", expression)
    expression = re.sub(r"is_creative_plane\(\)", "(str(map_id).startswith('creative_plane'))", expression)
    expression = re.sub(r"(\w+)\(\)", r"call('\1')", expression)
    expression = expression.replace("&&", " and ").replace("||", " or ")
    expression = re.sub(r"!(?!=)", " not ", expression)
    scope = dict(world, call=lambda other: dm_evaluate(policy, other, world))
    return bool(eval(expression, {"__builtins__": {"str": str}}, scope))


class WorldPolicy(unittest.TestCase):
    """world_flags.dm and constants.world_policy() answer the same for every world type."""

    def test_same_rules_on_both_sides(self):
        policy = dm_policy()
        self.assertEqual(set(policy) - {"is_tutorial", "is_creative_plane"}, set(world_policy("station", 1, 1, "world", "x")))
        for build, persistent, creative, kind, map_id in itertools.product(
                ("babylon", "station"), (0, 1), (0, 1), WORLD_KINDS, ("babylon", "metastation", "creative_plane_m")):
            world = dict(build=build, persistent=persistent, creative=creative, kind=kind, map_id=map_id)
            expected = world_policy(build, persistent, creative, kind, map_id)
            for name, value in expected.items():
                with self.subTest(rule=name, **world):
                    self.assertEqual(dm_evaluate(policy, name, world), value)

    def test_rulings(self):
        # A Creative Plane always contains a delamination, like its creative machines run.
        plane = world_policy("station", 1, 0, "world", "creative_plane_s")
        self.assertTrue(plane["delam_contained"] and plane["creative_machines_active"] and plane["storyteller_inert"])
        self.assertTrue(world_policy("station", 1, 1, "world", "metastation")["can_submit_tutorial"])
        self.assertFalse(world_policy("babylon", 1, 1, "world", "babylon")["can_submit_tutorial"])
        self.assertTrue(world_policy("station", 0, 0, "tutorial_edit", "metastation")["can_save_back_tutorial"])
        self.assertFalse(world_policy("station", 1, 1, "tutorial", "metastation")["saves"])

    def test_world_type_rules_live_in_world_flags(self):
        # The rules are defined once, in world_flags.dm; other modules only call them.
        for path, text in dm_sources().items():
            if path.name == "world_flags.dm":
                continue
            for rule in ("babylon_creative_machines_active", "babylon_delam_contained", "babylon_storyteller_inert",
                         "babylon_world_saves", "babylon_stop_saves", "babylon_tutorial_capable", "babylon_creative_enabled"):
                self.assertNotRegex(text, r"(?m)^/proc/%s\(" % rule, path.name)
            self.assertNotIn("babylon_station_saving_available", text, path.name)


if __name__ == "__main__":
    unittest.main()
