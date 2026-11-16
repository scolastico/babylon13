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
        # restore or a whole paste: every call runs inside its own try, or, in the modules that
        # allow no try (tools/babylon/test_no_try.py), alone in a proc of its own that returns
        # TRUE at its end (a runtime ends only that proc; the caller sees the missing TRUE).
        calls = 0
        no_try = [DM / "tutorial", DM / "creative"]
        for path, text in dm_sources().items():
            lines = text.splitlines()
            for index, line in enumerate(lines):
                if ".babylon_after_restore(" not in line:
                    continue
                calls += 1
                where = "%s:%d" % (path.name, index + 1)
                if lines[index - 1].strip() == "try":
                    continue
                self.assertTrue(any(folder in path.parents for folder in no_try), where)
                self.assertTrue(lines[index - 1].startswith("/proc/"), where)
                self.assertEqual(lines[index + 1].strip(), "return TRUE", where)
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


REPO = DM.parents[1]
# A guard flag set and cleared in one proc around code that may fail (see FlagGuards). These set
# and clear it in different branches, or inside a try whose catch clears it.
FLAG_PAIRS_ALLOWED = {
    ("creative/powers.dm", "user.babylon_creative_noclip"),  # on and off in separate branches
    ("creative/powers.dm", "user.babylon_creative_sight_hooked"),  # on and off in separate branches
    ("persistence.dm", "can_rotate"),  # reflector Initialize: a plain field toggle around ..()
    ("station_characters.dm", "menu.spawning"),  # inside a try; the catch clears it
}
FLAG_SET = re.compile(r"\s+([\w.\[\]\"]+)\s*=\s*(?:TRUE|1)\s*$")
FLAG_CLEAR = re.compile(r"\s+([\w.\[\]\"]+)\s*=\s*(?:FALSE|0|null)\s*$")


def dm_procs(text):
    """(first line index, [(index, line)]) for each top-level block of a DM file."""
    blocks = []
    for index, line in enumerate(text.splitlines()):
        if line and not line[0].isspace() and not line.startswith(("//", "#")):
            blocks.append((index, []))
        if blocks:
            blocks[-1][1].append((index, line))
    return blocks


class FlagGuards(unittest.TestCase):
    def test_no_guard_flag_is_left_set_by_a_runtime(self):
        # A proc that sets a flag, calls other code and clears the flag again must run that code
        # inside a try: a runtime in between would leave the flag set for the rest of the run
        # (a world flagged busy never saves again, a pending stop blocks every later stop).
        found = []
        for root in (DM, REPO / "modular_babylon/lobby"):
            for path in sorted(root.rglob("*.dm")):
                if path.name.startswith("testing"):
                    continue
                name = path.relative_to(root).as_posix()
                for _, body in dm_procs(path.read_text(encoding="utf-8")):
                    sets = {}
                    for index, line in body:
                        match = FLAG_SET.match(line)
                        if match:
                            sets.setdefault(match.group(1), index)
                            continue
                        match = FLAG_CLEAR.match(line)
                        if not match or match.group(1) not in sets or (name, match.group(1)) in FLAG_PAIRS_ALLOWED:
                            continue
                        between = [text for number, text in body if sets[match.group(1)] < number < index]
                        calls = [text for text in between if re.search(r"\w\(", text) and not text.strip().startswith("//")]
                        if calls and not any(text.strip() == "try" for text in between):
                            found.append("%s:%d %s" % (name, sets[match.group(1)] + 1, match.group(1)))
        self.assertEqual(found, [])

    def test_a_failed_restore_clears_the_saved_map_flag(self):
        # babylon_loading_saved_map() holds mapload defaults back while a save loads; a restore
        # that throws must not leave it set for the rest of the run.
        calls = 0
        for path, text in dm_sources().items():
            lines = text.splitlines()
            for index, line in enumerate(lines):
                if line.strip() not in ("session.restore_world()", "session.restore_station()"):
                    continue
                calls += 1
                self.assertEqual(lines[index - 1].strip(), "try", "%s:%d" % (path.name, index + 1))
                catch = next(number for number in range(index, len(lines)) if lines[number].strip().startswith("catch"))
                handler = []
                for following in lines[catch + 1:]:
                    if not following.startswith("\t\t"):
                        break
                    handler.append(following.strip())
                self.assertIn("session.loading_saved_map = FALSE", handler, "%s:%d" % (path.name, index + 1))
        self.assertEqual(calls, 2)


