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

from constants import (SAVES_CHARACTERS, TUTORIAL_DESCRIPTION_MAX, TUTORIAL_SNAPSHOT_MARKER, TUTORIAL_TITLE_MAX, WORLD_KINDS,
                       world_policy)
from supervisor import CHILD_ACTIONS, Denied, Supervisor

DM = Path(__file__).resolve().parents[2] / "modular_babylon/code"

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
        self.assertEqual(set(CHILD_ACTIONS) - set(dm_actions()), set())

    def test_every_supervisor_request_is_bounded(self):
        # world.Export blocks with no timeout of its own (arch-review C5): a hung supervisor would
        # stall logins, the round end or a lobby page. Only the background call datums block;
        # everything else goes through babylon_supervisor_request_within() / lobby_export_start() + lobby_await().
        allowed = {"babylon_supervisor_request(": {"/datum/babylon_supervisor_call/proc/perform"},
                   "world.Export(": {"/proc/babylon_supervisor_request", "/datum/lobby_request/proc/perform"},
                   # A proc reference starts the blocking call elsewhere (INVOKE_ASYNC, CALLBACK, addtimer).
                   "babylon_supervisor_request)": set(), "/proc/babylon_supervisor_request,": set()}
        sources = dict(dm_sources())
        sources.update({path: path.read_text(encoding="utf-8") for path in sorted((DM.parent / "lobby").glob("*.dm"))})
        found = {call: set() for call in allowed}
        for path, text in sources.items():
            owner = None
            for line in text.splitlines():
                if line and not line[0].isspace() and not line.startswith("//"):
                    owner = re.match(r"[^(]*", line).group(0)
                code = line.split("//")[0]
                for call in allowed:
                    if call in code and not code.lstrip().startswith("/proc/babylon_supervisor_request("):
                        found[call].add(owner)
                        self.assertIn(owner, allowed[call], "%s: %s calls %s" % (path.name, owner, call))
        for call, owners in allowed.items():
            self.assertEqual(found[call], owners, call)

    def test_no_supervisor_request_from_a_ui_action(self):
        # world.Export blocks (the tutorial copy takes long): tgui actions start a background proc
        # instead (arch-review C5). A ui_act, or a panel action it dispatches to, never asks itself.
        handler = re.compile(r"^/[\w/]+/(?:proc/)?(ui_act|handle_action|extension_action)\(.*?(?=^\S)", re.M | re.S)
        for path, text in dm_sources().items():
            for match in handler.finditer(text + "\n/end"):
                for call in ("babylon_supervisor_request", "babylon_supervisor_request_within", ".request(", "save_world(",
                             ".check(", ".submit(", ".save_back(", "take_snapshot("):
                    self.assertNotIn(call, match.group(0), "%s: %s" % (path.name, match.group(1)))

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
        # Tutorial instances never keep characters (arch M1); ordinary worlds do, saved or not.
        self.assertFalse(world_policy("station", 1, 1, "tutorial_edit", "metastation")["saves_characters"])
        self.assertTrue(world_policy("station", 0, 0, "world", "metastation")["saves_characters"])

    def test_characters_policy_covers_every_kind(self):
        self.assertEqual(set(SAVES_CHARACTERS), set(WORLD_KINDS))
        self.assertTrue(SAVES_CHARACTERS["world"])
        self.assertFalse(SAVES_CHARACTERS["tutorial"] or SAVES_CHARACTERS["tutorial_edit"])

    def test_station_save_asks_whether_it_saves_characters(self):
        # arch-review M1: the station checkpoint writes "characters" only where the policy allows
        # (never a tutorial world, never a tutorial snapshot): the snapshot flag reaches both captures.
        text = (DM / "persistence_levels.dm").read_text(encoding="utf-8")
        body = re.search(r"^/datum/babylon_save/capture_session_state\(.*?(?=^\S)", text, re.M | re.S).group(0)
        self.assertIn("capture_players(state, for_tutorial)", body)
        self.assertIn('state["characters"] = capture_characters(for_tutorial)', body)
        self.assertIn("capture_session_state(state, for_tutorial)", (DM / "persistence.dm").read_text(encoding="utf-8"))
        flags = (DM / "world_flags.dm").read_text(encoding="utf-8")
        self.assertRegex(flags, r"(?m)^/proc/babylon_world_saves_characters\(for_tutorial = FALSE\)\n\treturn !for_tutorial && !!GLOB\.babylon_world\?\.saves_characters\(\)$")

    def test_admission_timeout_code_matches(self):
        # The world tells a bounced player why by the supervisor's refusal code, not its wording.
        supervisor = (Path(__file__).parent / "supervisor.py").read_text(encoding="utf-8")
        self.assertIn('code="admission_timeout"', supervisor)
        self.assertIn('result["code"] == "admission_timeout"', (DM / "admission.dm").read_text(encoding="utf-8"))

    def test_tutorial_snapshot_marker_matches(self):
        text = (DM / "persistence.dm").read_text(encoding="utf-8")
        self.assertIn('rustg_file_write("1", "[base]/%s")' % TUTORIAL_SNAPSHOT_MARKER, text)

    def test_tutorial_text_limits_match(self):
        text = (DM / "tutorial/submit.dm").read_text(encoding="utf-8")
        self.assertEqual(int(re.search(r"#define BABYLON_TUTORIAL_TITLE_MAX (\d+)", text).group(1)), TUTORIAL_TITLE_MAX)
        self.assertEqual(int(re.search(r"#define BABYLON_TUTORIAL_DESCRIPTION_MAX (\d+)", text).group(1)), TUTORIAL_DESCRIPTION_MAX)

    def test_no_world_type_decision_outside_the_table(self):
        # Other modules ask the table; they do not test the kind or the map group themselves.
        pattern = re.compile(r'is_tutorial\(\)|is_creative_plane\(\)|\bkind\s*[!=]=\s*"')
        for path, text in dm_sources().items():
            if path.name == "world_flags.dm" or path.name.startswith("testing"):
                continue
            self.assertEqual(pattern.findall(text), [], path.name)

    def test_world_type_rules_live_in_world_flags(self):
        # The rules are defined once, in world_flags.dm; other modules only call them.
        for path, text in dm_sources().items():
            if path.name == "world_flags.dm":
                continue
            for rule in ("babylon_creative_machines_active", "babylon_delam_contained", "babylon_storyteller_inert",
                         "babylon_world_saves", "babylon_stop_saves", "babylon_tutorial_capable", "babylon_creative_enabled",
                         "babylon_world_saves_characters"):
                self.assertNotRegex(text, r"(?m)^/proc/%s\(" % rule, path.name)
            self.assertNotIn("babylon_station_saving_available", text, path.name)


class RestoreGuards(unittest.TestCase):
    def test_every_after_restore_call_is_guarded(self):
        # One object's reconcile step (babylon_after_restore) must never fail a whole world's
        # restore or a whole paste: every call runs inside its own try.
        calls = 0
        for path, text in dm_sources().items():
            lines = text.splitlines()
            for index, line in enumerate(lines):
                if ".babylon_after_restore(" not in line:
                    continue
                calls += 1
                self.assertEqual(lines[index - 1].strip(), "try", "%s:%d" % (path.name, index + 1))
        self.assertGreaterEqual(calls, 2)

    def test_every_character_capture_is_guarded(self):
        # One character that cannot be captured must never fail the whole world's checkpoint.
        calls = 0
        for path, text in dm_sources().items():
            lines = text.splitlines()
            for index, line in enumerate(lines):
                if "capture_character(" not in line or line.startswith("/"):
                    continue
                calls += 1
                self.assertEqual(lines[index - 1].strip(), "try", "%s:%d" % (path.name, index + 1))
        self.assertGreaterEqual(calls, 2)


if __name__ == "__main__":
    unittest.main()
