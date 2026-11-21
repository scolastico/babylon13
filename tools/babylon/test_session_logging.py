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

    def test_world_shutdown_flushes_connected_sessions_without_duplicate_disconnects(self):
        from test_window_startup import procedure
        source = (ROOT / 'modular_babylon/connection.dm').read_text()
        self.assertIn('/world/Del()', source, 'World shutdown must flush sessions before deleting the world')
        helpers = source[source.index('/proc/babylon_session_log_line'):source.index('/client/Del()')]
        helpers = helpers.replace('/client', '/datum/session_probe')
        disconnect = procedure(source, '/client/Del()').replace('/client/Del()', '/datum/session_probe/proc/disconnect()')
        disconnect = disconnect.replace('\treturn ..()\n', '')
        # Native clients require DreamSeeker. Substitute only the client collection/receiver;
        # execute the actual shutdown hook through world.Del(), including its parent shutdown.
        world_hook = procedure(source, '/world/Del()').replace(
            'for(var/client/player)', 'for(var/datum/session_probe/player in connected_probes)')
        harness = '''
var/global/list/connected_probes = list()
/datum/session_probe
    var/ckey
    var/address = "192.0.2.20"
/world/New()
    log = file("records.log")
    params["babylon-world"] = "world-id"
    params["babylon-name"] = "Test world"
    var/datum/session_probe/player = new
    player.ckey = "Still_Here"
    player.babylon_session_connected = 1
    player.babylon_session_joined = 1
    player.babylon_set_leave_reason("quit")
    var/datum/session_probe/gone = new
    gone.ckey = "Already_Gone"
    gone.babylon_session_connected = 1
    gone.babylon_session_joined = 1
    gone.babylon_set_leave_reason("kicked")
    gone.disconnect()
    gone.disconnect()
    var/datum/session_probe/flushed = new
    flushed.ckey = "Already_Flushed"
    flushed.babylon_session_connected = 1
    flushed.babylon_session_joined = 1
    flushed.babylon_log_disconnect("world_stopped")
    flushed.disconnect()
    var/datum/session_probe/loading = new
    loading.ckey = "Loading"
    loading.babylon_session_connected = 1
    connected_probes = list(player, gone, loading, flushed)
    Del()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'probe.dme').write_text(helpers + '\n' + disconnect + '\n' + world_hook + '\n' + harness)
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            records = [json.loads(line.split('BABYLON_SESSION ', 1)[1])
                       for line in (folder / 'records.log').read_text().splitlines() if 'BABYLON_SESSION ' in line]
        self.assertEqual([r['event'] for r in records], ['leave_world', 'disconnect'] * 3 + ['disconnect'])
        self.assertEqual([r['ckey'] for r in records], ['alreadygone', 'alreadygone', 'alreadyflushed', 'alreadyflushed', 'stillhere', 'stillhere', 'loading'])
        self.assertEqual([r['reason'] for r in records], ['kicked', 'kicked'] + ['world_stopped'] * 5)
        self.assertTrue(all(r['world_id'] == 'world-id' and r['world_name'] == 'Test world' for r in records))

    def test_tutorial_entry_refusals_are_logged_before_a_world_exists(self):
        from test_window_startup import procedure
        shared = (ROOT / 'modular_babylon/connection.dm').read_text()
        logger = shared[shared.index('/proc/babylon_session_log_line'):shared.index('/client/Del()')]
        logger = logger.replace('/client', '/datum/session_probe')
        action = procedure((ROOT / 'modular_babylon/lobby/lobby.dm').read_text(),
                           '/mob/lobby/proc/tutorial_action(action, list/payload, request)')
        action = action.replace('/mob/lobby/proc/', '/datum/tutorial_probe/proc/', 1)
        harness = '''
/datum/session_probe
    var/ckey = "Test_User"
    var/address = "192.0.2.20"
/datum/tutorial_probe
    var/datum/session_probe/client = new
    var/list/tutorial_cards = list("test-id" = list("title" = "Test tutorial"))
    var/list/api_result = list("error" = "Running world limit reached")
    var/view_filter
    var/joins = 0
    proc/api(action, list/payload)
        return api_result
    proc/respond(request, list/data)
        return
    proc/show_loading(world_name, stage)
        return
    proc/join_world(id, world_name, list/join, request = 0, stage, retry)
        joins++
