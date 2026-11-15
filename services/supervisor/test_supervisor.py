import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from supervisor import Denied, Supervisor


class FakeDriver:
    def __init__(self):
        self.runs = {}
        self.starts = 0
        self.fail_save = False
        self.saves = True

    def start(self, world, run):
        return self.spawn(world, run, self.prepare(world, run))

    def prepare(self, world, run):
        return None

    def spawn(self, world, run, root):
        self.starts += 1
        self.runs[run["id"]] = dict(run, players=[], ready=True)
        return 123

    def alive(self, run):
        return run["id"] in self.runs

    def status(self, run):
        r = self.runs[run["id"]]
        return dict(world=r["world"], run=r["id"], players=r["players"], ready=r["ready"],
                    draining=r.get("draining", False))

    def announce(self, run, message):
        self.announced = getattr(self, "announced", []) + [(run["id"], message)]
        return {"ok": True}

    def kill(self, run):
        self.killed = getattr(self, "killed", []) + [run["id"]]
        self.runs.pop(run["id"], None)

    def stop(self, run):
        if self.fail_save:
            return {"error": "disk full"}
        del self.runs[run["id"]]
        # What managed_stop answers (admission.dm): worlds that are not saved stop without a save.
        return {"ok": True, "saved": int(self.saves)}

    def ahelp_reply(self, run, payload):
        self.replies = getattr(self, "replies", []) + [(run["id"], payload)]
        if payload["ckey"] == "gone":
            return {"ok": 0, "result": "The player is no longer in this world"}
        return {"ok": 1, "result": "Message Successful"}

    def ahelp_close(self, run, payload):
        self.closed = getattr(self, "closed", []) + [(run["id"], payload)]
        if payload["ticket"] == 4:
            return {"ok": 0, "result": "That ticket is already closed"}
        return {"ok": 1, "result": "Closed"}


