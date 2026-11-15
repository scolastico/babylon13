"""The tutorial pipeline on the supervisor side: submit and save back (child actions), review, play
and copy (lobby actions), and the end of tutorial instances."""
import json
import os
import re
from pathlib import Path
import threading
import time
import unittest
import unittest.mock

import test_driver
from supervisor import CHILD_ACTIONS, Denied, Supervisor
import test_supervisor

GENERATION = "save-20261114-120000-3"


class TutorialFixture(unittest.TestCase):
    def setUp(self):
        test_supervisor.Policies.setUp(self)
        self.notified = []
        self.s.tutorial_notify = self.notified.append
        self.data = Path(self.temp.name)

    def tearDown(self):
        test_supervisor.Policies.tearDown(self)

    start = test_supervisor.Policies.start

    def make(self, owner="owner", **data):
        data = dict(dict(name="Builder", map="creative_plane_m", creative=1, persistent=0), **data)
        return self.s.dispatch(owner, "create", data)["id"]

    def save(self, world, generation=GENERATION, records=3, characters=None):
        """A checkpoint generation as the DM save writes it (characters: state "characters" and
        "players", as an ordinary world's save has them)."""
        directory = self.data / "worlds" / world / "data/babylon/saves" / generation
        directory.mkdir(parents=True)
        (directory / "map.dmm").write_text("map of " + world)
        (directory / "z2.dmm").write_text("level 2")
        state = {"generation": generation, "records": [{}] * records}
        if characters:
            state["characters"] = {ckey: {"id": "bb90", "records": [{"id": "bb91", "parent": "bb90"}]} for ckey in characters}
            state["players"] = {ckey: {"play_time": 600} for ckey in characters}
        (directory / "state.json").write_text(json.dumps(state))
        return directory

    def creative_run(self, owner="owner"):
        world = self.make(owner)
        run = self.start(world, owner)
        self.save(world)
        return world, run

    def child(self, action, run, **data):
        return CHILD_ACTIONS[action](self.s, dict(data, action=action, run=run["id"], secret=run["secret"]))

    def submit(self, run, actor="owner", title="Fix the power", description="Wire the SMES.", generation=GENERATION):
        return self.child("tutorial_submit", run, actor=actor, title=title, description=description,
                          generation=generation)["tutorial"]

    def tutorial(self, tid):
        return self.s.row("SELECT * FROM tutorials WHERE id=?", (tid,))

    def published(self, actor="owner"):
        """A tutorial submitted by ``actor`` and accepted by the admin."""
        world, run = self.creative_run(actor)
        tid = self.submit(run, actor)
        self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        self.stop(world)
        return tid

    def stop(self, world):
        self.s.dispatch("admin", "stop", {"world": world})
        for _ in range(100):
            if not self.s.stop_workers:
                break
            time.sleep(.01)
        self.s.tick()
        self.assertFalse(self.s.row("SELECT * FROM runs WHERE world=?", (world,)))


