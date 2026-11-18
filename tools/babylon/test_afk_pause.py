"""Run the real AFK policy in native BYOND; saves cannot consume player idle time."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
class AfkPause(unittest.TestCase):
    def test_save_pause_does_not_trigger_warning_or_kick(self):
        source = (ROOT / 'modular_babylon/code/afk.dm').read_text().split('/client\n', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'probe.dme').write_text('#define SECONDS * 10\n' + source + '''
/world/New()
    var/datum/babylon_afk/policy = new
    var/list/results = list()
    results["initial"] = isnull(policy.update(100 SECONDS, 900 SECONDS))
    results["save_start"] = isnull(policy.update(101 SECONDS, 900 SECONDS, TRUE))
    results["save_wait"] = isnull(policy.update(2000 SECONDS, 900 SECONDS, TRUE))
    results["save_end"] = isnull(policy.update(2100 SECONDS, 900 SECONDS, FALSE))
    results["active_after_save"] = isnull(policy.update(2800 SECONDS, 900 SECONDS))
    results["warn_after_playable_idle"] = policy.update(2840 SECONDS, 900 SECONDS) == "warn"
    results["kick_after_playable_idle"] = policy.update(2900 SECONDS, 900 SECONDS) == "kick"
    results["input_resets_credit"] = isnull(policy.update(1 SECONDS, 900 SECONDS))
    results["next_kick"] = policy.update(900 SECONDS, 900 SECONDS) == "kick"
    text2file(json_encode(results), "results.json")
    shutdown()
''')
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            results = json.loads((folder / 'results.json').read_text())
            for name, passed in results.items():
                with self.subTest(name=name):
                    self.assertTrue(passed)
