"""Compile the production verb metadata and inspect the categories exported to statbrowser."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Both game builds share the controls; session-specific variants are compiled together
# here because their names are distinct and metadata has no game dependencies.
FILES = ('admission.dm', 'session.dm', 'station_session.dm', 'station_round.dm',
         'world_players.dm', 'creative/panel.dm')


class WorldControls(unittest.TestCase):
    @unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
    def test_every_world_control_exports_the_same_category(self):
        declarations, references = [], []
        for filename in FILES:
            source = (ROOT / 'modular_babylon/code' / filename).read_text()
            for match in re.finditer(r'^(/(?:[^/\n]+/)+(?:verb|proc)/[^\n]+)\n((?:\tset [^\n]+\n)+)', source, re.M):
                declaration, attributes = match.groups()
                if not re.search(r'set category = "(?:Babylon|World Controls)"', attributes):
                    continue
                declarations.append(declaration + '\n' + attributes)
                references.append(declaration.split('(')[0])
        self.assertEqual(len(references), 12, 'All world controls, including owner-only verbs')
        harness = '/world/New()\n    var/list/results = list()\n'
        for index, reference in enumerate(references):
            harness += f'    var/verb{index} = {reference}\n    results["{reference}"] = verb{index}:category\n'
        harness += '    text2file(json_encode(results), "results.json")\n    shutdown()\n'
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'verbs.dme').write_text('\n'.join(declarations) + '\n' + harness)
            for command in (['DreamMaker', 'verbs.dme'], ['DreamDaemon', 'verbs.dmb', '-invisible', '-trusted']):
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            exported = json.loads((folder / 'results.json').read_text())
        self.assertEqual(set(exported), set(references))
        for reference, category in exported.items():
            with self.subTest(verb=reference):
                self.assertEqual(category, 'World Controls')


if __name__ == '__main__':
    unittest.main()
