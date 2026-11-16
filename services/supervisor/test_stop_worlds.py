import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from stop_worlds import running_worlds, stop_worlds


class Shutdown(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = dict(data_directory=self.temp.name)
        self.database = Path(self.temp.name) / 'supervisor.sqlite3'
        self.db = sqlite3.connect(self.database)
        self.db.executescript('CREATE TABLE worlds(id,owner,map); CREATE TABLE runs(world,state,error);')

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def world(self, name, owner, map_id='babylon'):
        with self.db:
            self.db.execute('INSERT INTO worlds VALUES(?,?,?)', (name, owner, map_id))
            self.db.execute("INSERT INTO runs VALUES(?,'running',NULL)", (name,))

    def test_stopped_cluster_is_noop(self):
        stop_worlds(self.config, request=lambda *_: self.fail('No stop request expected'))
        self.assertEqual(running_worlds(self.database), [])

    def test_every_world_is_requested_and_exit_is_waited_for(self):
        self.world('a', 'alice')
        self.world('b', 'bob')
        requests = []
        def stop(actor, world):
            requests.append((actor, world))
            with self.db:
                self.db.execute("UPDATE runs SET state='stopping' WHERE world=?", (world,))
        def exited(_):
            self.assertEqual(len(running_worlds(self.database)), 2)
            with self.db:
                self.db.execute('DELETE FROM runs')
        stop_worlds(self.config, request=stop, sleep=exited)
        self.assertEqual(requests, [('alice', 'a'), ('bob', 'b')])

    def test_save_failure_is_reported_and_run_is_retained(self):
        self.world('a', 'alice')
        def failed(*_):
            with self.db:
                self.db.execute("UPDATE runs SET state='error',error='disk full'")
        with self.assertRaisesRegex(RuntimeError, 'disk full'):
            stop_worlds(self.config, request=failed)
        self.assertEqual(len(running_worlds(self.database)), 1)

    def test_shutdown_waits_for_starting_world_before_requesting_save(self):
        self.world('a', 'alice')
        with self.db:
            self.db.execute("UPDATE runs SET state='starting'")
        ready = []
        def initialized(_):
            ready.append(True)
            with self.db:
                self.db.execute("UPDATE runs SET state='running'")
        def stopped(*_):
            self.assertTrue(ready)
            with self.db:
                self.db.execute('DELETE FROM runs')
        stop_worlds(self.config, request=stopped, sleep=initialized)

    def test_running_world_is_stopped_while_another_still_starts(self):
        # Review C-M3: a running world's final save does not wait for another world's start.
        self.world('a', 'alice')
        self.world('b', 'bob')
        with self.db:
            self.db.execute("UPDATE runs SET state='starting' WHERE world='b'")
        requests = []
        def stop(actor, world):
            requests.append(world)
            with self.db:
                self.db.execute("DELETE FROM runs WHERE world=?", (world,))
        passes = []
        def tick(_):
            passes.append(list(requests))
            if len(passes) == 2:
                with self.db:
                    self.db.execute("UPDATE runs SET state='running' WHERE world='b'")
        stop_worlds(self.config, request=stop, sleep=tick)
        self.assertEqual(passes[0], ['a'])
        self.assertEqual(requests, ['a', 'b'])

    def test_timeout_does_not_remove_or_kill_world(self):
        self.world('a', 'alice')
        with self.assertRaises(TimeoutError):
            stop_worlds(self.config, timeout=0, request=lambda *_: None)
        self.assertEqual(len(running_worlds(self.database)), 1)

    def catalog(self, build):
        directory = Path(self.temp.name) / 'cat'
        directory.mkdir(exist_ok=True)
        path = directory / 'catalog.json'
        path.write_text(json.dumps({'maps': [
            {'id': 'babylon', 'name': 'Babylon', 'description': 'd', 'group': 'babylon', 'size': None,
             'build': 'babylon', 'map_json': None, 'preview': None, 'multiz': False},
            {'id': 'box', 'name': 'Box', 'description': 'd', 'group': 'station', 'size': None,
             'build': build, 'map_json': 'box/box.json' if build == 'station' else None, 'preview': None,
             'multiz': False}]}))
        return str(path)

    def starting_world_times_out(self, map_id, build):
        self.world('a', 'alice', map_id)
        with self.db:
            self.db.execute("UPDATE runs SET state='starting'")
        now = [0]
        def sleep(seconds):
            now[0] += 100
        config = dict(self.config, station_startup_timeout_seconds=600, map_catalog=self.catalog(build))
        with self.assertRaises(TimeoutError):
            stop_worlds(config, timeout=180, request=lambda *_: None, sleep=sleep, clock=lambda: now[0])
        return now[0]

    def test_starting_station_world_waits_the_station_startup_timeout(self):
        self.assertGreaterEqual(self.starting_world_times_out('box', 'station'), 600)

    def test_starting_babylon_world_keeps_the_ordinary_wait(self):
        self.assertLess(self.starting_world_times_out('babylon', 'babylon'), 600)
