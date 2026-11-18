"""Idle time measures an available world, rather than process loading or a save."""
import unittest

import test_supervisor as fixtures


class IdleLifecycle(unittest.TestCase):
    setUp, tearDown = fixtures.Policies.setUp, fixtures.Policies.tearDown
    create, start, ticket = fixtures.Policies.create, fixtures.Policies.start, fixtures.Policies.ticket

    def test_loading_never_starts_empty_countdown(self):
        world = self.create()
        self.s.dispatch('owner', 'join', {'world': world})
        run = self.s.row('SELECT * FROM runs WHERE world=?', (world,))
        self.driver.runs[run['id']]['ready'] = False
        self.s.tick()
        self.now += 240
        self.s.tick()
        current = self.s.row('SELECT * FROM runs WHERE id=?', (run['id'],))
        self.assertEqual(current['state'], 'starting')
        self.assertIsNone(current['empty_since'])
        self.driver.runs[run['id']]['ready'] = True
        self.s.tick()
        current = self.s.row('SELECT * FROM runs WHERE id=?', (run['id'],))
        self.assertEqual(current['state'], 'running')
        self.assertEqual(current['empty_since'], self.now)

    def test_legacy_loading_idle_time_is_discarded_at_readiness(self):
        world = self.create()
        self.s.dispatch('owner', 'join', {'world': world})
        run = self.s.row('SELECT * FROM runs WHERE world=?', (world,))
        self.s.db.execute('UPDATE runs SET empty_since=? WHERE id=?', (self.now, run['id']))
        self.now += 240
        self.s.tick()
        self.assertEqual(self.s.row('SELECT state FROM runs WHERE id=?', (run['id'],))['state'], 'running')

    def test_ticket_and_redeemed_transfer_keep_world_alive(self):
        world = self.create()
        run = self.start(world)
        self.now += 119
        token = self.ticket(world)
        self.now += 59
        self.s.tick()
        self.assertIsNone(self.s.row('SELECT empty_since FROM runs WHERE id=?', (run['id'],))['empty_since'])
        self.s.redeem(run['id'], run['secret'], token, 'owner')
        self.now += 29
        self.s.tick()
        self.assertIsNone(self.s.row('SELECT empty_since FROM runs WHERE id=?', (run['id'],))['empty_since'])
        self.now += 2
        self.s.tick()
        self.assertEqual(self.s.row('SELECT empty_since FROM runs WHERE id=?', (run['id'],))['empty_since'], self.now)

    def test_busy_save_never_consumes_empty_grace(self):
        world = self.create()
        run = self.start(world)
        real_status = self.driver.status
        self.driver.status = lambda run: dict(real_status(run), busy=True)
        self.now += 240
        self.s.tick()
        current = self.s.row('SELECT * FROM runs WHERE id=?', (run['id'],))
        self.assertEqual(current['state'], 'running')
        self.assertIsNone(current['empty_since'])
        self.driver.status = real_status
        self.s.tick()
        self.assertEqual(self.s.row('SELECT empty_since FROM runs WHERE id=?', (run['id'],))['empty_since'], self.now)

    def test_answering_but_never_ready_world_has_startup_deadline(self):
        world = self.create()
        self.s.dispatch('owner', 'join', {'world': world})
        run = self.s.row('SELECT * FROM runs WHERE world=?', (world,))
        self.driver.runs[run['id']]['ready'] = False
        self.now += 301
        self.s.tick()
        current = self.s.row('SELECT * FROM runs WHERE id=?', (run['id'],))
        self.assertEqual(current['state'], 'error')
        self.assertIn('Startup timed out', current['error'])
        self.assertTrue(self.driver.alive(run))

    def test_empty_countdown_starting_at_zero_still_expires(self):
        self.now = 0
        world = self.create()
        run = self.start(world)
        self.now = 120
        self.s.tick()
        current = self.s.row('SELECT state FROM runs WHERE id=?', (run['id'],))
        self.assertTrue(current is None or current['state'] == 'stopping')

    def test_unanswering_world_does_not_accumulate_playable_idle(self):
        world = self.create()
        run = self.start(world)
        real_status = self.driver.status
        def unavailable(run):
            raise TimeoutError('snapshot capture blocks the game thread')
        self.driver.status = unavailable
        self.now += 240
        self.s.tick()
        self.driver.status = real_status
        self.s.tick()
        current = self.s.row('SELECT * FROM runs WHERE id=?', (run['id'],))
        self.assertEqual(current['state'], 'running')
        self.assertEqual(current['empty_since'], self.now)

    def test_errored_tutorial_is_reclaimed_even_if_stuck_busy(self):
        world = self.create()
        run = self.start(world)
        self.s.db.execute("UPDATE worlds SET kind='tutorial' WHERE id=?", (world,))
        real_status = self.driver.status
        self.driver.status = lambda run: dict(real_status(run), ready=False, busy=True, error='Startup failed')
        self.s.tick()
        self.now += 121
        self.s.tick()
        self.assertIsNone(self.s.row('SELECT * FROM runs WHERE id=?', (run['id'],)))
        self.assertFalse(self.driver.alive(run))
