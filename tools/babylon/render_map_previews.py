"""Renders top-down preview thumbnails of the catalog's station maps for the lobby's map picker.

Pure Python (no PIL): parses the map's .dmm (classic DMM or TGM), colours every tile by its turf
(space, wall, floor, terrain) tinted by its area's department, and writes an RGBA PNG with a
transparent background to _maps/babylon/previews/<id>.png. The catalog entry's "preview" is set
to that path. Output is deterministic, so unchanged maps give byte-identical files.

    python3 tools/babylon/render_map_previews.py            # every station map in the catalog
    python3 tools/babylon/render_map_previews.py icebox     # selected maps

Babylon uses render_babylon_preview.py for its atlas vault-start close-up.
Station inputs must exist; all map_file entries participate in deck selection. The Creative Plane
maps come from gen_creative_plane.py, which runs this script for them; their previews fill the
card with the plane in their own palette (grid, bright ring, spawn pad and utility corner).
"""
import json
from pathlib import Path
import re
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "_maps/babylon/catalog.json"
PREVIEWS = "_maps/babylon/previews"
# Longest side and the 2:1 frame of the lobby's map cards.
WIDTH, HEIGHT = 256, 128
SAMPLES = 3  # per axis; averaged so the downscaled map stays smooth

SPACE = None  # transparent
WALL = (184, 199, 214)
REINFORCED = (141, 157, 176)
WINDOW = (120, 196, 230)
ROCK = (52, 58, 68, 150)
TERRAIN = (70, 84, 100, 90)
LAVA = (122, 52, 32)
WATER = (40, 86, 128)
OTHER_FLOOR = (86, 96, 110)
# Department colours by /area/station/<segment>; floors are a muted shade of these.
DEPARTMENTS = (
    ("command", (70, 128, 214)), ("security", (204, 78, 78)), ("engineering", (222, 170, 64)),
    ("engine", (222, 170, 64)), ("medical", (92, 196, 222)), ("science", (166, 104, 222)),
    ("cargo", (196, 132, 64)), ("service", (96, 190, 112)), ("maintenance", (78, 86, 98)),
    ("hallway", (150, 164, 180)), ("ai_monitored", (64, 190, 160)), ("tcommsat", (64, 190, 160)),
    ("commons", (112, 140, 182)), ("solars", (70, 82, 110)),
)
STATION = (122, 138, 156)
BASE = (24, 32, 46)


class MapError(ValueError):
    pass


def split_top(text):
    """Splits a key's content "a{...},b,c" on commas outside strings, braces and parentheses."""
    parts, depth, quote, start, i = [], 0, None, 0, 0
    while i < len(text):
        char = text[i]
        if quote:
            if char == "\\":
                i += 1
            elif char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char in "{(":
            depth += 1
        elif char in "})":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    parts.append(text[start:])
    return [part.strip() for part in parts if part.strip()]