/world/New()
    log = file("records.log")
    var/datum/tutorial_probe/probe = new
    probe.tutorial_action("tutorial_play", list("tutorial" = "test-id"), 1)
    probe.tutorial_action("tutorial_edit", list("tutorial" = "test-id"), 2)
    probe.api_result = list("ok" = 1, "world" = "malformed")
    probe.tutorial_action("tutorial_play", list("tutorial" = "test-id"), 3)
    text2file(json_encode(list("joins" = probe.joins)), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'probe.dme').write_text(logger + '\n' + harness + '\n' + action)
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads((folder / 'results.json').read_text()), {'joins': 0})
            records = [json.loads(line.split('BABYLON_SESSION ', 1)[1])
                       for line in (folder / 'records.log').read_text().splitlines() if 'BABYLON_SESSION ' in line]
        self.assertEqual(len(records), 3)
        self.assertEqual([record['reason'] for record in records[:2]], ['Running world limit reached'] * 2)
        for record in records:
            self.assertEqual(record['event'], 'refused')
            self.assertEqual(record['ckey'], 'testuser')
            self.assertEqual(record['ip'], '192.0.2.20')
            self.assertEqual(record['world_name'], 'Test tutorial')
            self.assertIsNone(record['world_id'])

    def test_world_card_refusals_log_without_passwords_or_management_noise(self):
        from test_window_startup import procedure
        shared = (ROOT / 'modular_babylon/connection.dm').read_text()
        logger = shared[shared.index('/proc/babylon_session_log_line'):shared.index('/client/Del()')]
        logger = logger.replace('/client', '/datum/session_probe')
        lobby = (ROOT / 'modular_babylon/lobby/lobby.dm').read_text()
        action = procedure(lobby, '/mob/lobby/proc/handle_action(action, list/payload, request)')
        # Execute the actual card validation and join dispatcher; the rest handles unrelated actions.
        action = '/datum/card_probe/proc/dispatch(action, list/payload, request)\n' + action[
            action.index('\tvar/static/regex/world_id'):action.index('\tif(card["role"]')]
        harness = '''
/datum/session_probe
    var/ckey = "Test_User"
    var/address = "192.0.2.20"
/datum/card_probe
    var/datum/session_probe/client = new
    var/list/cards = list()
    var/joins = 0
    proc/respond(request, list/data)
        return
    proc/join_world(id, world_name, list/join, request = 0, retry)
        joins++
/world/New()
    log = file("records.log")
    var/datum/card_probe/probe = new
    var/id = "0123456789abcdef0123456789abcdef"
    probe.dispatch("join", list("world" = id), 1)
    probe.dispatch("join", list("world" = "invalid"), 2)
    probe.dispatch("edit", list("world" = id), 3)
    probe.cards[id] = list("name" = "Test world", "kind" = "creative")
    probe.dispatch("join", list("world" = id, "password" = list("private")), 4)
    probe.dispatch("join", list("world" = id), 5)
    text2file(json_encode(list("joins" = probe.joins)), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'probe.dme').write_text(logger + '\n' + procedure(lobby, '/proc/lobby_text(value, max_length)')
                                             + '\n' + harness + '\n' + action)
            for command in (['DreamMaker', 'probe.dme'], ['DreamDaemon', 'probe.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads((folder / 'results.json').read_text()), {'joins': 1})
            log = (folder / 'records.log').read_text()
            self.assertNotIn('private', log)
            records = [json.loads(line.split('BABYLON_SESSION ', 1)[1])
                       for line in log.splitlines() if 'BABYLON_SESSION ' in line]
        self.assertEqual(len(records), 3)
        self.assertEqual([record['event'] for record in records], ['refused'] * 3)
        self.assertEqual(records[0]['world_id'], '0123456789abcdef0123456789abcdef')
        self.assertIsNone(records[0]['world_name'])
        self.assertIsNone(records[1]['world_id'])
        self.assertEqual(records[2]['world_name'], 'Test world')
        self.assertEqual(records[2]['reason'], 'Use a password of at most 128 characters')