class Policies(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.driver = FakeDriver()
        self.now = 1000
        self.config = dict(data_directory=self.temp.name, max_worlds_per_player=3,
                           max_running_worlds_per_player=1, max_running_worlds=2,
                           max_players_per_world=2, port_first=1400, port_last=1402,
                           ticket_lifetime_seconds=60, empty_grace_seconds=120,
                           startup_timeout_seconds=300, public_host="localhost", admins=["admin"])
        self.s = Supervisor(self.config, self.driver, lambda: self.now)
        # A start finishes inside dispatch() here; Launches tests the background launch.
        self.s.background_launches = False

    def tearDown(self):
        for _ in range(100):
            if not self.s.stop_workers:
                break
            time.sleep(.01)
        self.s.db.close()
        self.temp.cleanup()

    def create(self, actor="owner", **kwargs):
        return self.s.dispatch(actor, "create", dict(name="World", visibility="public", **kwargs))["id"]

    def start(self, world, actor="owner", **kwargs):
        self.assertTrue(self.s.dispatch(actor, "join", dict(world=world, **kwargs))["pending"])
        self.s.tick()
        return self.s.row("SELECT * FROM runs WHERE world=?", (world,))

    def ticket(self, world, actor="owner", **kwargs):
        result = self.s.dispatch(actor, "join", dict(world=world, **kwargs))
        return result["address"].split("babylon_ticket=")[1]

    def test_private_members_and_admin(self):
        w = self.s.dispatch("owner", "create", {"name": "Private", "visibility": "private"})["id"]
        self.assertEqual(self.s.dispatch("stranger", "list", {})["worlds"], [])
        # The lobby swaps the world list for its restart screen while the server restarts.
        self.assertFalse(self.s.dispatch("stranger", "list", {})["restarting"])
        self.assertEqual(self.s.restart_screen_shown, set())
        self.s.shutting_down = True
        self.assertTrue(self.s.dispatch("stranger", "list", {})["restarting"])
        # The container keeps the lobby up until the players sent back have seen that screen.
        self.assertEqual(self.s.restart_screen_shown, {"stranger"})
        self.s.shutting_down = False
        with self.assertRaises(Denied):
            self.s.dispatch("stranger", "join", {"world": w})
        self.s.dispatch("owner", "member", {"world": w, "member": "friend"})
        run = self.start(w, "friend")
        token = self.ticket(w, "admin")
        self.assertEqual(self.s.redeem(run["id"], run["secret"], token, "admin")["role"], "admin")

    def test_an_exit_seen_by_two_ticks_is_handled_once(self):
        # The container's shutdown loop ticks beside the monitor thread: both can see one exit.
        w = self.create()
        run = self.start(w)
        del self.driver.runs[run["id"]]
        logged = []
        maintained = []
        real = self.s.maintain_checkpoints
        with patch("supervisor.log", logged.append), \
                patch.object(self.s, "maintain_checkpoints", lambda world: maintained.append(world) or real(world)):
            self.s.on_run_exited(dict(run))
            self.s.on_run_exited(dict(run))
        self.assertEqual(len([line for line in logged if "(port" in line]), 1, logged)
        self.assertEqual(maintained, [w])
        self.assertIsNone(self.s.row("SELECT * FROM runs WHERE id=?", (run["id"],)))

    def test_showcase_guest_visits_while_members_and_admins_play(self):
        world = self.s.dispatch("owner", "create", dict(name="Showcase", visibility="showcase", max_players=2))["id"]
        self.assertEqual(self.s.dispatch("visitor", "list", {})["worlds"][0]["visibility"], "showcase")
        self.s.dispatch("owner", "member", dict(world=world, member="friend"))
        run = self.start(world)
        for actor, expected in (("visitor", "showcase"), ("friend", "player"), ("owner", "player"), ("admin", "player")):
            with self.subTest(actor=actor):
                token = self.ticket(world, actor)
                result = self.s.redeem(run["id"], run["secret"], token, actor)
                self.assertEqual(result["mode"], expected)
                self.s.db.execute("DELETE FROM sessions")

    def test_showcase_mode_is_decided_at_redemption_not_from_join_payload(self):
        world = self.s.dispatch("owner", "create", dict(name="Showcase", visibility="showcase"))["id"]
        run = self.start(world)
        token = self.ticket(world, "visitor", mode="player", role="owner")
        self.assertEqual(self.s.redeem(run["id"], run["secret"], token, "visitor")["mode"], "showcase")
        token = self.ticket(world, "upgraded")
        self.s.dispatch("owner", "member", dict(world=world, member="upgraded"))
        # Membership changes revoke that actor's pending ticket.
        with self.assertRaises(Denied):
            self.s.redeem(run["id"], run["secret"], token, "upgraded")
        token = self.ticket(world, "upgraded")
        self.assertEqual(self.s.redeem(run["id"], run["secret"], token, "upgraded")["mode"], "player")

    def test_showcase_tickets_fail_when_world_becomes_private(self):
        world = self.s.dispatch("owner", "create", dict(name="Showcase", visibility="showcase"))["id"]
        run = self.start(world)
        token = self.ticket(world, "visitor")
        # Simulate an access change racing with ticket redemption.
        self.s.db.execute("UPDATE worlds SET visibility='private' WHERE id=?", (world,))
        with self.assertRaisesRegex(Denied, "Access has changed"):
            self.s.redeem(run["id"], run["secret"], token, "visitor")

    def test_public_guests_still_get_normal_play_mode(self):
        world = self.create()
        run = self.start(world)
        token = self.ticket(world, "visitor")
        self.assertEqual(self.s.redeem(run["id"], run["secret"], token, "visitor")["mode"], "player")

    def test_password_and_no_password_leak(self):
        w = self.s.dispatch("owner", "create", {"name": "Locked", "visibility": "password", "password": "secret"})["id"]
        self.assertNotIn("secret", json.dumps(self.s.dispatch("visitor", "list", {})))
        with self.assertRaises(Denied):
            self.s.dispatch("other", "join", {"world": w, "password": "wrong"})
        run = self.start(w)
        token = self.ticket(w, "other", password="secret")
        self.assertTrue(self.s.redeem(run["id"], run["secret"], token, "other")["ok"])

    def test_ticket_binding_expiry_and_replay(self):
        w = self.create()
        run = self.start(w)
        token = self.ticket(w)
        for run_id, key, actor in ((run["id"], run["secret"], "thief"), (run["id"], "wrong", "owner"), ("oldrun", run["secret"], "owner")):
            with self.assertRaises(Denied):
                self.s.redeem(run_id, key, token, actor)
        self.assertTrue(self.s.redeem(run["id"], run["secret"], token, "owner")["ok"])
        with self.assertRaises(Denied):
            self.s.redeem(run["id"], run["secret"], token, "owner")
        token = self.ticket(w)
        self.now += 61
        with self.assertRaises(Denied):
            self.s.redeem(run["id"], run["secret"], token, "owner")

    def test_quotas_reservations_and_duplicate_starts(self):
        w = self.create()
        run = self.start(w)
        self.ticket(w, "first")
        self.ticket(w, "second")
        with self.assertRaises(Denied):
            self.ticket(w, "third")
        self.assertEqual(self.driver.starts, 1)
        w2 = self.create()
        with self.assertRaises(Denied):
            self.start(w2)
        self.create()
        with self.assertRaises(Denied):
            self.create()
        self.assertEqual(self.s.row("SELECT count(*) n FROM runs")["n"], 1)

    def test_concurrent_join_single_process(self):
        w = self.create()
        for i in range(8):
            self.s.dispatch("owner", "member", {"world": w, "member": "p" + str(i)})
        errors = []
        def join(actor):
            try:
                self.s.dispatch(actor, "join", {"world": w})
            except Exception as error:
                errors.append(error)
        threads = [threading.Thread(target=join, args=("p" + str(i),)) for i in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        self.assertEqual(self.driver.starts, 1)

    def test_guests_cannot_start_public_password_or_showcase_worlds(self):
        for visibility in ("public", "password", "showcase"):
            with self.subTest(visibility=visibility):
                w = self.s.dispatch("owner", "create", {"name": "Offline", "visibility": visibility, "password": "secret"})["id"]
                with self.assertRaisesRegex(Denied, "offline"):
                    self.s.dispatch("visitor", "join", {"world": w, "password": "secret"})
        self.assertEqual(self.driver.starts, 0)
        self.assertEqual(self.s.row("SELECT count(*) n FROM runs")["n"], 0)

    def test_admins_are_not_limited_by_per_owner_world_rules(self):
        self.s.config["port_last"] = 1405
        for _ in range(self.config["max_worlds_per_player"] + 1):
            self.create("admin")
        with self.assertRaisesRegex(Denied, "world limit"):
            for _ in range(self.config["max_worlds_per_player"] + 1):
                self.create("owner")
        admin_worlds = [w["id"] for w in self.s.dispatch("admin", "list", {})["worlds"] if w["owner"] == "admin"]
        self.start(admin_worlds[0], "admin")
        self.start(admin_worlds[1], "admin")
        # The owner's own second world stays limited, but an admin may start it for them.
        owner_worlds = [w["id"] for w in self.s.dispatch("owner", "list", {})["worlds"] if w["owner"] == "owner"]
        self.start(owner_worlds[0])
        with self.assertRaisesRegex(Denied, "running-world limit"):
            self.s.dispatch("owner", "join", dict(world=owner_worlds[1]))
        self.start(owner_worlds[1], "admin")
        self.assertEqual(self.driver.starts, 4)

    def test_admins_can_start_and_join_as_spectators(self):
        world = self.create()
        # Start and spectate: the pending join and the final one both ask to spectate.
        run = self.start(world, "admin", spectate=True)
        token = self.ticket(world, "admin", spectate=True)
        self.assertEqual(self.s.redeem(run["id"], run["secret"], token, "admin")["mode"], "spectator")
        self.s.db.execute("DELETE FROM sessions")
        token = self.ticket(world, "admin")
        self.assertEqual(self.s.redeem(run["id"], run["secret"], token, "admin")["mode"], "player")
        for actor in ("owner", "stranger"):
            with self.subTest(actor=actor), self.assertRaisesRegex(Denied, "administrators"):
                self.s.dispatch(actor, "join", dict(world=world, spectate=True))

    def test_spectator_tickets_lose_the_mode_when_admin_rights_end(self):
        world = self.create()
        run = self.start(world)
        token = self.ticket(world, "admin", spectate=True)
        self.s.admins.discard("admin")
        self.assertEqual(self.s.redeem(run["id"], run["secret"], token, "admin")["mode"], "player")

    def test_admin_can_start_private_world(self):
        w = self.s.dispatch("owner", "create", {"name": "Private", "visibility": "private"})["id"]
        self.start(w, "admin")
        self.assertEqual(self.driver.starts, 1)

    def test_offline_edit_and_ownership(self):
        w = self.create()
        with self.assertRaises(Denied):
            self.s.dispatch("other", "edit", {"world": w, "name": "stolen"})
        self.s.dispatch("owner", "edit", {"world": w, "visibility": "private", "name": "changed"})
        self.start(w)
        with self.assertRaises(Denied):
            self.s.dispatch("owner", "edit", {"world": w, "name": "live"})

    def test_removed_members_ticket_invalidated(self):
        w = self.s.dispatch("owner", "create", {"name": "Private", "visibility": "private"})["id"]
        self.s.dispatch("owner", "member", {"world": w, "member": "friend"})
        run = self.start(w)
        token = self.ticket(w, "friend")
        self.s.dispatch("owner", "member", {"world": w, "member": "friend", "role": "remove"})
        with self.assertRaises(Denied):
            self.s.redeem(run["id"], run["secret"], token, "friend")

    def test_empty_stop_and_save_failure(self):
        w = self.create()
        run = self.start(w)
        token = self.ticket(w)
        self.now += 50
        self.s.tick()
        self.assertIsNone(self.s.row("SELECT * FROM runs")["empty_since"])
        self.now += 20
        self.s.tick()
        self.driver.fail_save = True
        self.now += 121
        self.s.tick()
        for _ in range(100):
            if not self.s.stop_workers:
                break
            time.sleep(.01)
        self.assertEqual(self.s.row("SELECT * FROM runs")["state"], "error")
        self.assertTrue(self.driver.alive(run))
        with self.assertRaises(Denied):
            self.s.redeem(run["id"], run["secret"], token, "owner")
        self.driver.fail_save = False
        self.s.dispatch("owner", "stop", {"world": w})
        for _ in range(100):
            if not self.s.stop_workers:
                break
            time.sleep(.01)
        self.s.tick()
        self.assertIsNone(self.s.row("SELECT * FROM runs"))

    def test_unsaved_world_stop_ends_stopped_not_in_error(self):
        # A world that is not saved (persistent=0) answers managed_stop with ok and saved=0: the
        # run must end as an ordinary stop, never in the error state that keeps its process.
        w = self.create(persistent=0)
        run = self.start(w)
        self.driver.saves = False
        self.s.dispatch("owner", "stop", {"world": w})
        for _ in range(100):
            if not self.s.stop_workers:
                break
            time.sleep(.01)
        current = self.s.row("SELECT * FROM runs")
        self.assertTrue(current is None or (current["state"], current["error"]) == ("stopping", None), dict(current or {}))
        self.s.tick()
        self.assertIsNone(self.s.row("SELECT * FROM runs"))
        self.assertFalse(self.driver.alive(run))
        self.assertIsNone(self.s.last_save(w))

    def test_stuck_stopping_run_returns_to_error_for_a_retry(self):
        # A run left in "stopping" without a stop in progress, whose world still runs and is not
        # draining (its stop failed or timed out), must not stay stuck: it goes to error, which
        # lets Stop be pressed again.
        w = self.create()
        run = self.start(w)
        with self.s.lock, self.s.db:
            self.s.db.execute("UPDATE runs SET state='stopping' WHERE id=?", (run["id"],))
        self.s.tick()
        # One tick is not enough: its status may be stale (see the fast-stop race test).
        self.assertEqual(self.s.row("SELECT state FROM runs")["state"], "stopping")
        self.s.tick()
        current = self.s.row("SELECT * FROM runs")
        self.assertEqual(current["state"], "error")
        self.assertIn("Press Stop again", current["error"])
        self.s.dispatch("owner", "stop", {"world": w})
        for _ in range(100):
            if not self.s.stop_workers:
                break
            time.sleep(.01)
        self.s.tick()
        self.assertIsNone(self.s.row("SELECT * FROM runs"))

    def test_fast_stop_finishing_during_the_status_call_is_not_stuck(self):
        # The race: tick() reads the status before managed_stop sets draining, the stop (one
        # without a save) finishes and its worker is removed, and only then does tick() take the
        # lock. The process exits a few seconds later. The run must stay stopping, never error.
        w = self.create(persistent=0)
        run = self.start(w)
        with self.s.lock, self.s.db:
            self.s.db.execute("UPDATE runs SET state='stopping' WHERE id=?", (run["id"],))
        self.s.stop_workers.add(run["id"])
        driver_status = self.driver.status

        def stale_status(r):
            answer = driver_status(r)  # read before managed_stop set draining
            with self.s.lock:
                self.s.stop_workers.discard(r["id"])  # the stop completes meanwhile
            self.driver.runs[r["id"]]["draining"] = True
            return answer
        self.driver.status = stale_status
        self.s.tick()
        self.driver.status = driver_status
        current = self.s.row("SELECT * FROM runs")
        self.assertEqual((current["state"], current["error"]), ("stopping", None))
        # The next tick sees the world draining: still not stuck.
        self.s.tick()
        self.assertEqual(self.s.row("SELECT state FROM runs")["state"], "stopping")
        # Even a second stale tick without the worker does not count: the first was not suspect.
        self.driver.runs[run["id"]]["draining"] = False
        self.s.tick()
        self.assertEqual(self.s.row("SELECT state FROM runs")["state"], "stopping")
        # The process exits: an ordinary stop.
        del self.driver.runs[run["id"]]
        self.s.tick()
        self.assertIsNone(self.s.row("SELECT * FROM runs"))
        self.assertNotIn(run["id"], self.s.stuck_suspects)

    def test_draining_stopping_run_is_left_alone(self):
        # A round's end (the world drains itself) stays stopping until the process exits.
        w = self.create()
        run = self.start(w)
        self.s.round_ended(run["id"], run["secret"])
        self.driver.runs[run["id"]]["draining"] = True
        self.s.tick()
        self.assertEqual(self.s.row("SELECT state FROM runs")["state"], "stopping")

    def test_list_shows_round_end_and_members_to_managers(self):
        w = self.create()
        self.s.dispatch("owner", "member", {"world": w, "member": "Friend", "role": "member"})
        self.assertEqual(self.s.dispatch("owner", "list", {})["worlds"][0]["members"], ["friend"])
        self.assertEqual(self.s.dispatch("admin", "list", {})["worlds"][0]["members"], ["friend"])
        self.assertNotIn("members", self.s.dispatch("friend", "list", {})["worlds"][0])
        self.assertNotIn("members", self.s.dispatch("stranger", "list", {})["worlds"][0])
        run = self.start(w)
        self.assertNotIn("stop_reason", self.s.dispatch("owner", "list", {})["worlds"][0])
        self.s.round_ended(run["id"], run["secret"])
        listed = self.s.dispatch("owner", "list", {})["worlds"][0]
        self.assertEqual((listed["state"], listed["stop_reason"]), ("stopping", "round_ended"))
        # An ordinary stop of a later run is not a round end.
        del self.driver.runs[run["id"]]
        self.s.tick()
        self.now += 10
        run = self.start(w)
        self.s.dispatch("owner", "stop", {"world": w})
        self.assertNotIn("stop_reason", self.s.dispatch("owner", "list", {})["worlds"][0])

    def test_round_end_stops_the_run_cleanly_without_a_save(self):
        w = self.create()
        run = self.start(w)
        token = self.ticket(w)
        with self.assertRaises(Denied):
            self.s.round_ended(run["id"], "wrong")
        self.assertEqual(self.s.row("SELECT state FROM runs")["state"], "running")
        self.assertEqual(self.s.round_ended(run["id"], run["secret"]), {"ok": True})
        self.assertEqual(self.s.round_ended(run["id"], run["secret"]), {"ok": True})
        # The world drains itself before it reports the round's end (station_round.dm).
        self.driver.runs[run["id"]]["draining"] = True
        current = self.s.row("SELECT * FROM runs")
        self.assertEqual((current["state"], current["error"]), ("stopping", None))
        # Nobody is admitted into a world whose round is over.
        with self.assertRaises(Denied):
            self.s.redeem(run["id"], run["secret"], token, "owner")
        with self.assertRaises(Denied):
            self.s.dispatch("owner", "join", {"world": w})
        self.assertIsNotNone(self.s.row("SELECT * FROM audit WHERE action='round_ended' AND world=?", (w,)))
        # Still answering while players read the round-end report: it stays stopping.
        self.now += 500
        self.s.tick()
        self.assertEqual(self.s.row("SELECT state FROM runs")["state"], "stopping")
        # The world exits on its own: an ordinary stop, never an error, and no save was asked for.
        del self.driver.runs[run["id"]]
        self.s.tick()
        self.assertIsNone(self.s.row("SELECT * FROM runs"))
        self.assertIsNone(self.s.row("SELECT * FROM sessions"))
        self.assertIsNone(self.s.last_save(w))
        # The world can be started again (it resumes its latest save).
        self.assertTrue(self.s.dispatch("owner", "join", {"world": w})["pending"])

    def test_summary_counts_players_across_running_worlds_without_actor(self):
        self.assertEqual(self.s.dispatch("", "summary", {}), {"ok": True, "running_worlds": 0, "admin_worlds": 0, "players": 0})
        one, two = self.start(self.create("one"), "one"), self.start(self.create("two"), "two")
        self.driver.runs[one["id"]]["players"] = ["alice", "bob"]
        self.driver.runs[two["id"]]["players"] = ["carol"]
        self.s.tick()
        summary = self.s.dispatch("", "summary", {})
        self.assertEqual((summary["running_worlds"], summary["players"]), (2, 3))
        self.assertNotIn("worlds", summary)

    def test_restart_keeps_worlds_and_reconciles_child(self):
        w = self.create()
        self.start(w)
        self.s.db.close()
        self.s = Supervisor(self.config, self.driver, lambda: self.now)
        self.s.tick()
        self.assertEqual(self.s.dispatch("owner", "list", {})["worlds"][0]["state"], "running")

    def test_global_limit_across_owners(self):
        for actor in ("one", "two"):
            self.start(self.create(actor), actor)
        w = self.create("three")
        with self.assertRaises(Denied):
            self.start(w, "three")
        self.assertEqual(self.driver.starts, 2)

    def test_redeemed_seats_count_before_next_heartbeat(self):
        w = self.create()
        run = self.start(w)
        for actor in ("one", "two"):
            token = self.ticket(w, actor)
            self.s.redeem(run["id"], run["secret"], token, actor)
        with self.assertRaises(Denied):
            self.ticket(w, "three")
        token = self.ticket(w, "admin")
        self.assertTrue(self.s.redeem(run["id"], run["secret"], token, "admin")["ok"])

    def test_redeem_is_answered_while_a_world_start_copies_its_files(self):
        # A world start prepares its files (the template, the saved levels) without the service
        # lock: logins to running worlds are answered meanwhile.
        running = self.create("one")
        run = self.start(running, "one")
        token = self.ticket(running, "one")
        copying, release = threading.Event(), threading.Event()
        def slow_prepare(world, new_run):
            copying.set()
            release.wait(10)

        other = self.create("two")
        self.driver.prepare = slow_prepare
        worker = threading.Thread(target=lambda: self.s.dispatch("two", "join", {"world": other}))
        worker.start()
        self.assertTrue(copying.wait(10))
        self.assertEqual(self.s.row("SELECT state FROM runs WHERE world=?", (other,))["state"], "starting")
        self.assertTrue(self.s.redeem(run["id"], run["secret"], token, "one", received=time.monotonic(), patience="30")["ok"])
        release.set()
        worker.join(10)
        self.assertEqual(self.s.row("SELECT pid FROM runs WHERE world=?", (other,))["pid"], 123)

    def test_a_failed_launch_removes_its_run(self):
        w = self.create()
        self.driver.prepare = lambda world, run: (_ for _ in ()).throw(OSError("disk full"))
        with self.assertRaisesRegex(Denied, "Child startup failed"):
            self.s.dispatch("owner", "join", {"world": w})
        self.assertFalse(self.s.row("SELECT * FROM runs WHERE world=?", (w,)))

    def test_late_redeem_keeps_the_ticket(self):
        # The world waits wait_seconds for its redeem; one that only got the lock after that is
        # refused without spending the ticket or adding a session (the player's retry works).
        w = self.create()
        run = self.start(w)
        token = self.ticket(w, "one")
        late = time.monotonic() - 40
        with self.assertRaisesRegex(Denied, "timed out"):
            self.s.redeem(run["id"], run["secret"], token, "one", received=late, patience="30")
        self.assertFalse(self.s.row("SELECT * FROM sessions WHERE ckey='one'"))
        # In time (or without a deadline) the same ticket is admitted.
        self.assertTrue(self.s.redeem(run["id"], run["secret"], token, "one", received=time.monotonic(), patience="30")["ok"])

    def test_settings_validation(self):
        for payload in ({"visibility": "invalid"}, {"visibility": "password"},
                        {"max_players": 999}, {"max_players": 0}, {"name": ""}):
            with self.assertRaises(Denied):
                self.s.dispatch("owner", "create", payload)
        self.assertEqual(self.s.dispatch("owner", "list", {})["worlds"], [])


class WorldTypes(unittest.TestCase):
    """Map, creative/persistent flags, limits and reset."""
    setUp, tearDown, create, start, ticket = Policies.setUp, Policies.tearDown, Policies.create, Policies.start, Policies.ticket

    def make(self, owner="owner", **data):
        return self.s.dispatch(owner, "create", dict(name="World", **data))["id"]

    def test_station_worlds_get_the_longer_startup_timeout(self):
        self.assertEqual(self.s.config["station_startup_timeout_seconds"], 600)
        babylon, station = self.make(), self.make(map="metastation")
        self.assertEqual(self.s.startup_timeout(dict(world=babylon)), 300)
        self.assertEqual(self.s.startup_timeout(dict(world=station)), 600)
        # A longer general timeout is never shortened for station maps.
        self.s.config["startup_timeout_seconds"] = 900
        self.assertEqual(self.s.startup_timeout(dict(world=station)), 900)

    def test_migration_defaults_babylon(self):
        import sqlite3
        self.s.db.close()
        path = Path(self.temp.name) / "supervisor.sqlite3"
        path.unlink()
        for suffix in ("-wal", "-shm"):
            Path(str(path) + suffix).unlink(missing_ok=True)
        old = sqlite3.connect(path)
        old.executescript("""CREATE TABLE worlds (id TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL,
            description TEXT NOT NULL, visibility TEXT NOT NULL, password TEXT, max_players INTEGER NOT NULL,
            created REAL NOT NULL, last_used REAL);
            INSERT INTO worlds VALUES('a','owner','Old','','private',NULL,2,1,1);""")
        old.commit()
        old.close()
        self.s = Supervisor(self.config, self.driver, lambda: self.now)
        row = self.s.row("SELECT * FROM worlds WHERE id='a'")
        self.assertEqual((row["map"], row["persistent"], row["creative"], row["kind"], row["tutorial"]),
                         ("babylon", 1, 0, "world", None))

    def test_create_with_map_and_flags(self):
        plain = self.s.row("SELECT * FROM worlds WHERE id=?", (self.make(),))
        self.assertEqual((plain["map"], plain["creative"], plain["persistent"], plain["kind"]), ("babylon", 0, 1, "world"))
        w = self.make(map="creative_plane_m", creative="1", persistent=0, kind="tutorial", tutorial="x")
        row = self.s.row("SELECT * FROM worlds WHERE id=?", (w,))
        self.assertEqual((row["map"], row["creative"], row["persistent"], row["kind"], row["tutorial"]),
                         ("creative_plane_m", 1, 0, "world", None))

    def test_create_unknown_map_denied(self):
        for data in ({"map": "nope"}, {"map": ""}, {"map": None}, {"map": 5}, {"map": "../babylon"}):
            with self.assertRaises(Denied):
                self.make(**data)

    def test_flag_values_are_normalised_strictly(self):
        for value in (True, False, 1, 0, "1", "0"):
            self.make(creative=value, persistent=value)
        for bad in ("true", "yes", 2, -1, None, "", 1.0, [], "01"):
            for key in ("creative", "persistent"):
                with self.assertRaises(Denied, msg=repr((key, bad))):
                    self.make(**{key: bad})
        self.assertEqual(len(self.s.dispatch("owner", "list", {})["worlds"]), 6)

    def test_non_persistent_worlds_use_total_limit(self):
        self.s.config["max_worlds_per_player"] = 4
        for _ in range(4):
            self.make()
        with self.assertRaises(Denied):
            self.make()
        for _ in range(16):
            self.make(persistent=0)
        with self.assertRaises(Denied):
            self.make(persistent=0)
        self.assertEqual(self.s.row("SELECT count(*) n FROM worlds")["n"], 20)
        # Admins are exempt from both limits.
        for _ in range(21):
            self.make("admin")

    def test_total_limit_is_configurable_and_per_player(self):
        self.s.config["max_total_worlds_per_player"] = 2
        self.make(persistent=0)
        self.make(persistent=0)
        with self.assertRaises(Denied):
            self.make(persistent=0)
        self.make("other")

    def test_turning_persistence_on_respects_the_limit(self):
        self.s.config["max_worlds_per_player"] = 1
        self.make()
        w = self.make(persistent=0)
        with self.assertRaises(Denied):
            self.s.dispatch("owner", "edit", dict(world=w, persistent=1))

    def test_flags_edit_requires_stopped(self):
        w = self.make()
        run = self.start(w)
        for data in ({"creative": 1}, {"persistent": 0}):
            with self.assertRaises(Denied):
                self.s.dispatch("owner", "edit", dict(world=w, **data))
        self.s.dispatch("owner", "stop", dict(world=w))
        self.s.tick()
        self.assertFalse(self.s.row("SELECT * FROM runs WHERE world=?", (w,)))
        self.s.dispatch("owner", "edit", dict(world=w, creative="1", persistent=False, max_players=1))
        row = self.s.row("SELECT * FROM worlds WHERE id=?", (w,))
        self.assertEqual((row["creative"], row["persistent"], row["max_players"], row["map"]), (1, 0, 1, "babylon"))
        with self.assertRaises(Denied):
            self.s.dispatch("owner", "edit", dict(world=w, creative="yes"))
        # The map is immutable and a payload cannot retarget the kind.
        self.s.dispatch("owner", "edit", dict(world=w, map="metastation", kind="tutorial", name="Renamed"))
        row = self.s.row("SELECT * FROM worlds WHERE id=?", (w,))
        self.assertEqual((row["map"], row["kind"], row["name"]), ("babylon", "world", "Renamed"))

    def test_reset_removes_saves_and_requires_confirm(self):
        w = self.make()
        root = Path(self.temp.name) / "worlds" / w
        (root / "data/babylon/saves").mkdir(parents=True)
        (root / "data/babylon/saves/note.txt").write_text("x")
        (root / "_maps/babylon/saved").mkdir(parents=True)
        (root / "_maps/babylon/saved/x.dmm").write_text("x")
        (root / "_maps/babylon/active.dmm").write_text("x")
        (root / "_maps/babylon/lore.json").write_text("{}")
        (root / "babylon-config").mkdir()
        for data in ({}, {"confirm": 0}, {"confirm": "no"}, {"confirm": False}):
            with self.assertRaises(Denied):
                self.s.dispatch("owner", "reset", dict(world=w, **data))
        with self.assertRaises(Denied):
            self.s.dispatch("stranger", "reset", dict(world=w, confirm=True))
        self.assertTrue((root / "data/babylon").exists())
        self.start(w)
        with self.assertRaises(Denied):
            self.s.dispatch("owner", "reset", dict(world=w, confirm=True))
        self.s.dispatch("owner", "stop", dict(world=w))
        self.s.tick()
        self.assertTrue(self.s.dispatch("owner", "reset", dict(world=w, confirm=True))["ok"])
        self.assertFalse((root / "data/babylon").exists())
        self.assertFalse((root / "_maps/babylon/saved").exists())
        self.assertFalse((root / "_maps/babylon/active.dmm").exists())
        self.assertTrue((root / "_maps/babylon/lore.json").exists())
        self.assertTrue((root / "babylon-config").exists())
        self.assertTrue(self.s.row("SELECT * FROM worlds WHERE id=?", (w,)))
        # An administrator may reset too, and a world with no files is fine.
        self.assertTrue(self.s.dispatch("admin", "reset", dict(world=w, confirm="1"))["ok"])

    def test_reset_world_data_refuses_links(self):
        from world_storage import reset_world_data
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep")
        root = Path(self.temp.name) / "w"
        (root / "data").mkdir(parents=True)
        (root / "data/babylon").symlink_to(outside)
        with self.assertRaises(ValueError):
            reset_world_data(root)
        self.assertTrue((outside / "keep").exists())
        reset_world_data(Path(self.temp.name) / "missing")

    def test_unknown_map_start_denied(self):
        w = self.make()
        self.s.db.execute("UPDATE worlds SET map='gone' WHERE id=?", (w,))
        with self.assertRaises(Denied):
            self.s.dispatch("owner", "join", dict(world=w))
        self.assertEqual(self.driver.starts, 0)
        self.assertFalse(self.s.row("SELECT * FROM runs WHERE world=?", (w,)))

    def test_tutorial_rows_hidden_from_list(self):
        public = self.make(visibility="public")
        hidden = {}
        for kind in ("tutorial", "tutorial_edit"):
            w = self.make("owner", visibility="public")
            self.s.db.execute("UPDATE worlds SET kind=? WHERE id=?", (kind, w))
            hidden[kind] = w
        ids = lambda actor: {x["id"] for x in self.s.dispatch(actor, "list", {})["worlds"]}
        self.assertIn(public, ids("stranger"))
        self.assertTrue(set(hidden.values()).isdisjoint(ids("stranger")))
        self.assertTrue(set(hidden.values()) <= ids("owner"))
        self.assertTrue(set(hidden.values()) <= ids("admin"))

    def test_list_reports_maps_and_world_fields(self):
        w = self.make(map="icebox", creative=1)
        result = self.s.dispatch("owner", "list", {})
        self.assertIn("icebox", [m["id"] for m in result["maps"]])
        self.assertTrue(all("map_json" not in m for m in result["maps"]))
        item = next(x for x in result["worlds"] if x["id"] == w)
        self.assertEqual((item["map"], item["creative"], item["persistent"], item["kind"]), ("icebox", 1, 1, "world"))
        self.assertIn("max_total_worlds_per_player", result["limits"])

    def test_malformed_catalog_stops_the_supervisor(self):
        from catalog import CatalogError
        bad = Path(self.temp.name) / "catalog.json"
        bad.write_text("{}")
        with self.assertRaises(CatalogError):
            Supervisor(dict(self.config, data_directory=self.temp.name + "/other", map_catalog=str(bad)),
                       self.driver, lambda: self.now)


class Launches(unittest.TestCase):
    """A world start commits its run under the lock and prepares its files without it (launch()):
    a Stop or a shutdown meanwhile cancels it, and the lobby's Join is answered at once."""
    setUp, create, start = Policies.setUp, Policies.create, Policies.start

    def tearDown(self):
        # A background launch must be done before the database closes.
        self.assertTrue(self.wait_until(lambda: not self.s.launching))
        time.sleep(.05)
        Policies.tearDown(self)

    def run_of(self, world):
        with self.s.lock:
            return self.s.row("SELECT * FROM runs WHERE world=?", (world,))

    def wait_until(self, condition):
        for _ in range(500):
            if condition():
                return True
            time.sleep(.01)
        return False

    def slow_prepare(self):
        preparing, release = threading.Event(), threading.Event()

        def prepare(world, run):
            preparing.set()
            release.wait(10)
        self.driver.prepare = prepare
        return preparing, release

    def join_in_thread(self, world, actor="owner"):
        outcome = {}

        def join():
            try:
                outcome["result"] = self.s.dispatch(actor, "join", {"world": world})
            except Denied as error:
                outcome["error"] = str(error)
        worker = threading.Thread(target=join)
        worker.start()
        return worker, outcome

    def test_stop_while_preparing_cancels_the_launch(self):
        w = self.create()
        preparing, release = self.slow_prepare()
        self.driver.stop = lambda run: self.fail("a world without a process gets no managed_stop")
        worker, outcome = self.join_in_thread(w)
        self.assertTrue(preparing.wait(10))
        self.assertEqual(self.s.dispatch("owner", "stop", {"world": w}), {"ok": True})
        run = self.run_of(w)
        self.assertEqual((run["state"], run["pid"], run["error"]), ("stopping", None, None))
        self.assertFalse(self.s.stop_workers)
        # A tick meanwhile leaves it to the launch (no error, no removal under its feet).
        self.s.tick()
        self.assertEqual(self.run_of(w)["state"], "stopping")
        release.set()
        worker.join(10)
        self.assertIn("cancelled: it was stopped", outcome["error"])
        self.assertIsNone(self.run_of(w))
        self.assertEqual(self.driver.starts, 0, "no process was started")
        self.assertFalse(self.s.launching)
        # The world starts normally again afterwards.
        self.driver.prepare = lambda world, run: None
        self.assertEqual(self.start(w)["pid"], 123)

    def test_shutdown_while_preparing_cancels_the_launch(self):
        w = self.create()
        preparing, release = self.slow_prepare()
        worker, outcome = self.join_in_thread(w)
        self.assertTrue(preparing.wait(10))
        self.s.shutting_down = True
        release.set()
        worker.join(10)
        self.assertIn("server is restarting", outcome["error"])
        self.assertIsNone(self.run_of(w))
        self.assertEqual(self.driver.starts, 0)

    def test_a_start_that_times_out_while_preparing_is_cancelled(self):
        w = self.create()
        preparing, release = self.slow_prepare()
        worker, outcome = self.join_in_thread(w)
        self.assertTrue(preparing.wait(10))
        self.now += 301
        self.s.tick()
        run = self.run_of(w)
        self.assertEqual((run["state"], run["error"]), ("error", "Startup timed out while its files were being prepared"))
        release.set()
        worker.join(10)
        self.assertIn("did not start in time", outcome["error"])
        self.assertIsNone(self.run_of(w))
        self.assertEqual(self.driver.starts, 0)

    def test_join_is_answered_before_the_files_are_ready(self):
        # m-e: the lobby's Join returns once the run is committed and polls Join meanwhile.
        self.s.background_launches = True
        w = self.create()
        preparing, release = self.slow_prepare()
        self.assertEqual(self.s.dispatch("owner", "join", {"world": w}), {"ok": True, "pending": True})
        self.assertTrue(preparing.wait(10))
        self.assertEqual(self.s.dispatch("owner", "join", {"world": w}), {"ok": True, "pending": True})
        release.set()
        self.assertTrue(self.wait_until(lambda: self.run_of(w)["pid"] == 123))
        self.s.tick()
        self.assertIn("address", self.s.dispatch("owner", "join", {"world": w}))

    def test_a_failed_background_launch_is_told_on_the_next_join(self):
        self.s.background_launches = True
        w = self.create()
        self.s.dispatch("owner", "member", {"world": w, "member": "friend"})
        prepares = []

        def failing(world, run):
            prepares.append(run["id"])
            raise OSError("disk full")
        self.driver.prepare = failing
        # N4-1: the failure is recorded before the run is removed (both under the lock), so no
        # poll can find the run gone without it and start the world again.
        real, seen = self.s.db, []

        class Watch:
            def __getattr__(self, name):
                return getattr(real, name)

            def execute(self, sql, *args):
                if sql.startswith("DELETE FROM runs WHERE id="):
                    seen.append(w in launches.s.launch_failures)
                return real.execute(sql, *args)

            def __enter__(self):
                return real.__enter__()

            def __exit__(self, *exc):
                return real.__exit__(*exc)
        launches = self
        self.s.db = Watch()
        try:
            self.assertTrue(self.s.dispatch("owner", "join", {"world": w})["pending"])
            self.assertTrue(self.wait_until(lambda: self.run_of(w) is None and not self.s.launching))
        finally:
            self.s.db = real
        self.assertEqual(seen, [True])
        # N4-4: during the back-off a member's poll is told the reason and starts nothing.
        # The reason ends with a full stop before the back-off sentence.
        with self.assertRaisesRegex(Denied, r"^Child startup failed; check the supervisor and daemon logs\. Try again in 30 seconds\.$"):
            self.s.dispatch("friend", "join", {"world": w})
        # The starter hears it once (their lobby stops polling then), then the back-off applies.
        with self.assertRaisesRegex(Denied, "^Child startup failed; check the supervisor and daemon logs$"):
            self.s.dispatch("owner", "join", {"world": w})
        with self.assertRaisesRegex(Denied, "Try again in"):
            self.s.dispatch("owner", "join", {"world": w})
        self.assertEqual(len(prepares), 1)
        self.assertIsNone(self.run_of(w))
        # After the back-off the world can be started again.
        self.now += Supervisor.LAUNCH_BACKOFF_SECONDS
        self.driver.prepare = lambda world, run: None
        self.assertTrue(self.s.dispatch("friend", "join", {"world": w})["pending"])
        self.assertTrue(self.wait_until(lambda: (self.run_of(w) or {}).get("pid") == 123))
        self.assertNotIn(w, self.s.launch_failures, "a new start supersedes the old failure")

    def test_a_cancelled_background_launch_is_told_on_the_next_join(self):
        self.s.background_launches = True
        w = self.create()
        self.s.dispatch("owner", "member", {"world": w, "member": "friend"})
        preparing, release = self.slow_prepare()
        self.assertTrue(self.s.dispatch("friend", "join", {"world": w})["pending"])
        self.assertTrue(preparing.wait(10))
        self.s.dispatch("owner", "stop", {"world": w})
        release.set()
        self.assertTrue(self.wait_until(lambda: self.run_of(w) is None and not self.s.launching))
        # The starter's poll is refused, so it does not start the world again.
        with self.assertRaisesRegex(Denied, "it was stopped"):
            self.s.dispatch("friend", "join", {"world": w})
        self.assertEqual(self.driver.starts, 0)
        # A cancel has no back-off: the Stop was meant, the next Join may start it.
        self.driver.prepare = lambda world, run: None
        self.assertTrue(self.s.dispatch("owner", "join", {"world": w})["pending"])
        self.assertTrue(self.wait_until(lambda: (self.run_of(w) or {}).get("pid") == 123))

    def test_old_launch_failures_are_forgotten(self):
        w = self.create()
        with self.s.lock:
            self.s.record_launch_failure(w, "owner", "old")
        self.now += Supervisor.LAUNCH_FAILURE_SECONDS + 1
        self.assertTrue(self.s.dispatch("owner", "join", {"world": w})["pending"])

    def test_join_and_stop_in_background_mode(self):
        # The production mode end to end: Join answers pending, polls until an address, Stop.
        self.s.background_launches = True
        w = self.create()
        self.assertTrue(self.s.dispatch("owner", "join", {"world": w})["pending"])
        self.assertTrue(self.wait_until(lambda: (self.run_of(w) or {}).get("pid") == 123))
        self.s.tick()
        self.assertIn("address", self.s.dispatch("owner", "join", {"world": w}))
        self.s.dispatch("owner", "stop", {"world": w})
        self.assertTrue(self.wait_until(lambda: not self.s.stop_workers))
        self.s.tick()
        self.assertIsNone(self.run_of(w))

    def test_maintenance_skips_worlds_being_deleted(self):
        # N4-5: recovering a rollback must not write into a half-deleted world.
        w = self.create()
        retained = []
        self.s.checkpoints.retain = lambda world, expected=None: retained.append(world)
        with self.s.lock, self.s.db:
            self.s.queue_world_deletion(w, "owner", "delete_world")
        self.s.maintain_checkpoints(w)
        self.s.run_maintenance()
        self.assertEqual(retained, [])

    def test_startup_drops_runs_that_never_started_a_process(self):
        # m-a: a supervisor that stopped while it prepared a world leaves a pid-less run behind.
        crashed, running = self.create(), self.create("two")
        self.start(running, "two")
        self.s.db.execute("INSERT INTO runs(id,world,port,secret,state,started) VALUES('lost',?,1402,'s','starting',?)",
                          (crashed, self.now))
        self.s.db.execute("INSERT INTO tickets(hash,ckey,world,run,expires) VALUES('h','owner',?,'lost',?)", (crashed, self.now + 60))
        self.s.db.commit()
        restarted = Supervisor(self.config, self.driver, lambda: self.now)
        self.addCleanup(restarted.db.close)
        self.assertIsNone(restarted.row("SELECT * FROM runs WHERE world=?", (crashed,)))
        self.assertIsNone(restarted.row("SELECT * FROM tickets WHERE run='lost'"))
        self.assertEqual(restarted.row("SELECT pid FROM runs WHERE world=?", (running,))["pid"], 123)

    def test_tick_drops_a_pid_less_run_no_launch_owns(self):
        w = self.create()
        self.s.db.execute("INSERT INTO runs(id,world,port,secret,state,started) VALUES('lost',?,1402,'s','stopping',?)",
                          (w, self.now))
        self.s.db.commit()
        self.s.tick()
        self.assertIsNone(self.run_of(w))

    def test_reset_waits_for_checkpoint_maintenance(self):
        # m-d: retain() and a reset never work on the same saves at once.
        w = self.create()
        saves = Path(self.temp.name) / "worlds" / w / "data/babylon/saves"
        saves.mkdir(parents=True)
        done = threading.Event()
        with self.s.checkpoint_lock:
            worker = threading.Thread(target=lambda: (self.s.dispatch("owner", "reset", {"world": w, "confirm": True}),
                                                      done.set()))
            worker.start()
            self.assertFalse(done.wait(.2))
            self.assertTrue(saves.exists())
        worker.join(10)
        self.assertTrue(done.is_set())
        self.assertFalse(saves.exists())

    def test_a_failed_stop_commit_leaves_no_stop_worker(self):
        w = self.create()
        run = self.start(w)
        real = self.s.db

        class FailingCommit:
            def __getattr__(self, name):
                return getattr(real, name)

            def commit(self):
                raise RuntimeError("disk full")
        self.s.db = FailingCommit()
        try:
            with self.s.lock, self.assertRaises(RuntimeError):
                self.s.begin_stop(run)
        finally:
            real.rollback()
            self.s.db = real
        self.assertFalse(self.s.stop_workers)
        self.s.dispatch("owner", "stop", {"world": w})
        self.assertTrue(self.wait_until(lambda: not self.s.stop_workers))
        self.s.tick()
        self.assertIsNone(self.run_of(w))

if __name__ == "__main__":
    unittest.main()
