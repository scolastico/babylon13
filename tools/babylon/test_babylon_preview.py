"""Atlas staging must render the same overlaid wreck that fresh child worlds use."""
from pathlib import Path
import hashlib
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_babylon_preview as babylon
from render_map_previews import parse_dmm

ROOT = Path(__file__).resolve().parents[2]


class BabylonAtlas(unittest.TestCase):
    def test_staged_source_uses_prepared_wreck_and_frames_spawn_and_vault(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary) / "source"
            active = babylon.prepare_source(ROOT, stage)
            self.assertEqual(active, stage / "_maps/babylon/active.dmm")
            metadata = json.loads((ROOT / '_maps/babylon/previews/babylon.render.json').read_text())
            self.assertEqual(metadata['prepared_map_sha256'], hashlib.sha256(active.read_bytes()).hexdigest())
            self.assertEqual(metadata['crop_inclusive'], list(babylon.CROP))
            self.assertEqual(metadata['renderer'], babylon.ATLAS_IMAGE)
            self.assertEqual(metadata['png_sha256'], hashlib.sha256((ROOT / babylon.PREVIEW).read_bytes()).hexdigest())
            keys, levels = parse_dmm(active.read_text())
            level = levels[1]
            spawn = [pos for pos, key in level.items()
                     if "/obj/effect/mob_spawn/ghost_role/drone/derelict/babylon" in keys[key]
                     and "/area/ruin/space/bb13/engineering/sec_eng" in keys[key]]
            self.assertEqual(spawn, [(41, 53)])
            self.assertIn("/obj/machinery/computer/vaultcontroller/babylon", keys[level[(42, 55)]])
            self.assertIn("/obj/machinery/door/airlock/vault/derelict", keys[level[(41, 56)]])
            self.assertIn("/obj/machinery/door/airlock/vault/derelict", keys[level[(41, 57)]])
            left, bottom, right, top = babylon.CROP
            self.assertEqual(right - left + 1, 2 * (top - bottom + 1))
            for x, y in (spawn[0], (42, 55), (41, 56), (41, 57)):
                self.assertTrue(left <= x <= right and bottom <= y <= top)
            self.assertLessEqual(right - left + 1, 24, "local close-up, not the full 81x81 wreck")
            self.assertEqual((stage / 'icons').readlink(), Path('/source/icons'))
            self.assertEqual((stage / '_maps/babylon13.json').readlink(), Path('/source/_maps/babylon13.json'))
            self.assertFalse(active.is_symlink(), "prepared map is a private file")


if __name__ == '__main__':
    unittest.main()
