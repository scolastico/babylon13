"""Contracts between the supervisor and the DM code that talks to it."""
import re
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import parse_qs

import test_driver
from constants import WORLD_KINDS
from supervisor import CHILD_ACTIONS

DM = Path(__file__).resolve().parents[2] / "modular_babylon/code"

# Child parameters a world is given on purpose even though no world code reads them by name.
# (empty: every parameter the Driver writes is read by the DM code, and vice versa)
WRITTEN_NOT_READ = set()
# Parameters the DM code reads that the Driver does not write. babylon-test is supplied by the
# smoke tests and is read through a different expression, so it needs no entry here.
READ_NOT_WRITTEN = set()


def dm_sources():
    return {path: path.read_text(encoding="utf-8") for path in sorted(DM.rglob("*.dm"))}


class ChildActions(unittest.TestCase):
    def test_every_dm_action_literal_is_a_child_action(self):
        found = {}
        for path, text in dm_sources().items():
            for action in re.findall(r'list\(\s*"action"\s*=\s*"([a-z_]+)"', text):
                found.setdefault(action, path.name)
        self.assertTrue({"redeem", "ahelp", "world_manage", "round_ended"} <= set(found), found)
        self.assertEqual({a: f for a, f in found.items() if a not in CHILD_ACTIONS}, {})

    def test_every_child_action_is_called_by_the_dm_code(self):
        used = set(re.findall(r'list\(\s*"action"\s*=\s*"([a-z_]+)"', "\n".join(dm_sources().values())))
        self.assertEqual(set(CHILD_ACTIONS) - used, set())


class ChildParams(test_driver.DriverFixture):
    def test_driver_params_match_what_the_dm_code_reads(self):
        music = Path(self.temp.name) / "music"
        music.mkdir()
        self.driver.config["music_directory"] = str(music)
        with patch("supervisor.subprocess.Popen", return_value=SimpleNamespace(pid=1)) as popen, \
                patch("supervisor.Follower"), patch("supervisor.prepare_fresh_map"):
            self.driver.start(dict(self.world(), map="babylon"), test_driver.RUN)
        arguments = popen.call_args.args[0]
        written = {k for k in parse_qs(arguments[arguments.index("-params") + 1], keep_blank_values=True)
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


if __name__ == "__main__":
    unittest.main()