# Upstream types whose Initialize deletes the object at random (prob(...) next to
# INITIALIZE_HINT_QDEL): a smoke test that spawns one fails now and then.
def randomly_deleted_types():
    found = set()
    for folder in ("code", "modular_skyrat", "modular_zubbers", "modular_zzplurt"):
        for path in (REPO / folder).rglob("*.dm"):
            current, body = None, []
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines() + ["/end"]:
                if line and not line[0].isspace():
                    if current and any("prob(" in text for text in body) and any("INITIALIZE_HINT_QDEL" in text for text in body):
                        found.add(current)
                    match = re.match(r"(/[\w/]+)/Initialize\(", line)
                    current, body = (match.group(1) if match else None), []
                elif current:
                    body.append(line)
    return found


class SmokeDeterminism(unittest.TestCase):
    def test_smoke_tests_spawn_nothing_that_deletes_itself_at_random(self):
        types = randomly_deleted_types()
        self.assertIn("/obj/structure/closet/emcloset", types)
        used = []
        for path in sorted(DM.rglob("testing*.dm")):
            text = path.read_text(encoding="utf-8")
            used += ["%s: %s" % (path.name, kind) for kind in sorted(types) if re.search(re.escape(kind) + r"(?!\w)", text)]
        self.assertEqual(used, [])

    def test_smoke_scripts_read_dm_results_through_the_length_check(self):
        # A DM result is cut off past the debug bridge's limit; only dm_entries() notices.
        here = Path(__file__).resolve().parent
        raw = []
        for name in ("smoke_native.py", "smoke_station.py"):
            for number, line in enumerate((here / name).read_text(encoding="utf-8").splitlines(), 1):
                if re.search(r'\w\["entries"\]', line) and "def dm_entries" not in line and 'packed["entries"]' not in line and '["contents"]["entries"]' not in line:
                    raw.append("%s:%d: %s" % (name, number, line.strip()))
        self.assertEqual(raw, [])

    def test_saved_objects_never_delete_themselves_at_random_on_load(self):
        # A restored object runs its Initialize again: one that deletes itself at random would
        # vanish from a saved world now and then. Each such type stands back for a saved map.
        hooked = {"/obj/structure/closet/emcloset": "/obj/structure/closet/emcloset/Initialize(mapload)",
                  "/mob/living/basic/bot/mulebot": "/mob/living/basic/bot/mulebot/Initialize(mapload)"}
        allowed = {
            "/obj/effect/spawner/message_in_a_bottle",  # a spawner: deletes itself either way
            "/obj/effect/mob_spawn/ghost_role/human/lavaland_syndicate/comms/space",  # commented out (Bubber)
            "/mob/living/basic/migo",  # 0.1%: replaced by the same mob with a wig, nothing is lost
        }
        persistence = (DM / "persistence.dm").read_text(encoding="utf-8")
        self.assertEqual(randomly_deleted_types() - set(hooked) - allowed, set())
        for hook in hooked.values():
            self.assertIn(hook, persistence)

    def test_marker_tiles_are_solid_floors(self):
        # Markers and the emptied locker's items must lie on a floor that moves nothing (no
        # planetary wind, conveyors or stairs): test_marker_turf() prefers such a floor.
        text = (DM / "testing_station.dm").read_text(encoding="utf-8")
        body = text.split("/datum/babylon_save/proc/test_marker_turf(", 1)[1].split("\n/", 1)[0]
        self.assertIn("babylon_test_solid_floor(tile)", body)
        floor = text.split("/proc/babylon_test_solid_floor(", 1)[1].split("\n/", 1)[0]
        for condition in ("/turf/open/floor", "planetary_atmos", "/obj/structure", "/obj/machinery"):
            self.assertIn(condition, floor)


class SaveFiles(unittest.TestCase):
    def test_save_files_are_written_in_checked_pieces(self):
        # A save file written from one huge DM string came out truncated (state.json earlier, a
        # level map in the H1 container run: "Undefined model key"); the next start then ran
        # without that level and its save wrote the loss over the world. Save files go through
        # babylon_write_pieces(), which checks every write and the size; only the two tiny files
        # are written directly.
        text = (DM / "persistence.dm").read_text(encoding="utf-8")
        direct = [line.strip() for path, source in dm_sources().items() if not path.name.startswith("testing")
                  for line in source.splitlines() if "rustg_file_write(" in line]
        self.assertEqual(len(direct), 2, direct)
        self.assertTrue(any('"1", "[base]/tutorial-snapshot"' in line for line in direct), direct)
        self.assertTrue(any("saves/latest.json" in line for line in direct), direct)
        self.assertIn('babylon_write_pieces(level_maps[z_text]', text)
        self.assertIn('babylon_write_pieces(pieces, "[base]/state.json")', text)
        self.assertNotIn('"map_text"', text)
        # The area tools' copies are map files too (up to 10,000 tiles).
        tools = (DM / "tutorial/area_tools.dm").read_text(encoding="utf-8")
        self.assertEqual(tools.count("babylon_write_pieces(babylon_area_map_pieces("), 2)

    def test_a_restore_refuses_levels_that_did_not_load(self):
        text = (DM / "persistence.dm").read_text(encoding="utf-8")
        body = text.split("/datum/babylon_save/proc/restore_world()", 1)[1].split("\n/", 1)[0]
        self.assertIn("if(length(SSmapping.babylon_failed_maps))", body)
        self.assertIn("babylon_failed_maps |= failed", text)