class Submit(TutorialFixture):
    def test_submit_stores_pending_copy_and_meta(self):
        world, run = self.creative_run()
        tid = self.submit(run)
        row = self.tutorial(tid)
        self.assertEqual((row["title"], row["description"], row["author"], row["status"], row["map"], row["build"]),
                         ("Fix the power", "Wire the SMES.", "owner", "pending", "creative_plane_m", "station"))
        folder = self.data / "tutorials/pending" / tid
        self.assertEqual((folder / "save/map.dmm").read_text(), "map of " + world)
        self.assertTrue((folder / "save/z2.dmm").is_file())
        meta = json.loads((folder / "meta.json").read_text())
        self.assertEqual((meta["title"], meta["author"], meta["map"], meta["build"], meta["source_world"], meta["generation"]),
                         ("Fix the power", "owner", "creative_plane_m", "station", world, GENERATION))
        self.assertEqual(meta["created"], self.now)
        # The world's own checkpoint is untouched.
        self.assertTrue((self.data / "worlds" / world / "data/babylon/saves" / GENERATION / "map.dmm").is_file())

    def test_tutorial_snapshots_are_removed_once_copied(self):
        # The world marks a submission's snapshot; the supervisor deletes it once copied or refused,
        # and the copy leaves the mark out (review S1).
        world, run = self.creative_run()
        snapshot = self.data / "worlds" / world / "data/babylon/saves" / GENERATION
        (snapshot / "tutorial-snapshot").write_text("1")
        tid = self.submit(run)
        self.assertFalse(snapshot.exists())
        saved = self.data / "tutorials/pending" / tid / "save"
        self.assertTrue((saved / "map.dmm").is_file())
        self.assertFalse((saved / "tutorial-snapshot").exists())
        # A refused copy removes it too; an unmarked generation (a real checkpoint) is never removed.
        world2, run2 = self.creative_run("second")
        marked = self.data / "worlds" / world2 / "data/babylon/saves" / GENERATION
        (marked / "tutorial-snapshot").write_text("1")
        with unittest.mock.patch.object(self.s.tutorials, "create_pending", side_effect=OSError("disk full")):
            with self.assertRaises(Denied):
                self.submit(run2, "second")
        self.assertFalse(marked.exists())
        edit = self.s.dispatch("admin", "tutorial_edit", {"tutorial": tid})["world"]
        self.s.tick()
        edit_run = self.s.row("SELECT * FROM runs WHERE world=?", (edit,))
        back = self.save(edit, "save-20261114-150000-7")
        (back / "tutorial-snapshot").write_text("1")
        self.child("tutorial_save_back", edit_run, actor="admin", generation="save-20261114-150000-7")
        self.assertFalse(back.exists())
        self.assertFalse((saved / "tutorial-snapshot").exists())

    def test_redeem_is_answered_while_a_submission_is_copied(self):
        # The snapshot copy runs outside the service lock: logins to other worlds are not held up
        # by a long multi-level copy (they would time out after 30 s), and a second submission by
        # the same author waits for the first.
        world, run = self.creative_run()
        other = self.make("player")
        other_run = self.start(other, "player")
        token = test_supervisor.Policies.ticket(self, other, "player")
        copying, release = threading.Event(), threading.Event()
        real_copy = self.s.tutorials.create_pending

        def slow_copy(*args):
            copying.set()
            release.wait(10)
            return real_copy(*args)

        result = {}
        with unittest.mock.patch.object(self.s.tutorials, "create_pending", side_effect=slow_copy):
            worker = threading.Thread(target=lambda: result.update(tid=self.submit(run)))
            worker.start()
            self.assertTrue(copying.wait(10))
            answered = self.s.redeem(other_run["id"], other_run["secret"], token, "player",
                                     received=time.monotonic(), patience="30")
            self.assertTrue(answered["ok"])
            with self.assertRaisesRegex(Denied, "being stored right now"):
                self.submit(run)
            release.set()
            worker.join(10)
        self.assertEqual(self.tutorial(result["tid"])["status"], "pending")
        # The reservation is gone; the cooldown now applies.
        self.assertFalse(self.s.submitting)
        with self.assertRaisesRegex(Denied, "another tutorial in"):
            self.submit(run)

    def test_no_start_reads_a_snapshot_during_its_save_back(self):
        # Save back swaps the pending snapshot outside the lock: play and edit starts are refused
        # meanwhile (also in the driver), and a save back waits while a start stages the snapshot.
        world, run = self.creative_run()
        tid = self.submit(run)
        self.s.saving_back.add(tid)
        for action in ("tutorial_play", "tutorial_edit"):
            with self.assertRaisesRegex(Denied, "saving this tutorial back"):
                self.s.dispatch("admin", action, {"tutorial": tid})
        self.assertFalse(self.s.row("SELECT * FROM worlds WHERE tutorial=?", (tid,)))
        with self.assertRaisesRegex(Denied, "saving this tutorial back"):
            test_driver_driver(self).restore_source(dict(kind="tutorial", tutorial=tid, id="x"))
        self.s.saving_back.discard(tid)
        edit = self.s.dispatch("admin", "tutorial_edit", {"tutorial": tid})["world"]
        self.s.tick()
        edit_run = self.s.row("SELECT * FROM runs WHERE world=?", (edit,))
        self.save(edit, "save-20261114-150000-7")
        self.s.tutorial_readers[tid] = 1
        with self.assertRaisesRegex(Denied, "being started"):
            self.child("tutorial_save_back", edit_run, actor="admin", generation="save-20261114-150000-7")
        with self.assertRaisesRegex(Denied, "being started or copied"):
            self.s.dispatch("admin", "tutorial_reject", {"tutorial": tid, "confirm": 1})
        # m-b: accepting would rename the pending directory away while a start copies it.
        with self.assertRaisesRegex(Denied, "being started or copied"):
            self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        self.assertEqual(self.tutorial(tid)["status"], "pending")
        self.s.tutorial_readers.clear()
        self.assertEqual(self.child("tutorial_save_back", edit_run, actor="admin", generation="save-20261114-150000-7")["ok"], True)

    def test_startup_repairs_the_tutorial_store(self):
        # An interrupted supervisor leaves staging copies and a half-swapped save back; the next
        # start cleans them up. A tutorial without a row is never deleted (the database may have
        # been lost or restored): it is moved, whole, to orphaned/ and logged.
        world, run = self.creative_run()
        tid = self.submit(run)
        pending = self.data / "tutorials/pending"
        (pending / ".abc.staging/save").mkdir(parents=True)
        orphan = pending / ("f" * 32)
        (orphan / "save").mkdir(parents=True)
        (orphan / "save/map.dmm").write_text("player work")
        (pending / tid / "save").rename(pending / tid / "save.old")
        (pending / tid / "save.staging").mkdir()
        with unittest.mock.patch("supervisor.log") as log:
            restarted = Supervisor(self.s.config, test_supervisor.FakeDriver(), lambda: self.now)
        self.addCleanup(restarted.db.close)
        self.assertFalse((pending / ".abc.staging").exists())
        self.assertFalse(orphan.exists())
        quarantined = list((self.data / "tutorials/orphaned").iterdir())
        self.assertEqual(len(quarantined), 1)
        self.assertTrue(quarantined[0].name.startswith("f" * 32 + "-pending-"))
        self.assertEqual((quarantined[0] / "save/map.dmm").read_text(), "player work")
        self.assertTrue(any("no database row" in str(call) and str(quarantined[0]) in str(call)
                            for call in log.call_args_list))
        self.assertFalse((self.data / "tutorials/deleted").exists() and any((self.data / "tutorials/deleted").iterdir()))
        self.assertTrue((pending / tid / "save/map.dmm").is_file())
        self.assertFalse((pending / tid / "save.old").exists() or (pending / tid / "save.staging").exists())

    def test_startup_with_a_lost_database_keeps_every_tutorial(self):
        # The database is gone (a fresh volume, a bad mount): every tutorial on disk lacks its row.
        # All of them are quarantined, none deleted; a published one included.
        tid = self.published()
        world, run = self.creative_run("other")
        pending_tid = self.submit(run, "other")
        self.s.db.close()
        (self.data / "supervisor.sqlite3").unlink()
        for suffix in ("-wal", "-shm"):
            (self.data / ("supervisor.sqlite3" + suffix)).unlink(missing_ok=True)
        restarted = Supervisor(self.s.config, test_supervisor.FakeDriver(), lambda: self.now)
        self.s = restarted
        names = sorted(p.name for p in (self.data / "tutorials/orphaned").iterdir())
        self.assertEqual([n.split("-")[0] for n in names], sorted([tid, pending_tid]))
        for name in names:
            self.assertTrue((self.data / "tutorials/orphaned" / name / "save/map.dmm").is_file())

    def test_submit_check_and_actor_must_own_the_world(self):
        world, run = self.creative_run()
        self.assertEqual(self.child("tutorial_submit_check", run, actor="owner"), {"ok": True, "wait_seconds": 0, "cooldown_hours": 6})
        for actor in ("someone", "", "admin"):
            with self.assertRaisesRegex(Denied, "owner"):
                self.child("tutorial_submit_check", run, actor=actor)
            with self.assertRaisesRegex(Denied, "owner"):
                self.submit(run, actor=actor)

    def test_only_creative_station_worlds_can_submit(self):
        for data in (dict(map="babylon", creative=1), dict(map="creative_plane_m", creative=0),
                     dict(map="metastation", creative=0)):
            world = self.make("p" + str(len(data)) + data["map"], **data)
            run = self.start(world, self.s.row("SELECT owner FROM worlds WHERE id=?", (world,))["owner"])
            owner = self.s.row("SELECT owner FROM worlds WHERE id=?", (world,))["owner"]
            self.save(world)
            with self.assertRaisesRegex(Denied, "Creative world on a station map"):
                self.child("tutorial_submit_check", run, actor=owner)
            with self.assertRaisesRegex(Denied, "Creative world on a station map"):
                self.submit(run, actor=owner)
            self.stop(world)
        # A station map with Creative on works.
        world = self.make("station", map="metastation", creative=1)
        run = self.start(world, "station")
        self.save(world)
        self.assertTrue(self.submit(run, actor="station"))

    def test_submit_validates_text_and_generation(self):
        world, run = self.creative_run()
        for data in (dict(title=""), dict(title="  "), dict(title="x" * 61), dict(description="x" * 501),
                     dict(generation="save-1"), dict(generation="../" + GENERATION), dict(generation=None),
                     dict(generation="save-20261114-120000-9")):
            with self.assertRaises(Denied, msg=repr(data)):
                self.submit(run, **data)
        self.assertIsNone(self.s.row("SELECT * FROM tutorials"))
        tid = self.submit(run, title="‮Title\u0007", description="Line one\r\nLine two")
        self.assertEqual((self.tutorial(tid)["title"], self.tutorial(tid)["description"]), ("Title", "Line one\nLine two"))

    def test_submit_refuses_links(self):
        world, run = self.creative_run()
        outside = self.data / "outside"
        outside.mkdir()
        (outside / "secret.txt").write_text("secret")
        saves = self.data / "worlds" / world / "data/babylon/saves"
        (saves / GENERATION / "inner").symlink_to(outside)
        with self.assertRaisesRegex(Denied, "link"):
            self.submit(run)
        linked = "save-20261114-130000-4"
        (saves / linked).symlink_to(saves / GENERATION)
        with self.assertRaises(Denied):
            self.submit(run, generation=linked)
        self.assertEqual(list((self.data / "tutorials/pending").iterdir()), [])

    def test_submit_cooldown(self):
        world, run = self.creative_run()
        self.submit(run)
        self.assertEqual(self.child("tutorial_submit_check", run, actor="owner")["wait_seconds"], 6 * 3600)
        self.now += 3600
        with self.assertRaisesRegex(Denied, "in 5 hours"):
            self.submit(run)
        self.assertEqual(self.child("tutorial_submit_check", run, actor="owner")["wait_seconds"], 5 * 3600)
        self.now += 5 * 3600
        self.assertEqual(self.child("tutorial_submit_check", run, actor="owner")["wait_seconds"], 0)
        self.submit(run)
        # The cooldown is per author and configurable; 0 turns it off.
        other_world, other_run = self.creative_run("other")
        self.stop(world)
        self.submit(other_run, actor="other")
        self.s.config["tutorial_submit_cooldown_hours"] = 0
        self.submit(other_run, actor="other")
        self.assertEqual(self.s.row("SELECT count(*) n FROM tutorials")["n"], 4)

    def test_submit_failed_save_keeps_cooldown(self):
        """A failed copy stores nothing and starts no cooldown: the player can retry at once."""
        world, run = self.creative_run()
        with self.assertRaisesRegex(Denied, "does not exist"):
            self.submit(run, generation="save-20261114-120000-9")
        broken = self.save(world, "save-20261114-130000-4")
        (broken / "state.json").write_text("not json")
        with self.assertRaisesRegex(Denied, "could not be stored"):
            self.submit(run, generation="save-20261114-130000-4")
        self.assertIsNone(self.s.row("SELECT * FROM tutorials"))
        self.assertIsNone(self.s.row("SELECT * FROM tutorial_cooldowns"))
        self.assertEqual(self.child("tutorial_submit_check", run, actor="owner")["wait_seconds"], 0)
        self.assertEqual(sorted(p.name for p in (self.data / "tutorials/pending").iterdir()), [])
        self.assertEqual(self.notified, [])
        self.submit(run)
        self.assertEqual(len(self.notified), 1)

    def test_discord_notified(self):
        world, run = self.creative_run()
        tid = self.submit(run)
        (note,) = self.notified
        self.assertEqual((note["id"], note["title"], note["author"], note["map"], note["map_name"], note["description"]),
                         (tid, "Fix the power", "owner", "creative_plane_m", "Creative Plane M", "Wire the SMES."))
        # Without the bot (or with a failing one) submitting still works; it is only logged.
        self.s.tutorial_notify = None
        self.s.config["tutorial_submit_cooldown_hours"] = 0
        self.submit(run)

        def broken(_):
            raise RuntimeError("Discord is down")
        self.s.tutorial_notify = broken
        self.submit(run)
        self.assertEqual(self.s.row("SELECT count(*) n FROM tutorials")["n"], 3)

    def test_child_tutorial_actions_need_the_run_credentials(self):
        world, run = self.creative_run()
        for action in ("tutorial_submit_check", "tutorial_submit", "tutorial_save_back"):
            with self.assertRaisesRegex(Denied, "credentials"):
                CHILD_ACTIONS[action](self.s, dict(action=action, run=run["id"], secret="wrong", actor="owner",
                                                   title="T", generation=GENERATION))


