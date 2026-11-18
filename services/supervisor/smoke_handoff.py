"""Focused native handoff matrix; no DreamSeeker and no existing player data.

Compile the selected maps' babylon-test.dme and/or babylon-station-test.dme first.
Run from a source tree with its native/runtime assets (like smoke_native.py). --client-endpoint models winget's
server IP:port, not the player's IP. The routed child host must be reachable here.
--maps accepts a focused catalog matrix; station maps also check the loaded map
name and real late-join points. This checks real listeners, the actual DM router
and DM HTTP admission/replay. It does not exercise client.New, DreamSeeker skin
replacement or game-window readiness.
"""
import argparse
import json
from pathlib import Path
import secrets
import shutil
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import parse_qs, urlsplit

from catalog import load_catalog
from protocol import topic
from smoke_native import dm_entries
from supervisor import Driver, Supervisor, serve

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/babylon'))
from connection_probe import native_routes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dreamdaemon', required=True)
    parser.add_argument('--config-directory', required=True)
    parser.add_argument('--data-directory', required=True)
    parser.add_argument('--template-directory', default=str(ROOT))
    parser.add_argument('--api-port', type=int, default=15560)
    parser.add_argument('--child-port', type=int, default=15500)
    parser.add_argument('--client-endpoint', default='127.0.0.1:15561')
    parser.add_argument('--maps', nargs='+', default=['babylon', 'creative_plane_s', 'creative_plane_m',
                                                   'creative_plane_l', 'metastation'])
    args = parser.parse_args()
    data = Path(args.data_directory).resolve()
    template = Path(args.template_directory).resolve()
    if data.exists():
        raise RuntimeError('Use a new empty test data directory')
    catalog = load_catalog(template / '_maps/babylon/catalog.json')
    builds = {catalog[map_id]['build'] for map_id in args.maps}
    for build in ('babylon-test' if b == 'babylon' else 'babylon-station-test' for b in builds):
        for ext in ('dmb', 'rsc'):
            if not (template / f'{build}.{ext}').is_file():
                raise RuntimeError('Compile %s first' % build)
    for port in (args.api_port, args.child_port):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', port))
    config = dict(data_directory=str(data), template_directory=str(template),
                  config_directory=str(Path(args.config_directory).resolve()),
                  dreamdaemon=str(Path(args.dreamdaemon).resolve()),
                  listen_host='127.0.0.1', listen_port=args.api_port,
                  public_host='127.0.0.1', bind_address='0.0.0.0',
                  lobby_address='byond://127.0.0.1:15561', lobby_secret=secrets.token_urlsafe(32),
                  admins=['handoffowner'], port_first=args.child_port, port_last=args.child_port,
                  max_running_worlds=1, max_running_worlds_per_player=1, max_players_per_world=2,
                  max_worlds_per_player=10, ticket_lifetime_seconds=60,
                  empty_grace_seconds=3600, startup_timeout_seconds=600)

    class TestDriver(Driver):
        def prepare(self, world, run):
            root = super().prepare(world, run)
            build = 'babylon-station' if self.build_of(world) == 'station' else 'babylon'
            for ext in ('dmb', 'rsc'):
                shutil.copy2(template / f'{build}-test.{ext}', root / f'{build}.{ext}')
            return root

    service = Supervisor(config, TestDriver(config))
    threading.Thread(target=serve, args=(config, service), daemon=True).start()

    def api(action, payload=None):
        body = json.dumps(dict(secret=config['lobby_secret'], actor='handoffowner', action=action,
                               payload=payload or {})).encode()
        request = urllib.request.Request(f'http://127.0.0.1:{args.api_port}/api', data=body,
                                         headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        assert result.get('ok'), result.get('error')
        return result

    def current(world):
        with service.lock:
            run = service.row('SELECT * FROM runs WHERE world=?', (world,))
            return dict(run) if run else None

    def redeem(run, token):
        query = json.dumps(dict(action='redeem', actor='handoffowner', ticket=token))
        result = topic(run['port'], run['secret'], 'call', dict(
            target='session', proc='test_supervisor_export', args=[query]), timeout=30)
        assert result.get('ok'), 'Native admission probe failed'
        return dm_entries(result['result'])

    def stop(world):
        api('stop', dict(world=world))
        deadline = time.monotonic() + 120
        while current(world) and time.monotonic() < deadline:
            time.sleep(1)
        assert not current(world), 'Disposable child did not stop'

    deadline = time.monotonic() + 10
    while True:
        try:
            api('summary')
            break
        except urllib.error.URLError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(.05)

    report = []
    for map_id in args.maps:
        world = api('create', dict(name='Handoff ' + map_id, map=map_id, visibility='private',
                                   persistent=False, creative=map_id.startswith('creative')))['id']
        try:
            started = time.monotonic()
            assert api('join', dict(world=world)).get('pending'), 'Fresh world skipped readiness'
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                offered = api('join', dict(world=world))
                if offered.get('address'):
                    break
                time.sleep(2)
            else:
                raise TimeoutError('Child did not become ready')
            run = current(world)
            status = topic(run['port'], run['secret'], 'status')
            assert status['ready'] and status['run'] == run['id'] and status['world'] == world
            assert status.get('map') == map_id and status.get('build') == catalog[map_id]['build']
            assert service.driver.alive(run)
            result = dict(map=map_id, ready_seconds=round(time.monotonic() - started, 1))
            for phase in ('fresh', 'running'):
                if phase == 'running':
                    offered = api('join', dict(world=world))
                routed = native_routes(ROOT / 'modular_babylon/connection.dm',
                                       [[offered['address'], args.client_endpoint]])[0]
                assert routed, 'No valid routed address'
                destination = urlsplit(routed)
                assert destination.port == run['port'], 'Child port changed'
                token = parse_qs(destination.query)['babylon_ticket'][0]
                assert token == parse_qs(urlsplit(offered['address']).query)['babylon_ticket'][0]
                with socket.create_connection((destination.hostname, destination.port), timeout=5):
                    pass
                admission = redeem(run, token)
                assert admission.get('ok') and admission['world'] == world and admission['run'] == run['id']
                assert not redeem(run, token).get('ok'), 'One-use ticket replay admitted'
                result[phase + '_dm_admission'] = True
                result['endpoint'] = routed.split('?')[0]
            if catalog[map_id]['group'] == 'station':
                def station_values(proc):
                    reply = topic(run['port'], run['secret'], 'call', dict(
                        target='session', proc=proc, args=[]), timeout=30)
                    assert reply.get('ok'), 'Station native probe failed'
                    return dm_entries(reply['result'])
                info = station_values('test_station_info')
                source = json.loads((template / '_maps' / catalog[map_id]['map_json']).read_text())
                assert info['map_name'] == source['map_name'], (map_id, info['map_name'])
                overrides = station_values('test_station_arrival_overrides')
                print(json.dumps(dict(map=map_id, arrival_overrides=overrides)), flush=True)
                assert all(overrides.values()), (map_id, overrides)
                latejoin = station_values('test_station_latejoin')
                assert all(latejoin.values()), (map_id, latejoin)
                result['map_name'] = info['map_name']
                result['latejoin_spawns'] = info['latejoin_spawns']
                result['latejoin_source'] = info['latejoin_source']
                result['latejoin_checks'] = latejoin
                result['arrival_override_checks'] = overrides
                result['levels'] = info['levels']
            report.append(result)
            print(json.dumps(result), flush=True)
        finally:
            if current(world):
                stop(world)
    (data / 'result.json').write_text(json.dumps(dict(passed=True, worlds=report), indent=2))


if __name__ == '__main__':
    main()