class MaploadDefaults(unittest.TestCase):
    # Upstream files that decide something at random only on mapload, and the hook in
    # persistence.dm that makes it stand back for a saved map (babylon_loading_saved_map()).
    HOOKS = {
        "code/game/turfs/open/floor.dm": "/turf/open/floor/MakeDirty()",
        "code/modules/recycling/disposal/bin.dm": "/obj/machinery/disposal/bin/spawn_contained_animal()",
        "code/modules/mob/living/basic/bots/mulebot/mulebot.dm": "/mob/living/basic/bot/mulebot/Initialize(mapload)",
        "code/game/machinery/camera/camera.dm": "/obj/machinery/camera/Initialize(mapload)",
    }
    # Random mapload choices a restore overwrites anyway.
    HARMLESS = {
        "code/modules/reagents/reagent_dispenser.dm",  # water cooler punch: the saved reagents replace it
    }

    def test_every_random_mapload_default_stands_back_for_a_saved_map(self):
        # Such code runs again on every restart of a saved world and piled up dirt, hidden
        # animals and the like. A new upstream case fails here until it gets a hook.
        persistence = (DM / "persistence.dm").read_text(encoding="utf-8")
        pattern = re.compile(r"(?<![!\w])mapload\s*&&.*prob\(|prob\(.*&&\s*mapload\b")
        found = set()
        for folder in ("code", "modular_skyrat", "modular_zubbers", "modular_zzplurt"):
            for path in (REPO / folder).rglob("*.dm"):
                if pattern.search(path.read_text(encoding="utf-8", errors="replace")):
                    found.add(path.relative_to(REPO).as_posix())
        self.assertEqual(found - self.HARMLESS - set(self.HOOKS), set())
        for hook in self.HOOKS.values():
            self.assertIn(hook, persistence)
        # Round-start decay (modular_skyrat decaySS.dm) is the same kind of decision, per world.
        self.assertIn("/datum/controller/subsystem/decay/Initialize()", persistence)
        self.assertIn("/datum/controller/subsystem/area_spawn/Initialize()", persistence)
        # Lights decide their breakage through allow_break_on_init.
        self.assertIn("allow_break_on_init = FALSE", persistence)


class Readiness(unittest.TestCase):
    def test_a_world_reports_ready_only_once_it_can_save(self):
        # The status the supervisor trusts and the flag save_world() checks must be the same:
        # a stop right after the start skipped its save when they differed.
        flags = (DM / "world_flags.dm").read_text(encoding="utf-8")
        body = flags.split("/proc/babylon_world_ready()", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(body.strip(), "return !!GLOB.babylon_save?.ready")
        self.assertIn("while(!babylon_station_boot_complete())", (DM / "station_session.dm").read_text(encoding="utf-8"))


class Companions(unittest.TestCase):
    def test_companions_are_marked_at_creation_and_never_saved(self):
        # Objects another atom makes in its Initialize are made again on every load: marked when
        # made (not when a map template places them), skipped by every save, and the copies older
        # saves hold are removed on restore.
        text = (DM / "persistence.dm").read_text(encoding="utf-8")
        hook = text.split("/datum/controller/subsystem/atoms/InitAtom(", 1)[1].split("\n/", 1)[0]
        self.assertIn("!from_template", hook)
        # No try: it would make a runtime deep inside any Initialize unwind up to it.
        self.assertNotIn("\ttry", hook)
        self.assertEqual(hook.count("babylon_initializing.Cut(depth + 1)"), 1)
        self.assertIn("/atom/movable/babylon_skip_save()\n\treturn ..() || babylon_is_companion()", text)
        self.assertIn("remove_saved_companion_copies(records)", text)
        # The fallback for copies made outside an Initialize runs in both builds before ready.
        for name in ("session.dm", "station_session.dm"):
            boot = (DM / name).read_text(encoding="utf-8")
            self.assertLess(boot.index("remove_regenerated_copies()"), boot.index("\tready = TRUE"), name)
        # What a random mapload default makes stays saved (the default stands back on a load).
        self.assertIn("!babylon_fresh_map_only", hook)
        for proc in ("/turf/open/floor/MakeDirty()",):
            body = text.split(proc, 1)[1].split("\n/", 1)[0]
            self.assertIn("SSatoms.babylon_fresh_map_only++", body)
            self.assertNotIn("\ttry", body)


if __name__ == "__main__":
    unittest.main()
