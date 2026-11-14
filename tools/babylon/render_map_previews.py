"""Renders top-down preview thumbnails of the catalog's station maps for the lobby's map picker.

Pure Python (no PIL): parses the map's .dmm (classic DMM or TGM), colours every tile by its turf
(space, wall, floor, terrain) tinted by its area's department, and writes an RGBA PNG with a
transparent background to _maps/babylon/previews/<id>.png. The catalog entry's "preview" is set
to that path. Output is deterministic, so unchanged maps give byte-identical files.

    python3 tools/babylon/render_map_previews.py            # every station map in the catalog
    python3 tools/babylon/render_map_previews.py icebox     # selected maps

Babylon has no .dmm in the catalog and the Creative Plane maps are generated elsewhere (their
generator runs this script once they exist); entries without a map file are skipped.
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


def render(keys, level):
    """RGBA rows (bytes) of the level cropped to its station, fitted into WIDTH x HEIGHT."""
    colours = {}
    station = []
    for position, key in level.items():
        paths = keys.get(key, ())
        colour = tile_colour(paths)
        if colour is not None:
            colours[position] = colour if len(colour) == 4 else colour + (255,)
            if any(p.startswith("/area/station") for p in paths):
                station.append(position)
    if not colours:
        raise MapError("the level has no visible tiles")
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
        rows.append(bytes(row))
    return rows


def png(rows):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\0" + row for row in rows)
    header = struct.pack(">IIBBBBB", len(rows[0]) // 4, len(rows), 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def map_file(entry):
    """The .dmm of a catalog entry (its tg map json's first map_file), or None."""
    if not entry.get("map_json"):
        return None
    config = ROOT / "_maps" / entry["map_json"]
    if not config.is_file():
        return None
    data = json.loads(config.read_text(encoding="utf-8"))
    files = data.get("map_file")
    name = files[0] if isinstance(files, list) else files
    path = ROOT / data.get("map_path", "") / name if name else None
    if path and not path.is_file():
        path = ROOT / "_maps" / data.get("map_path", "") / name
    return path if path and path.is_file() else None


def main(selected):
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    (ROOT / PREVIEWS).mkdir(parents=True, exist_ok=True)
    for entry in catalog["maps"]:
        if selected and entry["id"] not in selected:
            continue
        source = map_file(entry)
        if source is None:
            print("%s: no map file, skipped" % entry["id"])
            continue
        keys, levels = parse_dmm(source.read_text(encoding="utf-8", errors="replace"))
        z = busiest_level(keys, levels)
        target = "%s/%s.png" % (PREVIEWS, entry["id"])
        (ROOT / target).write_bytes(png(render(keys, levels[z])))
        entry["preview"] = target
        print("%s: %s (z%d)" % (entry["id"], target, z))
    CATALOG.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main(set(sys.argv[1:]))
