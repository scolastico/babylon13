import os
import tempfile
import unittest
from pathlib import Path

from world_storage import tutorial_snapshot_dir


class TutorialSnapshotDir(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def save(self, status, tid):
        path = self.root / "tutorials" / status / tid / "save"
        path.mkdir(parents=True)
        return path

    def test_published_wins_over_pending(self):
        self.save("pending", "t1")
        published = self.save("published", "t1")
        self.assertEqual(tutorial_snapshot_dir(self.root, "t1"), published)

    def test_pending_used_when_not_published(self):
        pending = self.save("pending", "t1")
        self.assertEqual(tutorial_snapshot_dir(self.root, "t1"), pending)

    def test_missing_is_none(self):
        self.assertIsNone(tutorial_snapshot_dir(self.root, "t1"))

    def test_invalid_ids_raise(self):
        for tid in ("", "../x", "a/b", "x" * 65, None, 5):
            with self.assertRaises(ValueError):
                tutorial_snapshot_dir(self.root, tid)

    @unittest.skipIf(os.name == "nt", "symlinks")
    def test_symlinked_snapshot_is_ignored(self):
        outside = self.root / "outside"
        outside.mkdir()
        target = self.root / "tutorials/published/t1"
        target.mkdir(parents=True)
        (target / "save").symlink_to(outside, target_is_directory=True)
        self.assertIsNone(tutorial_snapshot_dir(self.root, "t1"))


if __name__ == "__main__":
    unittest.main()
