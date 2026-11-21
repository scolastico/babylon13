"""Execute real native layout hooks with window I/O captured on a headless receiver."""
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_window_startup import procedure

ROOT = Path(__file__).resolve().parents[2]


class TopBar(unittest.TestCase):
    @unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
    def test_showcase_visitors_keep_the_pane_resize_callback(self):
        source = (ROOT / 'modular_babylon/code/showcase.dm').read_text()
        allowed = procedure(source, '/proc/babylon_showcase_allowed_verb(verb_path)')
        paths = set(re.findall(r'/(?:client|mob)[/\w]+', allowed))
        paths.add('/client/verb/babylon_layout_top_bar')
        declarations = '\n'.join(path + '()\n    return' for path in sorted(paths))
        harness = declarations + '\n' + allowed + '''
/world/New()
    text2file(json_encode(babylon_showcase_allowed_verb(/client/verb/babylon_layout_top_bar)), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'visitor.dme').write_text(harness)
            for command in (['DreamMaker', 'visitor.dme'], ['DreamDaemon', 'visitor.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(json.loads((folder / 'results.json').read_text()))

    @unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
    def test_visible_controls_fill_four_equal_columns_after_each_resize(self):
        source = (ROOT / 'modular_babylon/code/interface.dm').read_text()
        hooks = []
        for name in ('babylon_setup_top_bar', 'babylon_layout_top_bar'):
            declaration = '/client/' + ('verb/' if name == 'babylon_layout_top_bar' else 'proc/') + name + '()'
            body = procedure(source, declaration)
            if body:
                body = body.replace("'modular_babylon/icons/babylon13_64.png'", '"icon-fixture"')
                hooks.append(body.replace(declaration, '/datum/window_probe/proc/' + name + '()', 1))
        resize = procedure(source, '/client/verb/babylon_window_resized()')
        hooks.append(resize.replace('/client/verb/babylon_window_resized()', '/datum/window_probe/proc/babylon_window_resized()', 1))
        harness = r'''
#define TRUE 1
#define addtimer(callback, delay, flags)
#define winset(target, control, settings) target.write_window(control, settings)
#define winget(target, control, setting) target.read_window(control, setting)
/datum/window_probe
    var/width = 640
    var/list/writes = list()
    proc/read_window(control, setting)
        if(control == "infobuttons" && setting == "size")
            return "[width]x32"
        return null
    proc/write_window(control, settings)
        writes += list(list("control" = control, "settings" = islist(settings) ? settings : params2list(replacetext(settings, ";", "&"))))
/world/New()
    var/list/results = list()
    var/datum/window_probe/window = new
    var/first = TRUE
    for(var/width in list(240, 320, 641, 1280, 320))
        window.width = width
        window.writes = list()
        if(first)
            window.babylon_setup_top_bar()
            first = 0
        else
            window.babylon_window_resized()
        results += list(list("width" = width, "writes" = window.writes))
    text2file(json_encode(results), "results.json")
    shutdown()
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'bar.dme').write_text(harness + '\n' + '\n\n'.join(hooks) + '\n')
            for command in (['DreamMaker', 'bar.dme'], ['DreamDaemon', 'bar.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            results = json.loads((folder / 'results.json').read_text())
        first_controls = {write['control']: write['settings'] for write in results[0]['writes']}
        self.assertEqual(first_controls.get('infobuttons', {}).get('on-size'), 'babylon-top-bar-resized',
                         'The pane must also reflow when only the map/chat splitter moves')
        for result in results:
            with self.subTest(width=result['width']):
                controls = {write['control']: write['settings'] for write in result['writes']}
                edges, widths = [], []
                for name in ('options', 'settings', 'fullscreen-toggle', 'reconnect'):
                    settings = controls.get('infobuttons.' + name, {})
                    self.assertIn('pos', settings, name + ' needs a measured position')
                    self.assertIn('size', settings, name + ' needs a measured size')
                    left, top = map(int, settings['pos'].split(','))
                    width, height = map(int, settings['size'].split('x'))
                    if result['width'] == 240:
                        self.assertLessEqual(int(settings.get('font-size', 10)), 7, 'Narrow buttons must fit their labels')
                    self.assertGreater(width, 0)
                    self.assertGreater(height, 0)
                    self.assertGreaterEqual(top, 0)
                    self.assertLessEqual(top + height, 32)
                    edges.append((left, left + width))
                    widths.append(width)
                self.assertLessEqual(max(widths) - min(widths), 1)
                self.assertEqual(edges[0][0], 2)
                self.assertEqual(edges[-1][1], result['width'] - 2)
                self.assertEqual([edges[i + 1][0] - edges[i][1] for i in range(3)], [3, 3, 3])


if __name__ == '__main__':
    unittest.main()
