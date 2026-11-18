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


def piping_layer(entry):
    """Resolve the mapped layer, including a component's explicit var edit."""
    explicit = re.search(r"piping_layer = (\d+)", entry)
    subtype = re.search(r"/layer(\d+)(?:\{|$)", entry)
    return int(explicit.group(1)) if explicit else int(subtype.group(1)) if subtype else 3


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

    def test_utility_room_leaves_the_west_catwalk_open(self):
        # Leaving even one wall/device at the old west edge blocks the perimeter route.
        for size_id, size in plane.SIZES.items():
            with self.subTest(size_id):
                keys, full, grid = self.maps[size_id]
                x0, y0 = plane.floor_origin(size)
                at = lambda u, v: keys[grid[(x0 + u, y0 + v)]]
                for v in range(size):
                    self.assertIn(plane.CATWALK, at(0, v), (0, v))
                    self.assertIn(plane.AREA, at(0, v))
                walls = {(x - x0, y - y0) for x, y, _ in find(full, grid, plane.ROOM_WALL)}
                expected = {(u, v) for u in range(1, 10) for v in range(1, 8)
                            if u in (1, 9) or v in (1, 7)} - {(5, 1)}
                self.assertEqual(walls, expected)
                self.assertIn(plane.DOOR.split("{", 1)[0], at(5, 1))
                self.assertIn(plane.CABLE, at(5, 1))
                self.assertIn(plane.CABLE, at(5, 2))
                self.assertIn(plane.APC, at(6, 2))
                self.assertIn(plane.AIR_ALARM, at(2, 6))
                self.assertIn("/obj/structure/plaque/static_plaque", at(7, 1))
                fixtures = {
                    (2, 3): "/obj/machinery/portable_atmospherics/canister/babylon_creative/nitrogen",
                    (3, 2): "/obj/machinery/portable_atmospherics/canister/babylon_creative",
                    (3, 3): self.PIPING + "components/trinary/mixer/airmix",
                    (8, 5): "/obj/machinery/portable_atmospherics/canister/babylon_creative/void",
                    (5, 4): self.PIPING + "components/unary/vent_pump/on/layer2",
                    (7, 4): self.PIPING + "components/unary/vent_pump/on/layer2",
                    (5, 6): self.PIPING + "components/unary/vent_scrubber/on/layer4",
                    (7, 6): self.PIPING + "components/unary/vent_scrubber/on/layer4",
                }
                for (u, v), path in fixtures.items():
                    self.assertIn(path, at(u, v), (u, v))
                for u in range(2, 9):
                    for v in range(2, 7):
                        self.assertIn(plane.FLOOR, at(u, v), (u, v))
                        self.assertIn(plane.UTILITY_AREA, at(u, v), (u, v))
                # The translation leaves a free column between the east wall and the rest of the plane.
                for v in range(3, 8):
                    self.assertIn(plane.FLOOR, at(10, v))
                    self.assertEqual(len(at(10, v)), 2)

    def test_utility_pipes_have_no_unused_branches(self):
        # A redundant pipe west of the scrubber trunk becomes a dangling red stub in game.
        for size_id, size in plane.SIZES.items():
            with self.subTest(size_id):
                pipes, devices = self.atmos(size_id)
                x0, y0 = plane.floor_origin(size)
                for layer, positions in pipes.items():
                    for x, y in positions:
                        if not (0 <= x - x0 <= 9 and 1 <= y - y0 <= 7):
                            continue
                        connections = sum((x + dx, y + dy) in positions for dx, dy in STEP.values())
                        for path, dx, dy, facing, device_layer in devices:
                            if device_layer != layer:
                                continue
                            if "/unary/" in path:
                                step = STEP[facing]
                                connections += (dx + step[0], dy + step[1]) == (x, y)
                            elif "/mixer/" in path:
                                connections += (dx + 1, dy) == (x, y)
                        self.assertGreaterEqual(connections, 2, (size_id, layer, x - x0, y - y0))

    def test_supply_devices_and_pipes_use_layer_two(self):
        # Moving only the pipes to layer 2 silently disconnects layer-3 vents/mixer/ports.
        for size_id in plane.SIZES:
            with self.subTest(size_id):
                pipes, devices = self.atmos(size_id)
                self.assertTrue(pipes[2])
                self.assertFalse(pipes[3])
                for path, x, y, _, layer in devices:
                    if "/vent_scrubber/" in path or path.endswith("/layer4"):
                        self.assertEqual(layer, 4, (path, x, y))
                    else:
                        self.assertEqual(layer, 2, (path, x, y))

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
                    self.assertTrue(any(t.startswith("/obj/machinery/atmospherics/components/unary/portables_connector/visible") for t in tile))
                    self.assertIn(plane.UTILITY_AREA, tile)
                self.assertIn("creative_gas = /datum/gas/oxygen", canisters["babylon_creative"])
                self.assertIn("creative_gas = /datum/gas/nitrogen", canisters["nitrogen"])
                for name in ("babylon_creative", "nitrogen"):
                    self.assertIn('creative_mode = "source"', canisters[name])
                    self.assertIn("creative_pressure = 4500", canisters[name])
                self.assertIn('creative_mode = "void"', canisters["void"])

    PIPING = "/obj/machinery/atmospherics/"

    def atmos(self, size_id):
        """Pipes {layer: {(x, y)}}, devices [(kind, x, y, dir, layer)] of a committed map."""
        keys, full, grid = self.maps[size_id]
        pipes = {2: set(), 3: set(), 4: set()}
        devices = []
        for position, key in grid.items():
            for path in keys[key]:
                if not path.startswith(self.PIPING):
                    continue
                entry = next(e for e in full[key] if e.split("{", 1)[0].strip() == path)
                layer = piping_layer(entry)
                if "/pipe/smart/" in path:
                    pipes[layer].add(position)
                else:
                    devices.append((path, position, layer))
        found = []
        for path, position, layer in devices:
            for entry in full[grid[position]]:
                if entry.split("{", 1)[0].strip() == path:
                    found.append((path, position[0], position[1], direction(entry), layer))
        return pipes, sorted(found)

    @staticmethod
    def reach(pipes, start):
        """The tiles of one pipe layer connected to `start` (adjacent smart pipes join)."""
        reached, frontier = {start}, [start]
        while frontier:
            x, y = frontier.pop()
            for dx, dy in STEP.values():
                nxt = (x + dx, y + dy)
                if nxt in pipes and nxt not in reached:
                    reached.add(nxt)
                    frontier.append(nxt)
        return reached

    def test_atmos_connections(self):
        # Every unary device points at a pipe or device; the mixer gets N2 west, O2 south.
        keys, full, grid = self.maps["m"]
        pipes, devices = self.atmos("m")
        unary = [d for d in devices if "/unary/" in d[0]]
        for path, x, y, facing, layer in unary:
            step = STEP[facing]
            target = (x + step[0], y + step[1])
            self.assertTrue(target in pipes[layer] or any(t.startswith(self.PIPING) for t in keys[grid[target]]), (path, x, y))
        (mx, my, mixer), = find(full, grid, self.PIPING + "components/trinary/mixer/airmix")
        self.assertEqual(direction(mixer), EAST)
        self.assertIn("/nitrogen", " ".join(keys[grid[(mx - 1, my)]]))
        self.assertTrue(any(t == "/obj/machinery/portable_atmospherics/canister/babylon_creative" for t in keys[grid[(mx, my - 1)]]))
        self.assertIn(plane.SUPPLY, keys[grid[(mx + 1, my)]])
        # Supply (layer 2) and scrubber (layer 4) pipes are on different layers, so they never join,
        # and every pipe tile of the network is a pipe of its own layer only.
        self.assertTrue(pipes[2] and pipes[4])
        self.assertEqual(plane.SUPPLY_LAYER, 2)
        self.assertEqual(plane.SCRUBBER_LAYER, 4)
        for path in (plane.SUPPLY, plane.SUPPLY_HIDDEN):
            self.assertTrue(path.endswith("/layer2"))
        for path in (plane.SCRUBBERS, plane.SCRUBBERS_HIDDEN):
            self.assertTrue(path.endswith("/layer4"))
        for position, key in grid.items():
            on = keys[key]
            has_supply = plane.SUPPLY in on or plane.SUPPLY_HIDDEN in on
            has_scrub = plane.SCRUBBERS in on or plane.SCRUBBERS_HIDDEN in on
            self.assertEqual(position in pipes[2], has_supply)
            self.assertEqual(position in pipes[4], has_scrub)

    def test_air_distribution_reaches_every_vent_and_scrubber(self):
        # Supply: the mixer's output pipe reaches every vent's pipe; scrubbers: every scrubber's pipe
        # reaches the void canister's port. Nothing is left dangling.
        for size_id, size in plane.SIZES.items():
            with self.subTest(size_id):
                keys, full, grid = self.maps[size_id]
                pipes, devices = self.atmos(size_id)
                (mx, my, _), = find(full, grid, self.PIPING + "components/trinary/mixer/airmix")
                supply = self.reach(pipes[2], (mx + 1, my))
                self.assertEqual(supply, pipes[2], "supply pipes not one network from the mixer")
                (vx, vy, _), = find(full, grid, "/obj/machinery/portable_atmospherics/canister/babylon_creative/void")
                scrubbers = self.reach(pipes[4], (vx - 1, vy))
                self.assertEqual(scrubbers, pipes[4], "scrubber pipes not one network from the void port")
                vents = [d for d in devices if d[0] == self.PIPING + "components/unary/vent_pump/on/layer2"]
                drains = [d for d in devices if d[0].startswith(self.PIPING + "components/unary/vent_scrubber/on")]
                self.assertGreaterEqual(len(vents), 2 + 4 * 2)
                self.assertGreaterEqual(len(drains), 2 + 4 * 2)
                for path, x, y, facing, layer in vents:
                    self.assertEqual(layer, plane.SUPPLY_LAYER)
                    step = STEP[facing]
                    self.assertIn((x + step[0], y + step[1]), supply, (x, y))
                for path, x, y, facing, layer in drains:
                    self.assertEqual(layer, plane.SCRUBBER_LAYER)
                    step = STEP[facing]
                    self.assertIn((x + step[0], y + step[1]), scrubbers, (x, y))

    def test_pipes_follow_the_cable_under_catwalk(self):
        for size_id, size in plane.SIZES.items():
            with self.subTest(size_id):
                keys, full, grid = self.maps[size_id]
                pipes, _ = self.atmos(size_id)
                x0, y0 = plane.floor_origin(size)
                local = lambda p: (p[0] - x0, p[1] - y0)  # noqa: E731
                cables = {local((x, y)) for x, y, _ in find(full, grid, plane.CABLE)}
                middle = size // 2
                for layer in (2, 4):
                    tiles = {local(p) for p in pipes[layer]}
                    # Along the cable: the south edge from the door east, and the whole middle column.
                    for u in range(5, size):
                        self.assertIn((u, 0), tiles)
                    for v in range(1, size):
                        self.assertIn((middle, v), tiles)
                    # Every pipe tile outside the utility room lies on catwalk floor (or under the
                    # spawn pad, as the cable's spine does) and the shared ones are the cable's tiles.
                    for position in pipes[layer]:
                        u, v = local(position)
                        if 1 <= u <= 9 and 1 <= v <= 7:
                            continue
                        turf = keys[grid[position]][-2]
                        self.assertIn(turf, (plane.CATWALK, plane.PAD), (u, v))
                        if (u, v) in cables and turf != plane.PAD:
                            self.assertEqual(turf, plane.CATWALK)
                    self.assertTrue((tiles & cables) >= {(u, 0) for u in range(5, size)})
                # The cable's own catwalk tiles that the pipes share keep their cable.
                for u, v in {local(p) for p in pipes[2]} & cables:
                    self.assertIn(plane.CABLE, keys[grid[(x0 + u, y0 + v)]])

    def test_vents_and_scrubbers_spread_near_the_outer_walls(self):
        for size_id, size in plane.SIZES.items():
            with self.subTest(size_id):
                pipes, devices = self.atmos(size_id)
                x0, y0 = plane.floor_origin(size)
                sides = {"south": [], "north": [], "east": [], "west": []}
                for path, x, y, facing, layer in devices:
                    u, v = x - x0, y - y0
                    if "/vent_pump/" not in path and "/vent_scrubber/" not in path:
                        continue
                    if 1 <= u <= 9 and 1 <= v <= 7:
                        continue  # the utility room's own devices
                    side = {SOUTH: "south", NORTH: "north", EAST: "east", WEST: "west"}[facing]
                    # One tile inside the wall ring, facing it.
                    wall_gap = {"south": v, "north": size - 1 - v, "west": u, "east": size - 1 - u}[side]
                    self.assertEqual(wall_gap, 1, (path, u, v))
                    sides[side].append((u if side in ("south", "north") else v, layer))
                for side, entries in sides.items():
                    self.assertGreaterEqual(len([1 for _, layer in entries if layer == 2]), 2, side)
                    self.assertGreaterEqual(len([1 for _, layer in entries if layer == 4]), 2, side)
                    positions = sorted(p for p, _ in entries)
                    # Evenly spread: devices cover most of the side, without long gaps.
                    self.assertGreaterEqual(positions[-1] - positions[0], size * 0.4, side)
                    gaps = [b - a for a, b in zip(positions, positions[1:])]
                    self.assertLessEqual(max(gaps), size * 0.5, side)

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
