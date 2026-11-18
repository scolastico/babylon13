"""The map preview renderer (render_map_previews.py) and the shipped previews."""
import json
from pathlib import Path
import struct
import sys
import tempfile
from unittest.mock import patch
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_map_previews as previews  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]

# The same 3x2 map, z1, in TGM (one column per block) and classic DMM (one row per line).
KEYS = '''"a" = (
/turf/open/space/basic,
/area/space)
"b" = (
/turf/closed/wall/r_wall,
/area/station/command/bridge)
"c" = (
/obj/machinery/camera/directional/east{
	c_tag = "Bridge, (east)";
	network = list("ss13","rd")
	},
/turf/open/floor/iron,
/area/station/security/brig)
"d" = (
/obj/effect/spawner/structure/window/reinforced,
/turf/open/floor/plating,
/area/station/hallway/primary/fore)
'''
TGM = "//MAP CONVERTED BY dmm2tgm.py THIS HEADER COMMENT PREVENTS RECONVERSION, DO NOT REMOVE\n" + KEYS + '''
(1,1,1) = {"
b
a
"}
(2,1,1) = {"
c
d
"}
(3,1,1) = {"
a
b
"}
'''
CLASSIC = KEYS.replace("(\n", "(").replace(",\n", ",").replace("\n)", ")") + '''
(1,1,1) = {"
bca
adb
"}
(1,1,2) = {"
aaa
aaa
"}
'''


def decode_png(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    position, chunks = 8, {}
    while position < len(data):
        length, = struct.unpack(">I", data[position:position + 4])
        kind = data[position + 4:position + 8]
        body = data[position + 8:position + 8 + length]
        crc, = struct.unpack(">I", data[position + 8 + length:position + 12 + length])
        assert crc == zlib.crc32(kind + body) & 0xFFFFFFFF
        chunks[kind] = chunks.get(kind, b"") + body
        position += 12 + length
    width, height, depth, colour = struct.unpack(">IIBB", chunks[b"IHDR"][:10])
    raw = zlib.decompress(chunks[b"IDAT"])
    assert len(raw) == height * (1 + width * 4) and (depth, colour) == (8, 6)
    return width, height, raw


class Parser(unittest.TestCase):
    def check(self, text):
        keys, levels = previews.parse_dmm(text)
        self.assertEqual(keys["c"], ["/obj/machinery/camera/directional/east", "/turf/open/floor/iron", "/area/station/security/brig"])
        level = levels[1]
        self.assertEqual((level[(1, 2)], level[(2, 2)], level[(3, 2)]), ("b", "c", "a"))
        self.assertEqual((level[(1, 1)], level[(2, 1)], level[(3, 1)]), ("a", "d", "b"))
        return keys, levels

    def test_tgm_and_classic_dmm_agree(self):
        self.check(TGM)
        keys, levels = self.check(CLASSIC)
        self.assertEqual(sorted(levels), [1, 2])
        self.assertEqual(previews.busiest_level(keys, levels), 1)

    def test_tile_colours(self):
        keys, _ = previews.parse_dmm(TGM)
        self.assertIsNone(previews.tile_colour(keys["a"]), "space is transparent")
        self.assertEqual(previews.tile_colour(keys["b"]), previews.REINFORCED)
        self.assertEqual(previews.tile_colour(keys["d"]), previews.WINDOW)
        security = previews.tile_colour(keys["c"])
        self.assertGreater(security[0], security[2], "security floors are tinted red")

    def test_render_is_a_deterministic_png(self):
        keys, levels = previews.parse_dmm(TGM)
        first = previews.png(previews.render(keys, levels[1]))
        self.assertEqual(first, previews.png(previews.render(keys, levels[1])))
        width, height, raw = decode_png(first)
        self.assertEqual((width, height), (previews.WIDTH, previews.HEIGHT))
        alphas = raw[4::4]
        self.assertIn(0, alphas, "space and the frame stay transparent")
        self.assertIn(255, alphas)


class MapInputs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.patch = patch.object(previews, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        (self.root / "_maps/maps").mkdir(parents=True)
        (self.root / "_maps/maps/a.dmm").write_text(CLASSIC)
        # Same dictionary key, different meaning; second file is the busiest deck.
        (self.root / "_maps/maps/b.dmm").write_text(
            '\"a\" = (/turf/open/floor/iron,/area/station/medical)\n(1,1,1) = {\"\naaa\naaa\n\"}\n')
        self.entry = {"map_json": "test.json", "id": "test"}
        self.config(["a.dmm", "b.dmm"])

    def config(self, files):
        (self.root / "_maps/test.json").write_text(json.dumps({"map_path": "maps", "map_file": files}))

    def test_all_files_and_levels_participate_without_dictionary_collisions(self):
        keys, levels = previews.load_map(self.entry)
        self.assertEqual(sorted(levels), [1, 2, 3])
        self.assertEqual(keys[levels[1][(1, 1)]], ["/turf/open/space/basic", "/area/space"])
        self.assertEqual(keys[levels[3][(1, 1)]], ["/turf/open/floor/iron", "/area/station/medical"])
        self.assertEqual(previews.busiest_level(keys, levels), 3)
        image = previews.png(previews.render(keys, levels[3]))
        self.assertEqual(image, previews.png(previews.render(*self.main_level())))

    def main_level(self):
        keys, levels = previews.load_map(self.entry)
        return keys, levels[previews.busiest_level(keys, levels)]

    def test_string_map_file_and_case_sensitive_paths(self):
        self.config("a.dmm")
        self.assertEqual(previews.map_files(self.entry), [self.root / "_maps/maps/a.dmm"])
        self.config("A.dmm")
        with self.assertRaises(previews.MapError):
            previews.map_files(self.entry)

    def test_invalid_sources_fail_instead_of_skipping_or_using_first_file(self):
        for files in ([], None, ["a.dmm", "missing.dmm"], ["a.dmm", 3], "../../../outside.dmm"):
            with self.subTest(files=files):
                self.config(files)
                with self.assertRaises(previews.MapError):
                    previews.load_map(self.entry)
        (self.root / "_maps/test.json").unlink()
        with self.assertRaises(previews.MapError):
            previews.load_map(self.entry)


class ShippedPreviews(unittest.TestCase):
    def test_every_catalog_preview_exists(self):
        catalog = json.loads((ROOT / "_maps/babylon/catalog.json").read_text(encoding="utf-8"))
        for entry in catalog["maps"]:
            self.assertIsNotNone(entry["preview"], entry["id"])
            with self.subTest(entry["id"]):
                path = ROOT / entry["preview"]
                self.assertTrue(path.is_file())
                self.assertEqual(decode_png(path.read_bytes())[:2], (previews.WIDTH, previews.HEIGHT))

    def test_multiz_badges_match_actual_map_levels(self):
        catalog = json.loads((ROOT / "_maps/babylon/catalog.json").read_text())
        for entry in catalog["maps"]:
            if entry["build"] == "station":
                with self.subTest(entry["id"]):
                    _, levels = previews.load_map(entry)
                    self.assertEqual(len(levels) > 1, entry["multiz"])

    def test_every_station_map_with_a_map_file_has_a_preview(self):
        catalog = json.loads((ROOT / "_maps/babylon/catalog.json").read_text(encoding="utf-8"))
        for entry in catalog["maps"]:
            if entry["build"] == "station" and previews.map_files(entry):
                self.assertEqual(entry["preview"], "_maps/babylon/previews/%s.png" % entry["id"])


if __name__ == "__main__":
    unittest.main()
