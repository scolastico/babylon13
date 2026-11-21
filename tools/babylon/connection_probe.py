"""Test utility: execute the shared DM router on private input in a disposable native world."""
import json
from pathlib import Path
import subprocess
import tempfile


def native_routes(router, cases):
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        (folder / 'cases.json').write_text(json.dumps(cases))
        (folder / 'routes.dme').write_text('#include "' + router.as_posix() + '"\n' + '''
/world/New()
    var/list/cases = json_decode(file2text("cases.json"))
    var/list/results = list()
    for(var/list/entry in cases)
        results += list(babylon_connection_address(entry[1], entry[2]))
    text2file(json_encode(results), "results.json")
    shutdown()
''')
        for command in (['DreamMaker', 'routes.dme'],
                        ['DreamDaemon', 'routes.dmb', '-invisible', '-trusted']):
            result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise RuntimeError('Native router failed: ' + result.stdout + result.stderr)
        return json.loads((folder / 'results.json').read_text())