class NoCharacters(TutorialFixture):
    """A tutorial snapshot never carries players' characters or per-player records (arch M1): every
    copy into or out of the tutorial store blanks them, whatever the DM wrote."""

    def state(self, save):
        return json.loads((save / "state.json").read_text())

    def assert_no_characters(self, save):
        state = self.state(save)
        self.assertEqual((state["characters"], state["players"]), ({}, {}))
        # Everything else is kept.
        self.assertEqual((state["generation"], len(state["records"])), (GENERATION, 3))

    def test_kinds_rule(self):
        # The DM side is checked against world_policy() by test_contracts.WorldPolicy.
        from constants import SAVES_CHARACTERS
        self.assertEqual(SAVES_CHARACTERS, {"world": True, "tutorial": False, "tutorial_edit": False})

    def test_submit_save_back_and_copy_strip_characters(self):
        world = self.make()
        run = self.start(world, "owner")
        self.save(world, characters=["owner", "friend"])
        tid = self.submit(run)
        pending = self.data / "tutorials/pending" / tid / "save"
        self.assert_no_characters(pending)
        # The world's own save keeps them.
        own = self.state(self.data / "worlds" / world / "data/babylon/saves" / GENERATION)
        self.assertEqual(set(own["characters"]), {"owner", "friend"})
        edit = self.s.dispatch("admin", "tutorial_edit", {"tutorial": tid})["world"]
        self.s.tick()
        edit_run = self.s.row("SELECT * FROM runs WHERE world=?", (edit,))
        self.save(edit, GENERATION, characters=["admin"])
        self.child("tutorial_save_back", edit_run, actor="admin", generation=GENERATION)
        self.assert_no_characters(pending)
        self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        # Even a published snapshot that somehow holds characters is copied without them.
        published = self.data / "tutorials/published" / tid / "save"
        state = self.state(published)
        state["characters"] = {"admin": {"id": "bb90", "records": []}}
        state["players"] = {"admin": {"play_time": 1}}
        (published / "state.json").write_text(json.dumps(state))
        copied = self.s.dispatch("player", "tutorial_copy", {"tutorial": tid})
        self.assert_no_characters(self.data / "worlds" / copied["id"] / "data/babylon/saves" / GENERATION)


