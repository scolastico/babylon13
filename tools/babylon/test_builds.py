"""Guards the split between the Babylon build (babylon.dme) and the station build
(babylon-station.dme): shared modules stay in both, Babylon-only modules stay out of the
station build, and nothing every world needs (safe-for-work rules) hides in a Babylon-only file.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
CODE = "modular_babylon/code/"

SHARED = {"world_flags", "state", "persistence", "afk", "control", "admission", "showcase", "spectator",
          "sfw", "links", "storyteller", "moderation", "world_players", "interface", "music",
          "music_loops", "play_time", "testing_common", "creative/machines", "creative/testing_machines",
          "creative/powers", "creative/spawning", "creative/teleport",
          "creative/events", "creative/supermatter", "creative/panel", "creative/testing_creative",
          "tutorial/objects", "tutorial/triggers", "tutorial/actions", "tutorial/npc", "tutorial/runtime",
          "tutorial/area_tools", "tutorial/wand", "tutorial/submit", "tutorial/testing_tutorial",
          "tutorial/testing_area_tools", "tutorial/testing_submit"}
BABYLON_ONLY = {"rules", "session", "drone_recovery", "builder_experience", "lore", "vault", "survival",
                "silicons", "research", "testing"}
STATION_ONLY = {"station_session", "station_round", "persistence_levels", "testing_station", "creative/plane",
                "creative/testing_plane"}


def module_name(relative):
    """A module's name: its path below modular_babylon/code/ without .dm ("creative/panel")."""
    return Path(relative).with_suffix("").as_posix()


def modules(dme):
    text = (ROOT / dme).read_text()
    return {module_name(name) for name in re.findall(r'#include "' + CODE + r'([^"]+\.dm)"', text)}


class BuildSplitTest(unittest.TestCase):
    def test_shared_modules_in_both_builds(self):
        babylon, station = modules("babylon.dme"), modules("babylon-station.dme")
        self.assertEqual(SHARED - babylon, set())
        self.assertEqual(SHARED - station, set())

    def test_babylon_only_modules_stay_out_of_the_station_build(self):
        babylon, station = modules("babylon.dme"), modules("babylon-station.dme")
        self.assertEqual(BABYLON_ONLY - babylon, set())
        self.assertEqual(BABYLON_ONLY & station, set())
        self.assertEqual(STATION_ONLY & babylon, set())
        self.assertEqual(STATION_ONLY - station, set())

    def test_every_module_is_classified(self):
        files = {module_name(path.relative_to(ROOT / CODE)) for path in (ROOT / CODE).rglob("*.dm")}
        self.assertEqual(files - SHARED - BABYLON_ONLY - STATION_ONLY, set())

    def test_station_build_defines(self):
        text = (ROOT / "babylon-station.dme").read_text()
        defines = set(re.findall(r"^#define (\w+)", text, re.M))
        self.assertIn("BABYLON_STATION", defines)
        for babylon_rule in ("FORCE_MAP", "AUTOSTART_GAME", "SKIP_SPACE_LEVELS", "SKIP_LAVALAND"):
            self.assertNotIn(babylon_rule, defines)

    def test_exactly_one_game_build_define(self):
        # BABYLON_BUILDER is any cluster world; each game build defines exactly one of the two
        # build defines, and babylon.dm refuses (#error) a build with none or both.
        for dme, own in (("babylon.dme", "BABYLON_DRONE"), ("babylon-station.dme", "BABYLON_STATION")):
            defines = set(re.findall(r"^#define (\w+)", (ROOT / dme).read_text(), re.M))
            self.assertIn("BABYLON_BUILDER", defines, dme)
            self.assertEqual(defines & {"BABYLON_DRONE", "BABYLON_STATION"}, {own}, dme)
        guard = (ROOT / "modular_babylon/__DEFINES/babylon.dm").read_text()
        self.assertIn("#if defined(BABYLON_DRONE) && defined(BABYLON_STATION)\n#error", guard)
        self.assertIn("#if !defined(BABYLON_DRONE) && !defined(BABYLON_STATION)\n#error", guard)

    def test_drone_code_tests_the_positive_define(self):
        # "Not the station build" would hand the drone rules to any third build.
        negative = re.compile(r"#ifndef BABYLON_STATION|!\s*defined\(BABYLON_STATION\)")
        for folder in ["code", "modular_babylon/code"] + sorted(p.name for p in ROOT.glob("modular_*") if p.is_dir()):
            for path in (ROOT / folder).rglob("*.dm"):
                # The compile-time guard itself checks for "neither define".
                if path.name != "babylon.dm" and "BABYLON_STATION" in path.read_text(errors="ignore"):
                    self.assertNotRegex(path.read_text(errors="ignore"), negative, path.relative_to(ROOT).as_posix())

    def test_build_define_arms_name_their_build(self):
        # An #else arm of "#ifdef BABYLON_STATION" is "not the station build" again: each arm of a
        # conditional on a game build define names its build (#elif defined(BABYLON_DRONE)).
        problems = []
        folders = ["code"] + sorted(p.name for p in ROOT.glob("modular_*") if p.is_dir())
        for folder in folders:
            for path in (ROOT / folder).rglob("*.dm"):
                text = path.read_text(errors="ignore")
                if path.name == "babylon.dm" or not re.search(r"BABYLON_(STATION|DRONE)", text):
                    continue
                stack = []
                for number, line in enumerate(text.splitlines(), 1):
                    directive = line.strip()
                    if directive.startswith("#if"):
                        stack.append(bool(re.search(r"BABYLON_(STATION|DRONE)", directive)))
                    elif directive.startswith("#endif"):
                        stack.pop()
                    elif stack and stack[-1] and directive.startswith("#else"):
                        problems.append("%s:%d" % (path.relative_to(ROOT).as_posix(), number))
                    elif stack and stack[-1] and directive.startswith("#elif") \
                            and not re.search(r"(?<!!)defined\(BABYLON_(STATION|DRONE)\)", directive):
                        problems.append("%s:%d" % (path.relative_to(ROOT).as_posix(), number))
        self.assertEqual(problems, [])

    def test_test_builds_wrap_the_game_builds(self):
        for test, game in (("babylon-test.dme", "babylon.dme"), ("babylon-station-test.dme", "babylon-station.dme")):
            text = (ROOT / test).read_text()
            self.assertIn("#define BABYLON_TESTING", text)
            self.assertIn('#include "%s"' % game, text)

    def test_safe_for_work_rules_are_not_babylon_only(self):
        # Every world is SFW: such rules belong in a shared module (sfw.dm), never in one the
        # station build leaves out.
        pattern = re.compile(r"lewd|\berp\b|_erp|erp_|genital|arousal", re.I)
        for name in sorted(BABYLON_ONLY):
            text = (ROOT / CODE / (name + ".dm")).read_text()
            if name == "testing":
                continue
            self.assertIsNone(pattern.search(text), "%s.dm contains SFW logic; move it to sfw.dm" % name)

    def test_title_menu_anchor_still_exists(self):
        # station_round.dm inserts the round status and Start round button after this exact
        # markup in Skyrat's title screen; an upstream change would silently drop them.
        anchor = '<div class="container_nav">'
        title = (ROOT / "modular_skyrat/modules/title_screen/code/title_screen_html.dm").read_text()
        self.assertEqual(title.count(anchor), 1)
        self.assertIn(anchor, (ROOT / CODE / "station_round.dm").read_text())


if __name__ == "__main__":
    unittest.main()
