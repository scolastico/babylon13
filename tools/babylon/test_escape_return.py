"""Exercise the production escape-menu override using native message dispatch.

Parent handling and client/window I/O are receiver boundaries; the real override
must call the established return verb, preserve other messages, and expose state.
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class EscapeReturn(unittest.TestCase):
    @unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
    def test_world_quit_uses_return_verb_and_nonworld_messages_reach_parent(self):
        override = ROOT / 'modular_babylon/code/escape_menu.dm'
        source = override.read_text() if override.exists() else ''
        # The base receiver implements the existing upstream message/quit boundary.
        harness = r'''
#define TRUE 1
#define FALSE 0
var/global/lobby_available = TRUE
/datum/client_probe
    var/returns = 0
    proc/babylon_lobby_link()
        return lobby_available ? "byond://example.invalid:1361" : null
    proc/babylon_return_lobby()
        returns++
/datum/menu_base
    var/datum/client_probe/client = new
    var/list/parent_messages = list()
    var/list/updates = list()
    proc/on_message(type, payload, href_list)
        parent_messages += list(list(type, payload))
        return FALSE
    proc/send_init()
        return
    proc/send_update(list/data)
        updates += list(data)
/datum/escape_menu
    parent_type = /datum/menu_base
/world/New()
    var/list/results = list()
    var/datum/escape_menu/menu = new
    menu.send_init()
    results["init"] = menu.updates.Copy()
    results["handled"] = menu.on_message("action", list("action" = "quit"), list())
    results["returns"] = menu.client.returns
    menu.on_message("action", list("action" = "settings"), list())
    menu.on_message("ready", null, list())
    results["other_messages"] = menu.parent_messages
    menu.parent_messages = list()
    lobby_available = FALSE
    menu.send_init()
    results["standalone_init"] = length(menu.updates) ? menu.updates[length(menu.updates)] : null
    menu.on_message("action", list("action" = "quit"), list())
    results["standalone_messages"] = menu.parent_messages
    results["standalone_returns"] = menu.client.returns
    text2file(json_encode(results), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'escape.dme').write_text(harness + '\n' + source + '\n')
            for command in (['DreamMaker', 'escape.dme'], ['DreamDaemon', 'escape.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            results = json.loads((folder / 'results.json').read_text())
        self.assertEqual(results['returns'], 1, 'World quit must call the existing return-to-lobby verb')
        self.assertEqual(results['handled'], 1)
        self.assertEqual(results['init'], [{'babylon': 1, 'canReturnToLobby': 1}])
        self.assertEqual(results['other_messages'], [['action', {'action': 'settings'}], ['ready', None]])
        self.assertEqual(results['standalone_init'], {'babylon': 1, 'canReturnToLobby': 0})
        self.assertEqual(results['standalone_messages'], [['action', {'action': 'quit'}]])
        self.assertEqual(results['standalone_returns'], 1)


if __name__ == '__main__':
    unittest.main()
