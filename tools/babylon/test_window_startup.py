"""Startup contracts, plus production DM hook bodies run on headless test receivers.

The probe supplies window I/O/preferences/context doubles and records winset calls.
Ownership is checked statically; no Windows foreground window can be observed here.
Run with the BYOND toolchain on PATH to exercise the lifecycle rather than just bindings.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOBBY = ROOT / 'modular_babylon/lobby/lobby.dm'
GAME = ROOT / 'modular_babylon/code/interface.dm'


def procedure(source, declaration):
    match = re.search(r'^' + re.escape(declaration) + r'\n((?:\t[^\n]*\n|\n)*)', source, re.M)
    return match.group(0).rstrip() if match else None


class WindowStartup(unittest.TestCase):
    def test_lobby_load_notification_is_separate_from_refresh_and_actions(self):
        source = LOBBY.read_text()
        self.assertTrue("onload='lobbyWindowReady" in source, 'Lobby document must notify on load')
        topic = procedure(source, '/mob/lobby/Topic(href, list/params)')
        self.assertIn('client.lobby_window_ready()', topic)
        self.assertLess(topic.index('client.lobby_window_ready()'), topic.index('run_action('))
        self.assertIn('params["generation"] == "[poll_generation]"', topic)
        self.assertIn('browser_initialized', topic)
        self.assertLess(topic.index('usr != src'), topic.index('client.lobby_window_ready()'))
        for declaration in ('/mob/lobby/proc/show_browser(complete = 0)',
                            '/mob/lobby/proc/render_page(content, revision, complete, list/state)'):
            self.assertNotIn('winset(', procedure(source, declaration))

    def test_game_startup_is_visible_only_and_resize_does_not_activate(self):
        source = GAME.read_text()
        watcher = procedure(source, '/client/proc/babylon_watch_game_window()')
        self.assertRegex(watcher, r'if\(winget\(src, "mainwindow", "is-visible"\) == "true"\)[\s\S]*?babylon_game_window_shown\(\)\n\t\t\treturn')
        resize = procedure(source, '/client/verb/babylon_window_resized()')
        self.assertNotIn('winset(', resize)
        self.assertNotIn('window_shown(', resize)
        for name in ('babylon.dme', 'babylon-station.dme'):
            self.assertIn('#include "modular_babylon/code/interface.dm"', (ROOT / name).read_text())

    @unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
    def test_native_hooks_activate_once_per_connection_after_visibility(self):
        lobby = LOBBY.read_text()
        game = GAME.read_text()
        hooks = []
        for source, name in ((lobby, 'lobby_window_ready'), (game, 'babylon_game_window_shown')):
            declaration = '/client/proc/' + name + '()'
            body = procedure(source, declaration)
            self.assertIsNotNone(body, 'Missing startup hook: ' + name)
            hooks.append(body.replace(declaration, '/datum/window_probe/proc/' + name + '()', 1))
        # Use the real per-client state declarations, so static/mob-scoped state cannot pass.
        for source, flag in ((lobby, 'lobby_window_started'), (game, 'babylon_window_started')):
            block = procedure(source, '/client')
            declaration = re.search(r'^\tvar/' + flag + r' = .*$', block, re.M)
            self.assertIsNotNone(declaration, 'Startup state must belong to each client: ' + flag)
            hooks.append('/datum/window_probe\n' + declaration.group(0))
        hooks.append(procedure(lobby, '/mob/lobby/Topic(href, list/params)').replace(
            '/mob/lobby/Topic', '/datum/topic_probe/Topic', 1))
        harness = r'''
#define FALSE 0
#define TRUE 1
#define SECONDS *10
#define winset(target, control, settings) target.record_window(control, settings)
#define winget(target, control, setting) target.read_window(control, setting)
#define usr src
/datum/preference/toggle/fullscreen_mode
/datum/probe_preferences
    var/fullscreen = FALSE
    proc/read_preference(kind)
        return fullscreen
/datum/window_probe
    var/list/writes = list()
    var/datum/probe_preferences/prefs = new
    var/visible = TRUE
    var/reads = 0
    var/fits = 0
    proc/read_window(control, setting)
        reads++
        return visible && reads > 1 ? "true" : "false"
    proc/record_window(control, settings)
        writes += list(list("control" = control, "settings" = settings, "reads" = reads))
    proc/babylon_window_resized()
        fits++
/datum/topic_probe
    var/datum/window_probe/client = new
    var/browser_initialized = TRUE
    var/poll_generation = 7
    var/actions = 0
    proc/respond(request, list/data)
        actions++
    proc/run_action(action, list/payload, request)
        actions++
/proc/lobby_request_id(value)
    return 0
/proc/lobby_decode_payload(value)
    return list()
/world/New()
    var/list/results = list()
    var/datum/window_probe/lobby = new
    lobby.lobby_window_ready()
    lobby.lobby_window_ready()
    results["lobby"] = lobby.writes
    var/datum/window_probe/returned = new
    returned.lobby_window_ready()
    results["returned"] = returned.writes
    var/datum/window_probe/game = new
    game.babylon_game_window_shown()
    game.babylon_game_window_shown()
    game.babylon_window_resized()
    results["game"] = game.writes
    results["fits"] = game.fits
    var/datum/window_probe/fullscreen = new
    fullscreen.prefs.fullscreen = TRUE
    fullscreen.babylon_game_window_shown()
    fullscreen.babylon_game_window_shown()
    results["fullscreen"] = fullscreen.writes
    var/datum/window_probe/hidden = new
    hidden.visible = FALSE
    hidden.lobby_window_ready()
    results["hidden"] = hidden.writes
    var/datum/topic_probe/page = new
    page.Topic(null, list("action" = "window_ready", "generation" = "6"))
    results["stale_started"] = page.client.lobby_window_started
    page.browser_initialized = FALSE
    page.Topic(null, list("action" = "window_ready", "generation" = "7"))
    results["uninitialized_started"] = page.client.lobby_window_started
    page.browser_initialized = TRUE
    page.Topic(null, list("action" = "window_ready", "generation" = "7"))
    page.Topic(null, list("action" = "window_ready", "generation" = "7"))
    results["callback"] = page.client.writes
    results["actions"] = page.actions
    sleep(30)
    text2file(json_encode(results), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'windows.dme').write_text(harness + '\n' + '\n\n'.join(hooks) + '\n')
            for command in (['DreamMaker', 'windows.dme'],
                            ['DreamDaemon', 'windows.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            results = json.loads((folder / 'results.json').read_text())
        for path in ('lobby', 'returned', 'game', 'fullscreen', 'callback'):
            writes = results[path]
            self.assertTrue(writes, path)
            self.assertTrue(all(write['control'] == 'mainwindow' for write in writes), path)
            settings = [entry for write in writes for entry in write['settings'].split(';')]
            self.assertEqual(settings.count('focus=true'), 1, path)
            self.assertFalse(any(entry.startswith('is-fullscreen=') for entry in settings), path)
            if path != 'fullscreen':
                self.assertEqual(settings.count('is-maximized=true'), 1, path)
                self.assertLess(settings.index('is-maximized=true'), settings.index('focus=true'), path)
            else:
                self.assertNotIn('is-maximized=true', settings)
            if path in ('lobby', 'returned'):
                self.assertTrue(all(write['reads'] >= 2 for write in writes), 'Wait for visibility')
        self.assertEqual(results['fits'], 2, 'Startup fits once; a later resize still fits')
        self.assertEqual(results['hidden'], [], 'A hidden window must never activate')
        self.assertEqual(results['stale_started'], 0, 'A previous connection cannot start activation')
        self.assertEqual(results['uninitialized_started'], 0, 'Wait for the document to exist')
        self.assertEqual(results['actions'], 0, 'Readiness must not enter or refresh page actions')


if __name__ == '__main__':
    unittest.main()