class Review(TutorialFixture):
    def pending(self):
        world, run = self.creative_run()
        return world, run, self.submit(run)

    def test_accept_moves_to_published(self):
        world, run, tid = self.pending()
        self.assertEqual(self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid}), {"ok": True, "title": "Fix the power"})
        row = self.tutorial(tid)
        self.assertEqual((row["status"], row["reviewed_by"]), ("published", "admin"))
        self.assertFalse((self.data / "tutorials/pending" / tid).exists())
        self.assertEqual((self.data / "tutorials/published" / tid / "save/map.dmm").read_text(), "map of " + world)
        with self.assertRaisesRegex(Denied, "already published"):
            self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        with self.assertRaisesRegex(Denied, "Only pending"):
            self.s.dispatch("admin", "tutorial_reject", {"tutorial": tid, "confirm": 1})

    def test_reject_deletes(self):
        world, run, tid = self.pending()
        with self.assertRaisesRegex(Denied, "Confirm"):
            self.s.dispatch("admin", "tutorial_reject", {"tutorial": tid})
        self.assertTrue(self.s.dispatch("admin", "tutorial_reject", {"tutorial": tid, "confirm": 1})["ok"])
        self.assertIsNone(self.tutorial(tid))
        self.assertFalse((self.data / "tutorials/pending" / tid).exists())
        self.assertEqual(list((self.data / "tutorials/deleted").iterdir()), [])
        with self.assertRaisesRegex(Denied, "no longer available"):
            self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})

    def test_delete_published(self):
        tid = self.published()
        with self.assertRaisesRegex(Denied, "Confirm"):
            self.s.dispatch("admin", "tutorial_delete", {"tutorial": tid})
        self.s.dispatch("admin", "tutorial_delete", {"tutorial": tid, "confirm": "1"})
        self.assertIsNone(self.tutorial(tid))
        self.assertFalse((self.data / "tutorials/published" / tid).exists())

    def test_non_admin_cannot_review(self):
        world, run, tid = self.pending()
        for actor in ("owner", "stranger"):
            for action in ("tutorial_accept", "tutorial_reject", "tutorial_delete", "tutorial_edit", "tutorial_play",
                           "tutorial_copy"):
                with self.assertRaises(Denied, msg=(actor, action)):
                    self.s.dispatch(actor, action, {"tutorial": tid, "confirm": 1})
            # Pending tutorials are invisible to players, the author included.
            self.assertEqual(self.s.dispatch(actor, "tutorials", {})["tutorials"], [])
            self.assertNotIn("pending_tutorials", self.s.dispatch(actor, "list", {}))
        self.assertEqual(self.tutorial(tid)["status"], "pending")
        self.assertEqual(self.s.dispatch("admin", "list", {})["pending_tutorials"], 1)
        self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        for action in ("tutorial_delete", "tutorial_accept"):
            with self.assertRaisesRegex(Denied, "administrators"):
                self.s.dispatch("owner", action, {"tutorial": tid, "confirm": 1})
        self.assertEqual(self.s.dispatch("admin", "list", {})["pending_tutorials"], 0)

    def test_list_fields_and_visibility(self):
        published = self.published()
        self.now += 10
        self.s.config["tutorial_submit_cooldown_hours"] = 0
        world, run = self.creative_run("second")
        pending = self.submit(run, actor="second", title="Second")
        items = self.s.dispatch("admin", "tutorials", {})["tutorials"]
        self.assertEqual([i["id"] for i in items], [pending, published])
        item = items[1]
        self.assertEqual({k: item[k] for k in ("title", "description", "author", "map", "map_name", "status")},
                         dict(title="Fix the power", description="Wire the SMES.", author="owner", map="creative_plane_m",
                              map_name="Creative Plane M", status="published"))
        self.assertIsInstance(item["created"], (int, float))
        self.assertEqual((item["playing"], item["editing"]), (None, None))
        player = self.s.dispatch("player", "tutorials", {})["tutorials"]
        self.assertEqual([i["id"] for i in player], [published])
        self.assertNotIn("editing", player[0])
        for bad in (None, 5, "../x", "nope"):
            with self.assertRaisesRegex(Denied, "no longer available"):
                self.s.dispatch("player", "tutorial_play", {"tutorial": bad})


