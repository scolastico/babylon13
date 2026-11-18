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
    for(var/still_paused in list(TRUE, FALSE))
        var/datum/babylon_afk/reset_policy = new
        reset_policy.update(2000 SECONDS, 900 SECONDS, TRUE)
        results["paused_input_[still_paused]_safe"] = isnull(reset_policy.update(1500 SECONDS, 900 SECONDS, still_paused))
        results["paused_input_[still_paused]_credited"] = reset_policy.paused_inactivity == 1500 SECONDS
        var/resumed_idle = (still_paused ? 1501 : 1500) SECONDS
        results["paused_input_[still_paused]_resumed"] = isnull(reset_policy.update(resumed_idle, 900 SECONDS))
        results["paused_input_[still_paused]_fresh_grace"] = isnull(reset_policy.update(resumed_idle + 839 SECONDS, 900 SECONDS))
        results["paused_input_[still_paused]_warn"] = reset_policy.update(resumed_idle + 840 SECONDS, 900 SECONDS) == "warn"
        results["paused_input_[still_paused]_kick"] = reset_policy.update(resumed_idle + 900 SECONDS, 900 SECONDS) == "kick"
    var/datum/babylon_afk/entering_pause = new
    entering_pause.update(800 SECONDS, 900 SECONDS)
    entering_pause.update(700 SECONDS, 900 SECONDS, TRUE)
    results["input_before_pause_not_credited"] = entering_pause.paused_inactivity == 0
    entering_pause.update(701 SECONDS, 900 SECONDS)
    results["input_before_pause_keeps_playable_idle"] = entering_pause.update(841 SECONDS, 900 SECONDS) == "warn"
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

    def test_connecting_client_does_not_inherit_idle_time_from_loading(self):
        source = (ROOT / 'modular_babylon/code/afk.dm').read_text().split('/// Inactive players', 1)[0]
        source = source.replace('/client', '/datum/client_probe')
        harness = '''
#define FALSE 0
#define TRUE 1
#define SECONDS * 10
#define PROC_REF(name) null
#define INVOKE_ASYNC(target, ignored, timeout) target.babylon_disconnect_afk(timeout)
/proc/span_userdanger(message)
    return message
/proc/DisplayTimeText(value)
    return "[value]"
/proc/to_chat(datum/client_probe/target, message)
    target.warnings++
/datum/client_probe
    var/inactivity = 20000
    var/fully_created = FALSE
    var/warnings = 0
    var/kicks = 0
    proc/babylon_disconnect_afk(timeout)
        kicks++
/world/New()
    var/datum/client_probe/player = new
    var/list/results = list()
    player.babylon_check_afk(900 SECONDS)
    results["loading_safe"] = !player.kicks && !player.warnings
    player.fully_created = TRUE
    player.inactivity = 2100 SECONDS
    player.babylon_check_afk(900 SECONDS)
    results["ready_starts_fresh"] = !player.kicks && !player.warnings
    player.inactivity = 2900 SECONDS
    player.babylon_check_afk(900 SECONDS)
    results["playable_idle_only"] = !player.kicks && !player.warnings
    player.inactivity = 2940 SECONDS
    player.babylon_check_afk(900 SECONDS)
    results["warning_after_ready"] = player.warnings == 1 && !player.kicks
    player.inactivity = 3000 SECONDS
    player.babylon_check_afk(900 SECONDS)
    results["kick_after_ready"] = player.kicks == 1
    var/datum/client_probe/first_ready_check = new
    first_ready_check.fully_created = TRUE
    first_ready_check.babylon_check_afk(900 SECONDS)
    results["first_check_after_loading_starts_fresh"] = !first_ready_check.kicks && !first_ready_check.warnings
    text2file(json_encode(results), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'probe.dme').write_text(harness + '\n' + source)
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for name, passed in json.loads((folder / 'results.json').read_text()).items():
                with self.subTest(name=name):
                    self.assertTrue(passed)
