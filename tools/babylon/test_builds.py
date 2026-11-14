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
          "music_loops", "play_time", "testing_common",
          "creative/machine_types_stub", "creative/powers", "creative/spawning", "creative/teleport",
          "creative/events", "creative/supermatter", "creative/panel", "creative/testing_creative"}
BABYLON_ONLY = {"rules", "session", "drone_recovery", "builder_experience", "lore", "vault", "survival",
                "silicons", "research", "testing"}
STATION_ONLY = {"station_session", "station_round", "testing_station"}


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