def parse_dmm(text):
    """Parses DMM or TGM text into ({key: [type paths]}, {z: {(x, y): key}})."""
    keys = {}
    position = 0
    key_pattern = re.compile(r'"([A-Za-z]+)" = \(')
    grid_start = text.find("\n(1,1,")
    header = text if grid_start < 0 else text[:grid_start]
    for match in key_pattern.finditer(header):
        i, depth, quote = match.end(), 1, None
        while i < len(header) and depth:
            char = header[i]
            if quote:
                if char == "\\":
                    i += 1
                elif char == quote:
                    quote = None
            elif char in "\"'":
                quote = char
            elif char in "({":
                depth += 1
            elif char in ")}":
                depth -= 1
            i += 1
        content = header[match.end():i - 1]
        keys[match.group(1)] = [part.split("{", 1)[0].strip() for part in split_top(content)]
        position = i
    if not keys:
        raise MapError("no tile keys found")
    width = len(next(iter(keys)))
    levels = {}
    for block in re.finditer(r'\((\d+),(\d+),(\d+)\) = \{"\n?(.*?)\n?"\}', text[position:], re.S):
        x0, y0, z = (int(block.group(n)) for n in (1, 2, 3))
        lines = [line for line in block.group(4).split("\n") if line]
        top = y0 + len(lines) - 1
        level = levels.setdefault(z, {})
        for row, line in enumerate(lines):
            for column in range(len(line) // width):
                level[(x0 + column, top - row)] = line[column * width:(column + 1) * width]
    if not levels:
        raise MapError("no map grid found")
    return keys, levels


def department(area):
    if not area or not area.startswith("/area/station"):
        return None
    parts = area.split("/")[3:]
    for name, colour in DEPARTMENTS:
        if name in parts:
            return colour
    return STATION


def mix(a, b, amount):
    return tuple(round(a[i] * (1 - amount) + b[i] * amount) for i in range(3))


def tile_colour(paths):
    """The colour of a tile from its type paths; None for space (transparent)."""
    turf = next((p for p in paths if p.startswith("/turf/")), "")
    area = next((p for p in paths if p.startswith("/area/")), "")
    if any("/window" in p and (p.startswith("/obj/structure/window") or p.startswith("/obj/effect/spawner/structure/window")) for p in paths):
        return WINDOW
    if not turf or turf.startswith(("/turf/open/space", "/turf/open/openspace", "/turf/template_noop")):
        return SPACE
    if turf.startswith("/turf/closed/wall"):
        return REINFORCED if "/r_wall" in turf else WALL
    if turf.startswith("/turf/closed"):
        return ROCK
    if turf.startswith("/turf/open/lava"):
        return LAVA
    if turf.startswith("/turf/open/water"):
        return WATER
    colour = department(area)
    if turf.startswith(("/turf/open/misc", "/turf/open/chasm", "/turf/open/genturf")) and colour is None:
        return TERRAIN
    if colour is None:
        return OTHER_FLOOR
    return mix(BASE, colour, 0.62)


def busiest_level(keys, levels):
    """The station's main level: the z with the most tiles in station areas outside maintenance."""
    def score(z):
        return sum(1 for key in levels[z].values()
                   if any(p.startswith("/area/station") and "/maintenance" not in p for p in keys.get(key, ())))
    return max(sorted(levels), key=score)


def bounds(positions):
    """The box around the bulk of the positions: stray solars or lattice far out are cut off."""
    xs = sorted(x for x, _ in positions)
    ys = sorted(y for _, y in positions)
    cut = len(xs) // 100
    return xs[cut] - 2, xs[-1 - cut] + 2, ys[cut] - 2, ys[-1 - cut] + 2


# Creative Plane previews (gen_creative_plane.py): the floor with a faint grid, the
# indestructible ring as a bright outline, the spawn pad and the utility corner in accents.
PLANE_RING = (226, 236, 246)
PLANE_FLOOR = mix(BASE, STATION, 0.62)
PLANE_GRID = mix(BASE, STATION, 0.45)
PLANE_CABLE = mix(BASE, (222, 170, 64), 0.45)
PLANE_UTILITY = mix(BASE, (222, 170, 64), 0.7)
PLANE_PAD = mix(BASE, (64, 190, 160), 0.8)
PLANE_GRID_LINES = 10  # about this many grid lines across the floor
PLANE_MARKER = 8  # pixels: the smallest the spawn pad and utility room are drawn


def plane_colour(paths, position, origin, spacing):
    """A Creative Plane tile's colour, or None when the tile is not part of the plane."""
    turf = next((p for p in paths if p.startswith("/turf/")), "")
    area = next((p for p in paths if p.startswith("/area/")), "")
    if not area.startswith("/area/station/babylon/creative_plane"):
        return None
    if turf.startswith("/turf/closed/indestructible"):
        return PLANE_RING
    if turf.startswith("/turf/closed"):
        return mix(PLANE_UTILITY, PLANE_RING, 0.5)
    if area.endswith("/utilities"):
        return PLANE_UTILITY
    if turf == "/turf/open/floor/iron/dark":
        return PLANE_PAD
    if "catwalk" in turf:
        return PLANE_CABLE
    if (position[0] - origin[0]) % spacing == 0 or (position[1] - origin[1]) % spacing == 0:
        return PLANE_GRID
    return PLANE_FLOOR


def render(keys, level, creative_plane=False):
    """RGBA rows (bytes) of the level cropped to its station, fitted into WIDTH x HEIGHT.
    Creative Plane maps get their own palette (plane_colour) and are cropped to the plane."""
    colours = {}
    station = []
    origin, spacing = (0, 0), 1
    if creative_plane:
        floor = [position for position, key in level.items()
                 if any(p.startswith("/area/station/babylon/creative_plane") for p in keys.get(key, ()))]
        origin = (min(x for x, _ in floor), min(y for _, y in floor))
        spacing = max(2, round((max(x for x, _ in floor) - origin[0]) / PLANE_GRID_LINES))
    for position, key in level.items():
        paths = keys.get(key, ())
        colour = plane_colour(paths, position, origin, spacing) if creative_plane else tile_colour(paths)
        if colour is not None:
            colours[position] = colour if len(colour) == 4 else colour + (255,)
            if any(p.startswith("/area/station") for p in paths):
                station.append(position)
    if not colours:
        raise MapError("the level has no visible tiles")
    if creative_plane:
        # The whole plane with a one-tile margin, so the ring is never cut off.
        left, right = min(x for x, _ in station) - 1, max(x for x, _ in station) + 1
        bottom, top = min(y for _, y in station) - 1, max(y for _, y in station) + 1
    else:
        left, right, bottom, top = bounds(station or list(colours))
    span_x, span_y = right - left + 1, top - bottom + 1
    scale = min(WIDTH / span_x, HEIGHT / span_y)
    offset_x = (WIDTH - span_x * scale) / 2
    offset_y = (HEIGHT - span_y * scale) / 2
    rows = []
    for py in range(HEIGHT):
        row = bytearray()
        for px in range(WIDTH):
            # Alpha-weighted average of the samples (premultiplied, then divided back).
            red = green = blue = alpha = 0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    tx = left + int((px + (sx + .5) / SAMPLES - offset_x) // scale)
                    ty = top - int((py + (sy + .5) / SAMPLES - offset_y) // scale)
                    colour = colours.get((tx, ty))
                    if colour and left <= tx <= right and bottom <= ty <= top:
                        red += colour[0] * colour[3]
                        green += colour[1] * colour[3]
                        blue += colour[2] * colour[3]
                        alpha += colour[3]
            if alpha:
                row += bytes((red // alpha, green // alpha, blue // alpha, alpha // SAMPLES ** 2))
            else:
                row += b"\0\0\0\0"
        rows.append(row)
    if creative_plane:
        plane_markers(rows, keys, level, left, top, scale, offset_x, offset_y)
    return [bytes(row) for row in rows]


def plane_markers(rows, keys, level, left, top, scale, offset_x, offset_y):
    """Keeps the Creative Plane's landmarks readable at every size: the ring as a 2 px outline,
    the spawn pad and the utility corner as boxes of at least PLANE_MARKER pixels."""
    def pixel_box(tiles):
        x0 = offset_x + (min(x for x, _ in tiles) - left) * scale
        x1 = offset_x + (max(x for x, _ in tiles) - left + 1) * scale
        y0 = offset_y + (top - max(y for _, y in tiles)) * scale
        y1 = offset_y + (top - min(y for _, y in tiles) + 1) * scale
        return x0, y0, x1, y1

    def fill(box, colour, minimum=0, inset=0):
        x0, y0, x1, y1 = box
        grow_x, grow_y = max(0, minimum - (x1 - x0)) / 2, max(0, minimum - (y1 - y0)) / 2
        x0, x1, y0, y1 = x0 - grow_x + inset, x1 + grow_x - inset, y0 - grow_y + inset, y1 + grow_y - inset
        for py in range(max(0, int(y0)), min(HEIGHT, int(round(y1)))):
            for px in range(max(0, int(x0)), min(WIDTH, int(round(x1)))):
                rows[py][px * 4:px * 4 + 4] = bytes(colour + (255,))

    def tiles_where(test):
        return [position for position, key in level.items() if test(keys.get(key, ()))]

    plane = tiles_where(lambda paths: any(p.startswith("/area/station/babylon/creative_plane") for p in paths))
    x0, y0, x1, y1 = pixel_box(plane)
    for edge in ((x0, y0, x1, y0 + 2), (x0, y1 - 2, x1, y1), (x0, y0, x0 + 2, y1), (x1 - 2, y0, x1, y1)):
        fill(edge, PLANE_RING)
    utility = tiles_where(lambda paths: any(p.endswith("/creative_plane/utilities") for p in paths))
    room = [(x, y) for x, y in utility if any(p.startswith("/turf/closed") for p in keys[level[(x, y)]])]
    fill(pixel_box(room or utility), mix(PLANE_UTILITY, PLANE_RING, 0.5), PLANE_MARKER)
    fill(pixel_box(room or utility), PLANE_UTILITY, PLANE_MARKER, 1)
    pad = tiles_where(lambda paths: "/turf/open/floor/iron/dark" in paths)
    fill(pixel_box(pad), PLANE_PAD, PLANE_MARKER)


def png(rows):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\0" + row for row in rows)
    header = struct.pack(">IIBBBBB", len(rows[0]) // 4, len(rows), 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def map_files(entry):
    """All source DMMs, in config order; invalid/missing station inputs are errors."""
    try:
        maps = (ROOT / "_maps").resolve()
        config = maps / entry["map_json"]
        data = json.loads(config.read_text(encoding="utf-8"))
        files = data["map_file"]
        files = [files] if isinstance(files, str) else files
        if not isinstance(files, list) or not files:
            raise ValueError("map_file must be a name or nonempty list")
        paths = []
        for name in files:
            if not isinstance(name, str) or not name:
                raise ValueError("map_file names must be nonempty strings")
            path = (maps / data["map_path"] / name).resolve()
            if not path.is_relative_to(maps) or not path.is_file():
                raise ValueError("missing or unsafe map source: " + name)
            paths.append(path)
        return paths
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise MapError("%s: %s" % (entry["id"], error)) from error


def load_map(entry):
    """Stack files along z, with separate dictionaries, just as the map loader does."""
    keys, levels, offset = {}, {}, 0
    for index, source in enumerate(map_files(entry)):
        source_keys, source_levels = parse_dmm(source.read_text(encoding="utf-8"))
        keys.update({(index, key): paths for key, paths in source_keys.items()})
        for z, level in source_levels.items():
            levels[offset + z] = {position: (index, key) for position, key in level.items()}
        offset += max(source_levels)
    return keys, levels


def main(selected):
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    (ROOT / PREVIEWS).mkdir(parents=True, exist_ok=True)
    for entry in catalog["maps"]:
        if selected and entry["id"] not in selected:
            continue
        if entry["build"] == "babylon":
            print("babylon: use render_babylon_preview.py for the atlas close-up")
            continue
        keys, levels = load_map(entry)
        z = busiest_level(keys, levels)
        target = "%s/%s.png" % (PREVIEWS, entry["id"])
        creative_plane = entry.get("group") == "creative_plane"
        (ROOT / target).write_bytes(png(render(keys, levels[z], creative_plane)))
        entry["preview"] = target
        print("%s: %s (z%d)" % (entry["id"], target, z))
    CATALOG.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main(set(sys.argv[1:]))
