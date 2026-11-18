"""Run the actual managed/round stop bodies: final departure causes beat stale intent.

Client construction and link output are unavailable headlessly, so those I/O
boundaries use datum receivers. Save/stop/supervisor calls are captured boundaries;
the production control flow, client loops, state guards and delays run unchanged.
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_window_startup import procedure

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
class StopLogging(unittest.TestCase):
    def test_stops_replace_old_intent_before_exit_with_or_without_lobby(self):
        methods = []
        for filename, declaration in (
            ('admission.dm', '/datum/babylon_save/proc/managed_stop_now()'),
            ('station_round.dm', '/datum/babylon_save/proc/end_world_without_save(delay)'),
        ):
            method = procedure((ROOT / 'modular_babylon/code' / filename).read_text(), declaration)
            self.assertIsNotNone(method, declaration)
            method = method.replace('/datum/babylon_save', '/datum/stop_probe')
            method = method.replace('var/client/', 'var/datum/player_probe/')
            # Replace only the client network-output expression, retaining its real branch.
            method = method.replace('player << link(lobby)', 'player.redirect(lobby)')
            methods.append(method)
        setter = procedure((ROOT / 'modular_babylon/connection.dm').read_text(),
                           '/client/proc/babylon_set_leave_reason(reason)')
        self.assertIsNotNone(setter)
        setter = setter.replace('/client', '/datum/player_probe', 1)
        harness = r'''
#define FALSE 0
#define TRUE 1
#define SECONDS * 10
var/global/datum/global_probe/GLOB = new
var/global/datum/ticker_probe/SSticker = new
/datum/global_probe
    var/list/clients = list()
    var/list/directory = list()
    var/datum/world_probe/babylon_world = new
/datum/world_probe
    var/owner_ckey = "owner"
/datum/ticker_probe
    var/delay_end = FALSE
/proc/babylon_stop_saves()
    return TRUE
/proc/babylon_stop_message(saves)
    return "stopping"
/proc/babylon_supervisor_request_within(list/payload)
    return list("ok" = TRUE)
/proc/babylon_next_start_text(owner = FALSE)
    return null
/proc/log_world(message)
    return
/proc/span_notice(message)
    return message
/proc/to_chat(target, message)
    return
/proc/DisplayTimeText(delay)
    return "[delay]"
/datum/player_probe
    var/babylon_session_left = FALSE
    var/babylon_session_leave_reason
    var/lobby_available = FALSE
    var/list/redirects = list()
    proc/babylon_lobby_link(reason)
        return lobby_available ? "byond://example.invalid:1361" : null
    proc/redirect(destination)
        redirects += list(list("destination" = destination, "reason" = babylon_session_leave_reason))
/datum/stop_probe
    var/draining = FALSE
    var/round_ending = FALSE
    var/round_end_at
    var/ready = TRUE
    var/boot_error
    var/idle = TRUE
    var/save_ok = TRUE
    var/save_calls = 0
    var/stop_calls = 0
    var/list/reasons_at_stop
    proc/await_save_idle(timeout)
        return idle
    proc/save_world()
        save_calls++
        return save_ok ? list("ok" = TRUE, "saved" = TRUE) : list("error" = "save failed")
    proc/round_end_delay()
        return 0
    proc/stop_world()
        stop_calls++
        reasons_at_stop = list()
        for(var/datum/player_probe/player in GLOB.clients)
            reasons_at_stop += list(player.babylon_session_leave_reason)
/world/New()
    var/list/results = list()
    for(var/method in list("managed", "round"))
        for(var/lobby in list(FALSE, TRUE))
            var/datum/player_probe/fresh = new
            var/datum/player_probe/stale = new
            fresh.lobby_available = lobby
            stale.lobby_available = lobby
            stale.babylon_session_leave_reason = "quit"
            GLOB.clients = list(fresh, stale)
            var/datum/stop_probe/probe = new
            var/list/outcome
            if(method == "managed")
                outcome = probe.managed_stop_now()
            else
                probe.end_world_without_save(0)
            // Keep the production three-second delay and observe the real delayed stop boundary.
            sleep(31)
            var/list/row = list("reasons" = probe.reasons_at_stop, "stops" = probe.stop_calls,
                "saves" = probe.save_calls, "draining" = probe.draining,
                "round_ending" = probe.round_ending, "fresh_redirects" = fresh.redirects,
                "stale_redirects" = stale.redirects, "outcome" = outcome)
            if(method == "round")
                probe.end_world_without_save(0)
                row["duplicate_stops"] = probe.stop_calls
            results["[method]_[lobby]"] = row
    for(var/failure in list("busy", "save"))
        var/datum/player_probe/player = new
        player.babylon_session_leave_reason = "quit"
        GLOB.clients = list(player)
        var/datum/stop_probe/probe = new
        probe.idle = failure != "busy"
        probe.save_ok = FALSE
        var/list/outcome = probe.managed_stop_now()
        results[failure] = list("error" = outcome["error"], "stops" = probe.stop_calls,
            "draining" = probe.draining, "reason" = player.babylon_session_leave_reason,
            "redirects" = player.redirects, "saves" = probe.save_calls)
    text2file(json_encode(results), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'probe.dme').write_text(harness + '\n' + setter + '\n' + '\n'.join(methods) + '\n')
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            results = json.loads((folder / 'results.json').read_text())
        for method in ('managed', 'round'):
            for lobby in (False, True):
                row = results[f'{method}_{int(lobby)}']
                with self.subTest(method=method, lobby=lobby):
                    self.assertEqual(row['stops'], 1)
                    self.assertEqual(row['saves'], int(method == 'managed'))
                    self.assertEqual(row['draining'], 1)
                    self.assertEqual(row['round_ending'], int(method == 'round'))
                    if method == 'managed':
                        self.assertEqual(row['outcome'], {'ok': 1, 'saved': 1})
                    else:
                        self.assertEqual(row['duplicate_stops'], 1)
                    for name in ('fresh_redirects', 'stale_redirects'):
                        self.assertEqual(row[name], [{'destination': 'byond://example.invalid:1361',
                                                     'reason': 'world_stopped'}] if lobby else [])
                    self.assertEqual(row['reasons'], ['world_stopped', 'world_stopped'],
                                     'Actual stop must replace missing and stale failed-quit intent')
        for failure in ('busy', 'save'):
            with self.subTest(failure=failure):
                row = results[failure]
                self.assertTrue(row['error'])
                self.assertEqual(row['stops'], 0)
                self.assertEqual(row['draining'], 0)
                self.assertEqual(row['reason'], 'quit')
                self.assertEqual(row['redirects'], [])
                self.assertEqual(row['saves'], int(failure == 'save'))


if __name__ == '__main__':
    unittest.main()
