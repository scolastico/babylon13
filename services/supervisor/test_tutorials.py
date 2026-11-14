"""The tutorial pipeline on the supervisor side: submit and save back (child actions), review, play
and copy (lobby actions), and the end of tutorial instances."""
import json
import os
from pathlib import Path
import time
import unittest

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

    def save(self, world, generation=GENERATION, records=3):
        """A checkpoint generation as the DM save writes it."""
        directory = self.data / "worlds" / world / "data/babylon/saves" / generation
        directory.mkdir(parents=True)
        (directory / "map.dmm").write_text("map of " + world)
        (directory / "z2.dmm").write_text("level 2")
        (directory / "state.json").write_text(json.dumps({"generation": generation, "records": [{}] * records}))
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

    def test_submit_check_and_actor_must_own_the_world(self):
        world, run = self.creative_run()
        self.assertEqual(self.child("tutorial_submit_check", run, actor="owner"), {"ok": True, "wait_seconds": 0})
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

    def test_instances_without_a_run_are_removed_at_startup(self):
        tid = self.published()
        world = self.s.dispatch("player", "tutorial_play", {"tutorial": tid})["world"]
        self.s.db.execute("DELETE FROM runs WHERE world=?", (world,))
        self.s.db.commit()
        self.s.db.close()
        self.s = Supervisor(self.config, self.driver, lambda: self.now)
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
