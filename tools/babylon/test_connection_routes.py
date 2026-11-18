"""Run the shared connection router in native BYOND, without a client or player data."""
from pathlib import Path
import shutil
import unittest

from connection_probe import native_routes

ROOT = Path(__file__).resolve().parents[2]


class ConnectionRoutes(unittest.TestCase):
    @unittest.skipUnless(shutil.which('DreamMaker') and shutil.which('DreamDaemon'), 'native BYOND required')
    def test_routes_connected_server_without_changing_ports_or_ticket_queries(self):
        router = ROOT / 'modular_babylon/connection.dm'
        self.assertTrue(router.is_file(), 'Missing shared router: remote clients receive loopback destinations')
        cases = [
            # LAN, local and public clients keep the server host they actually reached.
            ['byond://127.0.0.1:1400?babylon_ticket=test-only', '192.0.2.10:1361',
             'byond://192.0.2.10:1400?babylon_ticket=test-only'],
            ['byond://127.0.0.1:1401?babylon_ticket=a_B-1', '127.0.0.1:1361',
             'byond://127.0.0.1:1401?babylon_ticket=a_B-1'],
            ['byond://localhost:1402?babylon_ticket=test-only', 'station.example.org:2361',
             'byond://station.example.org:1402?babylon_ticket=test-only'],
            ['byond://127.0.0.2:1403', '192.0.2.10:1361', 'byond://192.0.2.10:1403'],
            ['byond://LOCALHOST.:1404', '192.0.2.10:1361', 'byond://192.0.2.10:1404'],
            # Return, refusal notices and rejoin use the same routing, with the lobby's port.
            ['byond://127.0.0.1:1361', '192.0.2.10:1400', 'byond://192.0.2.10:1361'],
            ['byond://127.0.0.1:1361?babylon_notice=admission_timeout', '192.0.2.10:1400',
             'byond://192.0.2.10:1361?babylon_notice=admission_timeout'],
            ['byond://127.0.0.1:1361?babylon_rejoin=abc&spectate=1', '192.0.2.10:1400',
             'byond://192.0.2.10:1361?babylon_rejoin=abc&spectate=1'],
            # Configured public destinations remain authoritative, even without winget.
            ['byond://play.example.org:2500?babylon_ticket=test-only', '192.0.2.10:1361',
             'byond://play.example.org:2500?babylon_ticket=test-only'],
            ['byond://192.0.2.20:1361', None, 'byond://192.0.2.20:1361'],
        ]
        for endpoint in (None, '', '192.0.2.10:0', '192.0.2.10:65536', '0.0.0.0:1361',
                         '192.0.2.10:1361?injected=1', 'evil@example.org:1361',
                         'byond://192.0.2.10:1361', '192.0.2.10:1361/path', 'bad\nhost:1361'):
            cases.append(['byond://127.0.0.1:1400?babylon_ticket=test-only', endpoint, None])
        for destination in (None, '', 'http://example.org:1400', 'byond://0.0.0.0:1400',
                            'byond://127.0.0.1:0', 'byond://127.0.0.1:65536',
                            'byond://user@example.org:1400', 'byond://example.org:1400/path',
                            'byond://example.org:1400?ticket=x\ncommand=y',
                            'byond://example.org:1400#fragment', 'byond://example.org:1400\n'):
            cases.append([destination, '192.0.2.10:1361', None])
        actual = native_routes(router, [case[:2] for case in cases])
        self.assertEqual(len(actual), len(cases))
        for case, result in zip(cases, actual):
            with self.subTest(destination=case[0], endpoint=case[1]):
                self.assertEqual(result, case[2])


if __name__ == '__main__':
    unittest.main()
