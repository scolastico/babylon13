"""Exercise the lobby/world shared session record using real native DM output."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
class SessionLogging(unittest.TestCase):
    def test_session_records_are_complete_and_one_line_even_with_player_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            shared = ROOT / 'modular_babylon/connection.dm'
            (folder / 'probe.dme').write_text('#include "' + shared.as_posix() + '"\n' + '''
/world/New()
    var/list/events = list("connect", "join_world", "leave_world", "return_to_lobby", "disconnect", "refused")
    for(var/event in events)
        text2file(babylon_session_log_line(event, "Test_User", "192.0.2.20", "A \\"world\\"\\nwith text", "world-id", "kicked\\nreason"), "records.log")
    text2file(babylon_session_log_line("connect", "Lobby_User", "192.0.2.21"), "records.log")
    text2file(babylon_session_log_line("connect", "Local_User", null), "records.log")
    shutdown()
''')
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            lines = (folder / 'records.log').read_text().splitlines()
            self.assertEqual(len(lines), 8)
            for event, line in zip(('connect', 'join_world', 'leave_world', 'return_to_lobby', 'disconnect', 'refused'), lines):
                prefix, encoded = line.split(' ', 1)
                self.assertEqual(prefix, 'BABYLON_SESSION')
                record = json.loads(encoded)
                self.assertRegex(record['time'], r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')
                self.assertEqual(record['event'], event)
                self.assertEqual(record['ckey'], 'testuser')
                self.assertEqual(record['ip'], '192.0.2.20')
                self.assertEqual(record['world_name'], 'A "world"\nwith text')
                self.assertEqual(record['world_id'], 'world-id')
                self.assertEqual(record['reason'], 'kicked\nreason')
            lobby = json.loads(lines[-2].split(' ', 1)[1])
            self.assertEqual(json.loads(lines[-1].split(' ', 1)[1])['ip'], '127.0.0.1')
            self.assertIsNone(lobby['world_name'])
            self.assertIsNone(lobby['world_id'])
            self.assertIsNone(lobby['reason'])

    def test_actual_lifecycle_hooks_log_one_leave_and_preserve_known_reason(self):
        source = (ROOT / 'modular_babylon/connection.dm').read_text()
        # /client cannot be constructed headlessly. Keep the production hook bodies on a datum
        # receiver with the same intrinsic identity fields, and capture the real world.log output.
        hooks = source[source.index('/proc/babylon_session_log_line'):]
        hooks = hooks.replace('/client/Del()', '/datum/session_probe/proc/disconnect()')
        hooks = hooks.replace('/client', '/datum/session_probe').replace('\treturn ..()\n', '')
        harness = '''
/datum/session_probe
    var/ckey = "Test_User"
    var/address = "192.0.2.20"
/world/New()
    log = file("records.log")
    params["babylon-world"] = "world-id"
    params["babylon-name"] = "Test world"
    var/datum/session_probe/player = new
    player.babylon_session_connected = 1
    player.babylon_log_session("connect")
    player.babylon_session_joined = 1
    player.babylon_log_session("join_world")
    player.babylon_set_leave_reason("quit")
    player.babylon_set_leave_reason("banned: test reason")
    player.disconnect()
    player.babylon_log_leave("ignored duplicate")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'probe.dme').write_text(hooks + '\n' + harness)
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            records = [json.loads(line.split('BABYLON_SESSION ', 1)[1])
                       for line in (folder / 'records.log').read_text().splitlines() if 'BABYLON_SESSION ' in line]
        self.assertEqual([record['event'] for record in records], ['connect', 'join_world', 'leave_world', 'disconnect'])
        self.assertEqual([record['reason'] for record in records[-2:]], ['banned: test reason', 'banned: test reason'])
        self.assertTrue(all(record['ip'] == '192.0.2.20' and record['world_id'] == 'world-id' for record in records))

    def test_preclient_ban_wrapper_keeps_policy_and_logs_the_refusal(self):
        moderation = (ROOT / 'modular_babylon/code/moderation.dm').read_text()
        hook = moderation[moderation.index('/world/IsBanned('):].replace('/world/IsBanned', '/datum/gate/IsBanned', 1)
        shared = ROOT / 'modular_babylon/connection.dm'
        harness = '''
#define FALSE 0
#define TRUE 1
var/global/gate_result
/datum/gate_base/proc/IsBanned(key, address, computer_id, type, real_bans_only = FALSE)
    return gate_result
/datum/gate
    parent_type = /datum/gate_base
/world/New()
    log = file("records.log")
    params["babylon-world"] = "world-id"
    params["babylon-name"] = "Test world"
    var/datum/gate/gate = new
    gate_result = list("reason" = "Banned", "desc" = "the existing policy")
    var/list/refused = gate.IsBanned("Test_User", "192.0.2.20", "test-only", "seeker")
    gate.IsBanned("Test_User", "192.0.2.20", "test-only", "seeker", TRUE)
    gate.IsBanned("Test_User", "192.0.2.20", "test-only", "world")
    gate_result = FALSE
    var/allowed = gate.IsBanned("Test_User", "192.0.2.20", "test-only", "seeker")
    text2file(json_encode(list("refused" = refused, "allowed" = allowed)), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'probe.dme').write_text('#include "' + shared.as_posix() + '"\n' + harness + '\n' + hook)
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            results = json.loads((folder / 'results.json').read_text())
            self.assertEqual(results, {'refused': {'reason': 'Banned', 'desc': 'the existing policy'}, 'allowed': 0})
            records = [json.loads(line.split('BABYLON_SESSION ', 1)[1])
                       for line in (folder / 'records.log').read_text().splitlines() if 'BABYLON_SESSION ' in line]
        self.assertEqual([record['event'] for record in records], ['connect', 'refused'])
        self.assertEqual(records[-1]['reason'], 'Banned')
        self.assertEqual(records[-1]['ip'], '192.0.2.20')
