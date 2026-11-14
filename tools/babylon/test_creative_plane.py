"""The Creative Plane generator (gen_creative_plane.py) and the committed maps it produced."""
import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_creative_plane as plane  # noqa: E402
import render_map_previews as previews  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "_maps/babylon/catalog.json"
NORTH, SOUTH, EAST, WEST = 1, 2, 4, 8
STEP = {NORTH: (0, 1), SOUTH: (0, -1), EAST: (1, 0), WEST: (-1, 0)}


def parsed(size_id):
    """({key: [full entries]}, {(x, y): key}) of a committed map, var edits included."""
    text = (plane.MAPS / ("creative_plane_%s.dmm" % size_id)).read_text(encoding="utf-8")
    keys, levels = previews.parse_dmm(text)
    full = {}
    for match in re.finditer(r'^"([A-Za-z]{3})" = \(\n(.*?)\)$', text, re.M | re.S):
        full[match.group(1)] = previews.split_top(match.group(2).replace("\n", " "))
    return keys, full, levels[1]


def find(full, grid, path):
    """[(x, y, entry)] of every entry whose type path is exactly path."""
    found = []
    for position, key in grid.items():
        for entry in full[key]:
            if entry.split("{", 1)[0].strip() == path:
                found.append((position[0], position[1], entry))
    return sorted(found)


def direction(entry, default=SOUTH):
    match = re.search(r"dir = (\d+)", entry)
    return int(match.group(1)) if match else default


class CreativePlaneTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.maps = {size_id: parsed(size_id) for size_id in plane.SIZES}

    def test_generated_maps_match_script(self):
        # Rerunning the generator gives byte-identical maps and json (no hand edits, no drift).
        for path, text in plane.outputs().items():
            with self.subTest(path.name):
                self.assertTrue(path.is_file(), "%s is missing; run gen_creative_plane.py" % path.name)
                self.assertEqual(path.read_text(encoding="utf-8"), text, "%s is stale; run gen_creative_plane.py" % path.name)
        self.assertEqual(plane.generate(50), plane.generate(50))

    def test_tgm_format(self):
        text = (plane.MAPS / "creative_plane_s.dmm").read_text(encoding="utf-8")
        self.assertTrue(text.startswith(plane.TGM_HEADER + "\n"))
        self.assertTrue(text.endswith('"}\n'))
        self.assertEqual(text.count(",1,1) = {\""), 255)

    def test_sizes(self):
        for size_id, size in plane.SIZES.items():
            with self.subTest(size_id):
                keys, _, grid = self.maps[size_id]
                xs = {x for x, _ in grid}
                ys = {y for _, y in grid}
                self.assertEqual((min(xs), max(xs), min(ys), max(ys)), (1, 255, 1, 255))
                floor = [p for p, key in grid.items() if any(t.startswith("/turf/open/floor") for t in keys[key])]
                plane_area = [p for p, key in grid.items() if plane.AREA in keys[key] or plane.UTILITY_AREA in keys[key]]
                fx = [x for x, _ in floor]
                fy = [y for _, y in floor]
                self.assertEqual((max(fx) - min(fx) + 1, max(fy) - min(fy) + 1), (size, size))
                # Centred: the space on both sides differs by at most one tile.
                self.assertLessEqual(abs((min(fx) - 1) - (255 - max(fx))), 1)
                self.assertLessEqual(abs((min(fy) - 1) - (255 - max(fy))), 1)
                # The two areas are the floor plus its wall ring; everything else is space.
                self.assertEqual(len(plane_area), (size + 2) ** 2)
                space = [p for p, key in grid.items() if keys[key] == [plane.SPACE, plane.SPACE_AREA]]
                self.assertEqual(len(space), 255 * 255 - (size + 2) ** 2)
                ring = [(x, y) for x in range(min(fx) - 1, max(fx) + 2) for y in (min(fy) - 1, max(fy) + 1)]
                ring += [(x, y) for y in range(min(fy) - 1, max(fy) + 2) for x in (min(fx) - 1, max(fx) + 1)]
                # The ring is indestructible (a breach would vent the whole plane); the room's walls are not.
                self.assertTrue(plane.OUTER_WALL.startswith("/turf/closed/indestructible/"))
                self.assertTrue(all(plane.OUTER_WALL in keys[grid[p]] for p in ring))
                self.assertEqual(sum(1 for key in grid.values() if plane.OUTER_WALL in keys[key]), 4 * (size + 1))
                self.assertTrue(any(plane.ROOM_WALL in keys[key] for key in grid.values()))

    def test_landmarks_present(self):
        for size_id in plane.SIZES:
            with self.subTest(size_id):
                keys, full, grid = self.maps[size_id]
                latejoin = find(full, grid, plane.LATEJOIN)
                assistant = find(full, grid, plane.ASSISTANT)
                observer = find(full, grid, plane.OBSERVER)
                self.assertEqual((len(latejoin), len(assistant), len(observer)), (8, 8, 1))
                for x, y, _ in latejoin + assistant + observer:
                    self.assertIn(plane.PAD, keys[grid[(x, y)]])
                    self.assertIn(plane.AREA, keys[grid[(x, y)]])
                # No other job landmarks: every other job falls back to the late-join points.
                others = {t for key in set(grid.values()) for t in keys[key]
                          if t.startswith("/obj/effect/landmark/start/") and t != plane.ASSISTANT}
                self.assertEqual(others, set())

    def test_machine_settings_in_the_map(self):
        for size_id in plane.SIZES:
            with self.subTest(size_id):
                keys, full, grid = self.maps[size_id]
                (sx, sy, smes), = find(full, grid, "/obj/machinery/power/smes/babylon_creative")
                self.assertIn('creative_mode = "source"', smes)
                self.assertRegex(smes, r"charge = \d{8,}")
                self.assertIn("output_level = 1000000", smes)
                self.assertIn(plane.CABLE, keys[grid[(sx, sy)]])
                # The terminal faces the SMES (tg finds it by its dir) and has no cable.
                (tx, ty, terminal), = find(full, grid, "/obj/machinery/power/terminal")
                step = STEP[direction(terminal)]
                self.assertEqual((tx + step[0], ty + step[1]), (sx, sy))
                self.assertNotIn(plane.CABLE, keys[grid[(tx, ty)]])
                # One APC per area, each on a cable joined to the main line, mounted on a wall south.
                apcs = find(full, grid, plane.APC)
                self.assertEqual(sorted(next(p for p in keys[grid[(x, y)]] if p.startswith("/area/")) for x, y, _ in apcs),
                                 [plane.AREA, plane.UTILITY_AREA])
                for ax, ay, _ in apcs:
                    self.assertIn(plane.CABLE, keys[grid[(ax, ay)]])
                    self.assertTrue(keys[grid[(ax, ay - 1)]][-2].startswith("/turf/closed"))
                cables = {(x, y) for x, y, _ in find(full, grid, plane.CABLE)}
                reached, frontier = {(sx, sy)}, [(sx, sy)]
                while frontier:
                    x, y = frontier.pop()
                    for dx, dy in STEP.values():
                        if (x + dx, y + dy) in cables and (x + dx, y + dy) not in reached:
                            reached.add((x + dx, y + dy))
                            frontier.append((x + dx, y + dy))
                self.assertEqual(reached, cables)  # one network: SMES, both APCs, edge and spine
                self.assertIn(plane.UTILITY_AREA, keys[grid[(sx, sy)]])
                (px, py, plaque), = find(full, grid, "/obj/structure/plaque/static_plaque")
                self.assertIn("Ctrl + Shift + click", plaque)
                self.assertIn(plane.UTILITY_AREA, keys[grid[(px, py)]])

                canisters = {}
                for path in ("/obj/machinery/portable_atmospherics/canister/babylon_creative",
                             "/obj/machinery/portable_atmospherics/canister/babylon_creative/nitrogen",
                             "/obj/machinery/portable_atmospherics/canister/babylon_creative/void"):
                    (cx, cy, entry), = find(full, grid, path)
                    canisters[path.rsplit("/", 1)[1]] = entry
                    tile = keys[grid[(cx, cy)]]
                    self.assertIn("/obj/machinery/atmospherics/components/unary/portables_connector/visible", tile)
                    self.assertIn(plane.UTILITY_AREA, tile)
                self.assertIn("creative_gas = /datum/gas/oxygen", canisters["babylon_creative"])
                self.assertIn("creative_gas = /datum/gas/nitrogen", canisters["nitrogen"])
                for name in ("babylon_creative", "nitrogen"):
                    self.assertIn('creative_mode = "source"', canisters[name])
                    self.assertIn("creative_pressure = 4500", canisters[name])
                self.assertIn('creative_mode = "void"', canisters["void"])

    def test_atmos_connections(self):
        # Every unary device points at a pipe or device; the mixer gets N2 west, O2 south.
        keys, full, grid = self.maps["m"]
        piping = "/obj/machinery/atmospherics/"

        def piping_at(x, y):
            return [t for t in keys[grid[(x, y)]] if t.startswith(piping)]

        unary = []
        for path in ("components/unary/portables_connector/visible", "components/unary/vent_pump/on",
                     "components/unary/vent_scrubber/on"):
            unary += find(full, grid, piping + path)
        self.assertEqual(len(unary), 3 + 2 + 2)
        for x, y, entry in unary:
            step = STEP[direction(entry)]
            self.assertTrue(piping_at(x + step[0], y + step[1]), entry)
        (mx, my, mixer), = find(full, grid, piping + "components/trinary/mixer/airmix")
        self.assertEqual(direction(mixer), EAST)
        self.assertIn("/nitrogen", " ".join(keys[grid[(mx - 1, my)]]))
        self.assertTrue(any(t == "/obj/machinery/portable_atmospherics/canister/babylon_creative" for t in keys[grid[(mx, my - 1)]]))
        self.assertIn(plane.SUPPLY, keys[grid[(mx + 1, my)]])
        # Supply and scrubber pipes never touch (smart pipes on one layer would join them).
        supply = {(x, y) for x, y, _ in find(full, grid, plane.SUPPLY)}
        scrubbers = {(x, y) for x, y, _ in find(full, grid, plane.SCRUBBERS)}
        for x, y in supply:
            for dx, dy in STEP.values():
                self.assertNotIn((x + dx, y + dy), scrubbers)

    def test_map_json(self):
        for size_id, size in plane.SIZES.items():
            with self.subTest(size_id):
                config = json.loads((plane.MAPS / ("creative_plane_%s.json" % size_id)).read_text())
                self.assertEqual(config["version"], 1)
                self.assertEqual(config["map_name"], "Creative Plane %s" % size_id.upper())
                self.assertTrue((ROOT / "_maps" / config["map_path"] / config["map_file"]).is_file())
                self.assertEqual(config["minetype"], "none")
                self.assertNotIn("traits", config)  # tg's default: one station level

    def test_catalog_entries_point_at_the_maps_and_previews(self):
        catalog = {entry["id"]: entry for entry in json.loads(CATALOG.read_text())["maps"]}
        for size_id in plane.SIZES:
            entry = catalog["creative_plane_" + size_id]
            self.assertEqual(entry["map_json"], "babylon/creative_plane_%s.json" % size_id)
            self.assertEqual(entry["preview"], "_maps/babylon/previews/creative_plane_%s.png" % size_id)
            self.assertTrue((ROOT / entry["preview"]).is_file())


if __name__ == "__main__":
    unittest.main()
