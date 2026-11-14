"""Guards the world tick's single definition.

/datum/babylon_save/tick_world() is defined once, in the shared state.dm: it runs the build's player
loop (tick_players(), one per build: session.dm or station_session.dm) and then sends
COMSIG_BABYLON_WORLD_TICK. Modules register a handler for that signal. An override chain of
tick_world (or tick_players) would again depend on the include order and on every link calling ..().
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULAR = ROOT / "modular_babylon"
# Upstream hooks live outside modular_babylon; scan them too.
UPSTREAM = ("code", "modular_skyrat", "modular_zubbers", "modular_zzplurt")


def definitions(name):
    """(file, line) of every definition of /datum/babylon_save/<name>(), in either DM syntax."""
    path_form = re.compile(r"^/datum/babylon_save/(?:proc/|verb/)?%s\(" % name)
    block_form = re.compile(r"^\t(?:proc/|verb/)?%s\(" % name)
    found = []
    files = list(MODULAR.rglob("*.dm"))
    for folder in UPSTREAM:
        files += [path for path in (ROOT / folder).rglob("*.dm") if "babylon" in path.read_text(errors="ignore")]
    for path in files:
        block = None
        for number, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
            if line and not line[0].isspace():
                # A top-level line: a type block (/datum/babylon_save) or a proc definition.
                block = line.split("//")[0].strip()
            if path_form.match(line) or (block == "/datum/babylon_save" and block_form.match(line)):
                found.append((path.relative_to(ROOT).as_posix(), number))
    return found


class TickOverrideTest(unittest.TestCase):
    def test_tick_world_is_defined_only_in_the_shared_base(self):
        files = [name for name, _ in definitions("tick_world")]
        self.assertEqual(files, ["modular_babylon/code/state.dm"])

    def test_one_player_loop_per_build(self):
        files = sorted(name for name, _ in definitions("tick_players"))
        self.assertEqual(files, ["modular_babylon/code/session.dm", "modular_babylon/code/state.dm",
                                 "modular_babylon/code/station_session.dm"])

    def test_base_sends_the_tick_signal(self):
        text = (MODULAR / "code/state.dm").read_text()
        self.assertIn("SEND_SIGNAL(src, COMSIG_BABYLON_WORLD_TICK)", text)
        self.assertIn("#define COMSIG_BABYLON_WORLD_TICK", (MODULAR / "__DEFINES/babylon.dm").read_text())

    def test_modules_register_for_the_tick(self):
        for name in ("play_time.dm", "station_round.dm"):
            self.assertIn("COMSIG_BABYLON_WORLD_TICK", (MODULAR / "code" / name).read_text(), name)

    def test_the_scan_finds_both_syntaxes(self):
        # Guards the guard: a block-form override in a type block must be detected too.
        block = re.compile(r"^\t(?:proc/|verb/)?tick_world\(")
        self.assertTrue(block.match("\ttick_world()"))
        self.assertFalse(block.match("\t\ttick_world()"))


if __name__ == "__main__":
    unittest.main()