class Instances(TutorialFixture):
    def instance(self, world):
        return self.s.row("SELECT * FROM worlds WHERE id=?", (world,))

    def test_play_creates_a_private_throwaway_instance(self):
        tid = self.published()
        result = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})
        self.assertEqual((result["ok"], result["pending"], result["name"]), (True, True, "Fix the power"))
        world = self.instance(result["world"])
        self.assertEqual({k: world[k] for k in ("owner", "kind", "tutorial", "visibility", "persistent", "creative", "map",
                                                "max_players")},
                         dict(owner="player", kind="tutorial", tutorial=tid, visibility="private", persistent=0, creative=0,
                              map="creative_plane_m", max_players=1))
        self.assertTrue(self.s.row("SELECT * FROM runs WHERE world=?", (world["id"],)))
        self.s.tick()
        listed = self.s.dispatch("player", "tutorials", {})["tutorials"][0]
        self.assertEqual(listed["playing"], "running")
        # The join flow admits the player to it.
        self.assertIn("babylon_ticket=", self.s.dispatch("player", "join", {"world": world["id"]})["address"])
        # Tutorial instances do not count against the world limits.
        self.s.config["max_total_worlds_per_player"] = 1
        self.make("player")

    def test_tutorial_play_reuses_instance(self):
        first = self.published()
        self.s.config["tutorial_submit_cooldown_hours"] = 0
        second = self.published("author2")
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": first})["world"]
        self.s.tick()
        again = self.s.dispatch("player", "tutorial_play", {"tutorial": first})
        self.assertEqual((again["world"], again["reused"], again["pending"]), (world, True, False))
        self.assertEqual(self.s.row("SELECT count(*) n FROM worlds WHERE kind='tutorial'")["n"], 1)
        self.assertEqual(self.driver.starts, 3)  # the two authors' worlds and one instance
        with self.assertRaisesRegex(Denied, "Finish or leave your current tutorial first"):
            self.s.dispatch("player", "tutorial_play", {"tutorial": second})
        # Someone else plays their own instance.
        other = self.s.dispatch("friend", "tutorial_play", {"tutorial": first})["world"]
        self.assertNotEqual(other, world)

    def test_play_counts_toward_running_limits(self):
        tid = self.published()
        self.s.dispatch("player", "create", dict(name="Mine", visibility="private"))
        mine = self.s.row("SELECT id FROM worlds WHERE owner='player' AND kind='world'")["id"]
        self.start(mine, "player")
        with self.assertRaisesRegex(Denied, "running-world limit"):
            self.s.dispatch("player", "tutorial_play", {"tutorial": tid})
        # The instance that could not start is gone again.
        self.assertIsNone(self.s.row("SELECT * FROM worlds WHERE kind='tutorial'"))
        self.assertIsNone(self.s.row("SELECT * FROM world_deletions"))

    def test_tutorial_instance_deleted_on_stop(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        self.s.tick()
        root = self.data / "worlds" / world
        root.mkdir(parents=True)
        (root / "daemon.log").write_text("x")
        # Its process ends (the player left, the round ended or it crashed).
        run = self.s.row("SELECT * FROM runs WHERE world=?", (world,))
        del self.driver.runs[run["id"]]
        self.s.tick()
        self.assertIsNone(self.instance(world))
        self.assertIsNone(self.s.row("SELECT * FROM runs WHERE world=?", (world,)))
        self.assertFalse(root.exists())
        self.assertIsNone(self.s.row("SELECT * FROM world_deletions"))
        # Ordinary worlds are kept when they stop.
        self.assertTrue(self.s.row("SELECT * FROM worlds WHERE kind='world'"))
        # A new run of the tutorial starts a fresh instance.
        self.assertNotEqual(self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"], world)

    def test_edit_world_deleted_on_stop(self):
        # The admin's edit world is unsaved like a play instance: stopping it deletes its row and
        # files; the pending tutorial (and what was saved back to it) stays.
        world, run = self.creative_run()
        tid = self.submit(run)
        edit = self.s.dispatch("admin", "tutorial_edit", {"tutorial": tid})["world"]
        self.s.tick()
        root = self.data / "worlds" / edit
        root.mkdir(parents=True, exist_ok=True)
        (root / "daemon.log").write_text("x")
        self.stop(edit)
        self.assertIsNone(self.instance(edit))
        self.assertFalse(root.exists())
        self.assertIsNone(self.s.row("SELECT * FROM world_deletions"))
        self.assertEqual(self.tutorial(tid)["status"], "pending")
        self.assertTrue((self.data / "tutorials/pending" / tid / "save/map.dmm").is_file())
        # The next Edit starts a fresh world from the pending copy.
        self.assertNotEqual(self.s.dispatch("admin", "tutorial_edit", {"tutorial": tid})["world"], edit)

    def test_copy_counts_against_the_total_world_limit(self):
        tid = self.published()
        self.s.config["max_total_worlds_per_player"] = 1
        self.make("player", persistent=0)
        with self.assertRaisesRegex(Denied, "total world limit"):
            self.s.dispatch("player", "tutorial_copy", {"tutorial": tid})
        self.assertEqual(self.s.row("SELECT count(*) n FROM worlds WHERE owner='player'")["n"], 1)
        self.assertFalse(self.s.copying)
        self.assertFalse(self.s.tutorial_readers)
        # Play instances never count: a player at the limit can still play.
        self.assertTrue(self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["ok"])

    def test_instances_without_a_run_are_removed_at_startup(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        self.s.db.execute("DELETE FROM runs WHERE world=?", (world,))
        self.s.db.commit()
        self.s.db.close()
        self.s = Supervisor(self.config, self.driver, lambda: self.now)
        self.s.background_launches = False
        self.assertIsNone(self.instance(world))
        self.s.tick()
        self.assertIsNone(self.s.row("SELECT * FROM world_deletions"))

    def test_deleting_a_tutorial_keeps_running_instances(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        self.s.tick()
        self.s.dispatch("admin", "tutorial_delete", {"tutorial": tid, "confirm": 1})
        self.s.tick()
        self.assertEqual(self.s.row("SELECT state FROM runs WHERE world=?", (world,))["state"], "running")
        self.assertIn("babylon_ticket=", self.s.dispatch("player", "join", {"world": world})["address"])

    def test_edit_is_one_admin_world_per_tutorial(self):
        world, run = self.creative_run()
        tid = self.submit(run)
        with self.assertRaises(Denied):
            self.s.dispatch("owner", "tutorial_edit", {"tutorial": tid})
        self.s.config["admins"] = ["admin", "admin2"]
        self.s.admins.add("admin2")
        edit = self.s.dispatch("admin", "tutorial_edit", {"tutorial": tid})
        row = self.instance(edit["world"])
        self.assertEqual({k: row[k] for k in ("owner", "kind", "tutorial", "creative", "persistent", "visibility", "name")},
                         dict(owner="admin", kind="tutorial_edit", tutorial=tid, creative=1, persistent=0,
                              visibility="private", name="Editing: Fix the power"))
        self.s.tick()
        self.assertEqual(self.s.dispatch("admin2", "tutorial_edit", {"tutorial": tid})["world"], edit["world"])
        self.assertEqual(self.s.dispatch("admin", "tutorials", {})["tutorials"][0]["editing"], "running")
        # An admin may play a pending tutorial too; published ones can't be edited.
        self.assertTrue(self.s.dispatch("admin2", "tutorial_play", {"tutorial": tid})["ok"])
        self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        with self.assertRaisesRegex(Denied, "Only pending"):
            self.s.dispatch("admin", "tutorial_edit", {"tutorial": tid})

    def test_save_back_admin_only(self):
        world, run = self.creative_run()
        tid = self.submit(run)
        edit = self.s.dispatch("admin", "tutorial_edit", {"tutorial": tid})["world"]
        self.s.tick()
        edit_run = self.s.row("SELECT * FROM runs WHERE world=?", (edit,))
        changed = self.save(edit, "save-20261114-150000-7")
        (changed / "map.dmm").write_text("edited map")
        for actor in ("owner", "player", ""):
            with self.assertRaisesRegex(Denied, "administrators"):
                self.child("tutorial_save_back", edit_run, actor=actor, generation="save-20261114-150000-7")
        # Only from the edit world: not from the author's own world.
        with self.assertRaisesRegex(Denied, "edits a pending tutorial"):
            self.child("tutorial_save_back", run, actor="admin", generation=GENERATION)
        with self.assertRaises(Denied):
            self.child("tutorial_save_back", edit_run, actor="admin", generation="save-20261114-150000-8")
        folder = self.data / "tutorials/pending" / tid
        self.assertEqual((folder / "save/map.dmm").read_text(), "map of " + world)
        self.now += 50
        self.assertEqual(self.child("tutorial_save_back", edit_run, actor="admin", generation="save-20261114-150000-7"),
                         {"ok": True, "tutorial": tid})
        self.assertEqual((folder / "save/map.dmm").read_text(), "edited map")
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["meta.json", "save"])
        self.assertEqual(self.tutorial(tid)["updated"], self.now)
        self.assertEqual(json.loads((folder / "meta.json").read_text())["generation"], "save-20261114-150000-7")
        # Once accepted, the edit world can no longer change it.
        self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        with self.assertRaisesRegex(Denied, "no longer pending"):
            self.child("tutorial_save_back", edit_run, actor="admin", generation="save-20261114-150000-7")

    def test_copy_seeds_first_save(self):
        tid = self.published()
        copied = self.s.dispatch("player", "tutorial_copy", {"tutorial": tid})
        row = self.instance(copied["id"])
        self.assertEqual({k: row[k] for k in ("owner", "kind", "tutorial", "creative", "persistent", "map", "name", "visibility")},
                         dict(owner="player", kind="world", tutorial=None, creative=1, persistent=1, map="creative_plane_m",
                              name="Fix the power", visibility="private"))
        saves = self.data / "worlds" / copied["id"] / "data/babylon/saves"
        self.assertEqual(json.loads((saves / "latest.json").read_text()),
                         {"generation": GENERATION, "saved_at": "2026-11-14 12:00:00", "objects": 3})
        self.assertTrue((saves / GENERATION / "map.dmm").is_file())
        # The Driver restores it on the first start, like any saved world.
        from supervisor import Driver
        self.assertEqual(Driver(self.config, self.s.catalog).restore_source(row), saves / GENERATION)
        self.assertEqual(self.s.checkpoints.list(copied["id"])["latest"], GENERATION)
        # It counts against the world limits; pending tutorials can't be copied.
        self.s.config["max_worlds_per_player"] = 1
        with self.assertRaisesRegex(Denied, "world limit"):
            self.s.dispatch("player", "tutorial_copy", {"tutorial": tid})
        self.assertTrue(self.s.dispatch("admin", "tutorial_copy", {"tutorial": tid})["ok"])
        self.s.config["tutorial_submit_cooldown_hours"] = 0
        world, run = self.creative_run("author3")
        pending = self.submit(run, actor="author3")
        with self.assertRaisesRegex(Denied, "Only published"):
            self.s.dispatch("admin", "tutorial_copy", {"tutorial": pending})

    def test_copy_checks_the_world_limit_again_after_copying(self):
        # m-c: a world created while the copy ran must not let the owner exceed the limit.
        tid = self.published()
        self.s.config["max_worlds_per_player"] = 1
        import tutorials
        real = tutorials.seed_first_save

        def seed_and_create(snapshot, saves):
            result = real(snapshot, saves)
            self.s.dispatch("player", "create", dict(name="Meanwhile", visibility="private"))
            return result
        with unittest.mock.patch("supervisor.seed_first_save", seed_and_create):
            with self.assertRaisesRegex(Denied, "world limit"):
                self.s.dispatch("player", "tutorial_copy", {"tutorial": tid})
        rows = self.s.db.execute("SELECT name FROM worlds WHERE owner='player'").fetchall()
        self.assertEqual([r[0] for r in rows], ["Meanwhile"])
        self.assertEqual(sorted(p.name for p in (self.data / "worlds").iterdir()
                                if (p / "data/babylon/saves/latest.json").exists()), [])
        self.assertFalse(self.s.copying)
        self.assertFalse(self.s.tutorial_readers)

    def test_copy_reservations_survive_no_failed_commit(self):
        # m-c: the reservations are taken outside the transaction block; a failing commit there
        # leaves none behind.
        tid = self.published()
        real = self.s.db

        class FailingCommit:
            def __getattr__(self, name):
                return getattr(real, name)

            def __enter__(self):
                return real.__enter__()

            def __exit__(self, kind, *rest):
                if kind is None:
                    real.rollback()
                    raise RuntimeError("disk full")
                return real.__exit__(kind, *rest)
        self.s.db = FailingCommit()
        try:
            with self.assertRaises(RuntimeError):
                self.s.dispatch("player", "tutorial_copy", {"tutorial": tid})
        finally:
            self.s.db = real
        self.assertFalse(self.s.copying)
        self.assertFalse(self.s.tutorial_readers)
        self.assertTrue(self.s.dispatch("player", "tutorial_copy", {"tutorial": tid})["ok"])

    def test_stop_while_an_instance_prepares_deletes_it(self):
        # S-A for tutorial instances: Stop under My worlds while Play prepares cancels the start;
        # the instance (row and files) goes like any ended instance.
        tid = self.published()
        preparing, release = threading.Event(), threading.Event()

        def prepare(world, run):
            (self.data / "worlds" / world["id"]).mkdir(parents=True, exist_ok=True)
            preparing.set()
            release.wait(10)
        self.driver.prepare = prepare
        outcome = {}

        def play():
            try:
                self.s.dispatch("player", "tutorial_play", {"tutorial": tid})
            except Denied as error:
                outcome["error"] = str(error)
        worker = threading.Thread(target=play)
        worker.start()
        self.assertTrue(preparing.wait(10))
        with self.s.lock:
            instance = self.s.row("SELECT id FROM worlds WHERE kind='tutorial' AND owner='player'")["id"]
        self.s.dispatch("player", "stop", {"world": instance})
        release.set()
        worker.join(10)
        self.assertFalse(self.s.row("SELECT * FROM worlds WHERE id=?", (instance,)))
        self.assertFalse(self.s.row("SELECT * FROM runs WHERE world=?", (instance,)))
        self.assertFalse((self.data / "worlds" / instance).exists())
        self.assertFalse(self.s.tutorial_readers)
        self.assertIn("cancelled: it was stopped", outcome["error"])
        self.assertEqual(self.driver.starts, 1)  # the author's world; no process for the instance

    def test_no_new_instances_while_shutting_down(self):
        tid = self.published()
        self.s.shutting_down = True
        for action in ("tutorial_play", "tutorial_copy", "tutorial_edit"):
            with self.assertRaisesRegex(Denied, "restarting"):
                self.s.dispatch("admin", action, {"tutorial": tid})


class Robustness(TutorialFixture):
    def pending(self):
        world, run = self.creative_run()
        return world, run, self.submit(run)

    def test_interrupted_save_back_swap_is_recovered(self):
        world, run, tid = self.pending()
        folder = self.data / "tutorials/pending" / tid
        # A crash between "save -> save.old" and "save.staging -> save".
        (folder / "save").rename(folder / "save.old")
        broken = self.save(world, "save-20261114-160000-8")
        (broken / "state.json").write_text("not json")
        from tutorials import TutorialError
        with self.assertRaises(TutorialError):
            self.s.tutorials.replace_save(tid, broken)
        self.assertEqual((folder / "save/map.dmm").read_text(), "map of " + world, "the old snapshot is back")
        self.assertFalse((folder / "save.old").exists())
        good = self.save(world, "save-20261114-170000-9")
        (good / "map.dmm").write_text("newer")
        self.s.tutorials.replace_save(tid, good)
        self.assertEqual((folder / "save/map.dmm").read_text(), "newer")

    def test_accept_puts_the_files_back_when_the_database_fails(self):
        world, run, tid = self.pending()
        real = self.s.db

        class FailingUpdate:
            def __getattr__(self, name):
                return getattr(real, name)

            def execute(self, sql, *args):
                if sql.startswith("UPDATE tutorials SET status='published'"):
                    raise RuntimeError("disk full")
                return real.execute(sql, *args)

            def __enter__(self):
                return real.__enter__()

            def __exit__(self, *exc):
                return real.__exit__(*exc)
        self.s.db = FailingUpdate()
        try:
            with self.assertRaises(RuntimeError):
                self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        finally:
            self.s.db = real
        self.assertEqual(self.tutorial(tid)["status"], "pending")
        self.assertTrue((self.data / "tutorials/pending" / tid / "save/map.dmm").is_file())
        self.assertFalse((self.data / "tutorials/published" / tid).exists())
        self.s.dispatch("admin", "tutorial_accept", {"tutorial": tid})
        self.assertEqual(self.tutorial(tid)["status"], "published")

    def test_failed_copy_leaves_no_world_files(self):
        tid = self.published()
        real = self.s.db
        worlds = set((self.data / "worlds").iterdir())

        class FailingInsert:
            def __getattr__(self, name):
                return getattr(real, name)

            def execute(self, sql, *args):
                if sql.startswith("INSERT INTO worlds"):
                    raise RuntimeError("disk full")
                return real.execute(sql, *args)

            def __enter__(self):
                return real.__enter__()

            def __exit__(self, *exc):
                return real.__exit__(*exc)
        self.s.db = FailingInsert()
        try:
            with self.assertRaises(RuntimeError):
                self.s.dispatch("player", "tutorial_copy", {"tutorial": tid})
        finally:
            self.s.db = real
        self.assertEqual(set((self.data / "worlds").iterdir()), worlds)
        self.assertIsNone(self.s.row("SELECT * FROM worlds WHERE owner='player'"))

    def test_an_empty_instance_in_error_is_ended(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        self.s.tick()
        run = self.s.row("SELECT * FROM runs WHERE world=?", (world,))
        # It reports an error (its process is retained for ordinary worlds) and nobody is in it.
        self.driver.runs[run["id"]]["error"] = "boom"
        status = self.driver.status
        self.driver.status = lambda r: dict(status(r), error=self.driver.runs[r["id"]].get("error"))
        self.s.tick()
        self.assertEqual(self.s.row("SELECT state FROM runs WHERE world=?", (world,))["state"], "error")
        self.now += self.config["empty_grace_seconds"] - 1
        self.s.tick()
        self.assertTrue(self.s.row("SELECT * FROM runs WHERE world=?", (world,)))
        self.now += 2
        self.s.tick()
        self.assertEqual(self.driver.killed, [run["id"]])
        self.assertIsNone(self.s.row("SELECT * FROM runs WHERE world=?", (world,)))
        self.assertIsNone(self.s.row("SELECT * FROM worlds WHERE id=?", (world,)))
        # The player can play again.
        self.assertTrue(self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["ok"])

    def test_an_instance_that_never_answered_is_ended(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        run = self.s.row("SELECT * FROM runs WHERE world=?", (world,))
        # Startup timed out: the process lives but never answers a status request.
        self.s.db.execute("UPDATE runs SET state='error',error='Startup timed out; process retained' WHERE id=?", (run["id"],))
        self.s.db.commit()
        status = self.driver.status

        def silent(r):
            if r["id"] == run["id"]:
                raise OSError("no answer")
            return status(r)
        self.driver.status = silent
        self.s.tick()
        self.assertTrue(self.s.row("SELECT * FROM runs WHERE world=?", (world,)))
        self.now += self.config["empty_grace_seconds"]
        self.s.tick()
        self.assertEqual(self.driver.killed, [run["id"]])
        self.assertIsNone(self.s.row("SELECT * FROM worlds WHERE id=?", (world,)))

    def test_a_silent_instance_with_players_is_told_then_ended(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        run = self.s.row("SELECT * FROM runs WHERE world=?", (world,))
        self.s.db.execute("UPDATE runs SET state='error',players='[\"player\"]' WHERE id=?", (run["id"],))
        self.s.db.commit()
        status = self.driver.status

        def silent(r):
            if r["id"] == run["id"]:
                raise OSError("no answer")
            return status(r)
        self.driver.status = silent
        self.s.tick()
        self.now += self.config["empty_grace_seconds"]
        self.s.tick()
        self.assertEqual([r for r, _ in self.driver.announced], [run["id"]])
        self.assertEqual(self.driver.killed, [run["id"]])

    def test_an_answering_instance_in_error_with_players_is_kept(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        self.s.tick()
        run = self.s.row("SELECT * FROM runs WHERE world=?", (world,))
        self.driver.runs[run["id"]]["error"] = "boom"
        self.driver.runs[run["id"]]["players"] = ["player"]
        status = self.driver.status
        self.driver.status = lambda r: dict(status(r), error=self.driver.runs[r["id"]].get("error"))
        self.s.tick()
        self.now += self.config["empty_grace_seconds"] * 10
        self.s.tick()
        self.assertTrue(self.s.row("SELECT * FROM runs WHERE world=?", (world,)))
        self.assertFalse(getattr(self.driver, "killed", []))

    def test_an_ordinary_world_in_error_keeps_its_process(self):
        world, run = self.creative_run()
        self.driver.runs[run["id"]]["error"] = "boom"
        status = self.driver.status
        self.driver.status = lambda r: dict(status(r), error=self.driver.runs[r["id"]].get("error"))
        self.s.tick()
        self.now += self.config["empty_grace_seconds"] * 10
        self.s.tick()
        self.assertEqual(self.s.row("SELECT state FROM runs WHERE world=?", (world,))["state"], "error")
        self.assertFalse(getattr(self.driver, "killed", []))

    def test_a_broken_play_instance_is_explained(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        self.s.db.execute("UPDATE runs SET state='error' WHERE world=?", (world,))
        self.s.db.commit()
        with self.assertRaisesRegex(Denied, "Stop it under My worlds"):
            self.s.dispatch("player", "tutorial_play", {"tutorial": tid})

    def test_copies_credit_the_original_when_submitted(self):
        original = self.published()
        copied = self.s.dispatch("player", "tutorial_copy", {"tutorial": original})["id"]
        row = self.s.row("SELECT copied_from FROM worlds WHERE id=?", (copied,))
        self.assertEqual(json.loads(row["copied_from"]), {"id": original, "title": "Fix the power", "author": "owner"})
        run = self.start(copied, "player")  # its seeded first checkpoint is submitted again
        tid = self.submit(run, actor="player", title="Fix the power, extended")
        based_on = {"id": original, "title": "Fix the power", "author": "owner"}
        self.assertEqual(json.loads((self.data / "tutorials/pending" / tid / "meta.json").read_text())["based_on"], based_on)
        items = {i["id"]: i for i in self.s.dispatch("admin", "tutorials", {})["tutorials"]}
        self.assertEqual(items[tid]["based_on"], based_on)
        self.assertIsNone(items[original]["based_on"])
        self.assertNotIn("based_on", self.s.dispatch("player", "tutorials", {})["tutorials"][0])

    def test_lobby_forwards_every_field_the_page_reads(self):
        # Contract (the DM item builder can't run here): every field lobby.js reads from a tutorial
        # comes from the supervisor's real list item and is forwarded by lobby.dm's
        # lobby_tutorial_item; a field it drops never reaches the page, whatever the JS test injects.
        lobby = Path(__file__).resolve().parents[2] / "modular_babylon/lobby"
        script = (lobby / "lobby.js").read_text(encoding="utf-8")
        dm = (lobby / "lobby.dm").read_text(encoding="utf-8")
        builder = re.search(r"^/proc/lobby_tutorial_item\(.*?(?=^\S)", dm, re.M | re.S).group(0)
        # clean["x"] = ..., "x" = item["x"] / lobby_number(item["x"]), and for(var/key in list("x", ...)).
        forwarded = set(re.findall(r'clean\["(\w+)"\]', builder))
        forwarded |= set(re.findall(r'"(\w+)" = [\w(]*item\["\1"\]', builder))
        for keys in re.findall(r"for\(var/key in list\(([^)]*)\)\)", builder):
            forwarded |= set(re.findall(r'"(\w+)"', keys))
        # Fields read through any name for a tutorial: tutorial.x, current.x, tutorials[i].x, ...
        read = set(re.findall(r"\b(?:tutorial|current|tutorials\[\w+\])\.(\w+)", script))
        read -= {"length"}
        nested = set(re.findall(r"\bbased_on\.(\w+)", script))
        self.assertIn("based_on", read)
        self.assertEqual(read - forwarded, set(), "fields lobby.js reads that lobby.dm drops")
        based_on_kept = set(re.findall(r'"(\w+)" = based_on\["\1"\]', builder))
        self.assertEqual(nested - based_on_kept, set(), "based_on fields lobby.js reads that lobby.dm drops")
        # The page escapes them as text: lobby.dm keeps only text (or drops based_on whole).
        for field in nested:
            self.assertIn('istext(based_on["%s"])' % field, builder)
        # The page state carries the list (and who may review) from the Tutorials tab's builder.
        page_state = re.search(r"^/mob/lobby/proc/show_browser\(.*?(?=^\S)", dm, re.M | re.S).group(0)
        for key in set(re.findall(r"\blobbyState\.(tutorials\w*|admin)\b", script)):
            self.assertRegex(page_state, r'(state\["%s"\] =|"%s" = )' % (key, key), key)
        # ...and the supervisor sends them all (an admin's item for a copied, pending tutorial).
        original = self.published()
        copied = self.s.dispatch("player", "tutorial_copy", {"tutorial": original})["id"]
        tid = self.submit(self.start(copied, "player"), actor="player", title="Extended")
        item = next(i for i in self.s.dispatch("admin", "tutorials", {})["tutorials"] if i["id"] == tid)
        self.assertEqual(read - set(item), set(), "fields lobby.js reads that the supervisor does not send")
        self.assertEqual(nested - set(item["based_on"]), set())


class SnapshotCopiedAtPrepare(test_driver.DriverFixture):
    def test_instance_is_prepared_from_a_copy(self):
        """A tutorial deleted (or accepted) while its instances run does not affect them: prepare
        copies the snapshot into the world before the child starts."""
        snapshot = self.data / "tutorials/published/t1/save"
        self.generation(snapshot, ["z2.dmm", "z3.dmm"], self.station_state())
        world = self.world(kind="tutorial", tutorial="t1", persistent=0)
        self.driver.prepare(world, test_driver.RUN)
        import shutil
        shutil.rmtree(self.data / "tutorials")
        self.assertEqual((self.root() / "_maps/babylon/saved/z2.dmm").read_text(), "map z2.dmm")
        self.assertTrue((self.root() / "data/babylon/resume-state.json").is_file())


if __name__ == "__main__":
    unittest.main()


def test_driver_driver(case):
    """A real Driver on the test supervisor's data directory, wired like Supervisor wires it."""
    from supervisor import Driver
    driver = Driver(dict(case.s.config), case.s.catalog)
    driver.busy_tutorials = case.s.saving_back
    return driver
