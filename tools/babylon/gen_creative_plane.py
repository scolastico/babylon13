#!/usr/bin/env python3
"""Generates the Creative Plane maps (spec 5.2): _maps/babylon/creative_plane_{s,m,l}.dmm + .json.

Each map is one 255x255 station level: a square iron floor (S 50x50, M 100x100, L 200x200)
centred in space, closed by a ring of indestructible reinforced walls so its air can never vent
(the floor relies on its initial air). The floor area is /area/station/babylon/creative_plane
(modular_babylon/code/creative/plane.dm): fullbright, standard gravity, powered by one APC.
Along the south edge (local coordinates: u east, v north, 0,0 = the floor's south-west tile):

- utility room (south-west corner, walls u 0..8, v 1..7, glass door south; area ".../utilities"
  with its own APC, together with the SMES corner): a creative O2 source and a creative N2
  source canister on connector ports feed an air mixer, whose supply line runs two vents; two
  scrubbers drain into a creative void canister. Ordinary pipes, all on layer 3. A plaque on
  its south wall explains the machines.
- creative SMES (source, full charge) at u 10 with an unwired terminal north of it; its cable
  joins the main cable along the south edge (catwalk floor) and a spine up the middle column.
- the plane's APC on the south wall, on the main cable.
- the spawn pad (dark floor, 5x5, centred on the spine): observer start in the middle, eight
  late-join points around it and eight Assistant start points on its rim.

Output is TGM and fully deterministic: rerunning the script gives byte-identical files (the
test test_creative_plane.py checks the committed maps against it). Afterwards the lobby
previews are rendered with render_map_previews.py.

    python3 tools/babylon/gen_creative_plane.py          # write the maps, json and previews
    python3 tools/babylon/gen_creative_plane.py --check  # exit 1 if the committed files differ
"""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
MAPS = ROOT / "_maps/babylon"
WORLD = 255
SIZES = {"s": 50, "m": 100, "l": 200}
TGM_HEADER = "//MAP CONVERTED BY dmm2tgm.py THIS HEADER COMMENT PREVENTS RECONVERSION, DO NOT REMOVE"

SPACE_AREA = "/area/space"
SPACE = "/turf/open/space/basic"
AREA = "/area/station/babylon/creative_plane"
UTILITY_AREA = "/area/station/babylon/creative_plane/utilities"
FLOOR = "/turf/open/floor/iron"
CATWALK = "/turf/open/floor/catwalk_floor/iron"
PAD = "/turf/open/floor/iron/dark"
OUTER_WALL = "/turf/closed/indestructible/reinforced"
ROOM_WALL = "/turf/closed/wall"

NORTH, SOUTH, EAST, WEST = 1, 2, 4, 8

CABLE = "/obj/structure/cable"
SMES = '/obj/machinery/power/smes/babylon_creative{\n\tcharge = 100000000;\n\tcreative_mode = "source";\n\toutput_level = 1000000\n\t}'
TERMINAL = "/obj/machinery/power/terminal{\n\tdir = %d\n\t}" % SOUTH
APC = "/obj/machinery/power/apc/auto_name/directional/south"
O2_CANISTER = ('/obj/machinery/portable_atmospherics/canister/babylon_creative{\n\tcreative_gas = /datum/gas/oxygen;\n'
               '\tcreative_mode = "source";\n\tcreative_pressure = 4500\n\t}')
N2_CANISTER = ('/obj/machinery/portable_atmospherics/canister/babylon_creative/nitrogen{\n\tcreative_gas = /datum/gas/nitrogen;\n'
               '\tcreative_mode = "source";\n\tcreative_pressure = 4500\n\t}')
VOID_CANISTER = '/obj/machinery/portable_atmospherics/canister/babylon_creative/void{\n\tcreative_mode = "void"\n\t}'
MIXER = "/obj/machinery/atmospherics/components/trinary/mixer/airmix{\n\tdir = %d\n\t}" % EAST
SUPPLY = "/obj/machinery/atmospherics/pipe/smart/manifold4w/supply/visible"
SCRUBBERS = "/obj/machinery/atmospherics/pipe/smart/manifold4w/scrubbers/visible"
DOOR = '/obj/machinery/door/airlock/public/glass{\n\tname = "Utilities"\n\t}'
PLAQUE = ('/obj/structure/plaque/static_plaque{\n\tdesc = "Power and air for this plane: a creative SMES (source) feeds the '
          'main cable; creative oxygen and nitrogen canisters feed the vents through an air mixer, and the scrubbers drain '
          'into a creative void canister. In Creative worlds, Ctrl + Shift + click a creative machine to configure it.";'
          '\n\tname = "Creative utilities"\n\t}')
AIR_ALARM = "/obj/machinery/airalarm/directional/north"
LATEJOIN = "/obj/effect/landmark/latejoin"
ASSISTANT = "/obj/effect/landmark/start/assistant"
OBSERVER = "/obj/effect/landmark/observer_start"


def directed(path, direction):
    return "%s{\n\tdir = %d\n\t}" % (path, direction)


def port(direction):
    return directed("/obj/machinery/atmospherics/components/unary/portables_connector/visible", direction)


def vent(direction):
    return directed("/obj/machinery/atmospherics/components/unary/vent_pump/on", direction)


def scrubber(direction):
    return directed("/obj/machinery/atmospherics/components/unary/vent_scrubber/on", direction)


def floor_origin(size):
    """The world coordinates (1-based) of the floor's south-west tile: the floor is centred."""
    start = (WORLD - size) // 2 + 1
    return start, start


def layout(size):
    """{(u, v): [turf, [objects], area]} for the floor square and its wall ring (u, v in -1..size)."""
    tiles = {}
    for u in range(-1, size + 1):
        for v in range(-1, size + 1):
            edge = u in (-1, size) or v in (-1, size)
            tiles[(u, v)] = [OUTER_WALL if edge else FLOOR, [], AREA]

    def put(u, v, *objects, turf=None, area=None):
        tile = tiles[(u, v)]
        if turf:
            tile[0] = turf
        if area:
            tile[2] = area
        tile[1].extend(objects)

    middle = size // 2
    # Main power: the south edge and the middle column, on catwalk floor (cables visible).
    for u in range(size):
        put(u, 0, CABLE, turf=CATWALK)
    for v in range(1, size):
        put(middle, v, CABLE, turf=CATWALK)
    put(10, 1, SMES, CABLE, area=UTILITY_AREA)
    put(10, 2, TERMINAL, area=UTILITY_AREA)
    put(12, 0, APC)

    # Utility room: walls u 0..8, v 1..7; interior u 1..7, v 2..6 (local a = u - 1, b = v - 2).
    for u in range(0, 9):
        for v in range(1, 8):
            put(u, v, area=UTILITY_AREA)
            if u in (0, 8) or v in (1, 7):
                put(u, v, turf=ROOM_WALL)
    # Door south onto the main cable; the room's APC is fed through it.
    put(4, 1, DOOR, CABLE, turf=FLOOR)
    put(4, 2, CABLE)
    put(5, 2, APC, CABLE)
    put(6, 1, PLAQUE)

    def room(a, b, *objects):
        put(1 + a, 2 + b, *objects)

    # The air mixer takes N2 from the west (node 1), O2 from the south (node 2), outputs east.
    room(0, 1, port(EAST), N2_CANISTER)
    room(1, 0, port(NORTH), O2_CANISTER)
    room(1, 1, MIXER)
    for a in range(2, 6):
        room(a, 1, SUPPLY)
    room(3, 2, vent(SOUTH))
    room(5, 2, vent(SOUTH))
    for a in range(2, 6):
        room(a, 3, SCRUBBERS)
    room(3, 4, scrubber(SOUTH))
    room(5, 4, scrubber(SOUTH))
    room(6, 3, port(WEST), VOID_CANISTER)
    room(0, 4, AIR_ALARM)

    # Spawn pad: 5x5 dark floor centred on the spine, v 2..6.
    centre = (middle, 4)
    for du in range(-2, 3):
        for dv in range(-2, 3):
            position = (centre[0] + du, centre[1] + dv)
            put(*position, turf=PAD)
            if (du, dv) == (0, 0):
                put(*position, OBSERVER)
            elif max(abs(du), abs(dv)) == 1:
                put(*position, LATEJOIN)
            elif abs(du) in (0, 2) and abs(dv) in (0, 2):
                put(*position, ASSISTANT)
    return tiles


def tile_text(turf, objects, area):
    # Landmarks and helpers first, then machines, as tg's mapping tools order them loosely;
    # the order only has to be stable.
    return ",\n".join(list(objects) + [turf, area])


def key_name(index):
    letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    name = ""
    for _ in range(3):
        name = letters[index % 52] + name
        index //= 52
    return name


def generate(size):
    """The TGM text of a Creative Plane with a size x size floor."""
    x0, y0 = floor_origin(size)
    tiles = layout(size)
    contents = {}
    grid = {}
    for x in range(1, WORLD + 1):
        for y in range(1, WORLD + 1):
            tile = tiles.get((x - x0, y - y0))
            text = tile_text(tile[0], tile[1], tile[2]) if tile else tile_text(SPACE, [], SPACE_AREA)
            grid[(x, y)] = text
            contents.setdefault(text, None)
    # Space first (key aaa), then everything else sorted: stable keys across runs.
    space = tile_text(SPACE, [], SPACE_AREA)
    ordered = [space] + sorted(text for text in contents if text != space)
    keys = {text: key_name(index) for index, text in enumerate(ordered)}
    lines = [TGM_HEADER]
    for text in ordered:
        lines.append('"%s" = (\n%s)' % (keys[text], text))
    for x in range(1, WORLD + 1):
        lines.append("")
        column = "\n".join(keys[grid[(x, y)]] for y in range(WORLD, 0, -1))
        lines.append('(%d,1,1) = {"\n%s\n"}' % (x, column))
    return "\n".join(lines) + "\n"


def map_config(size_id):
    size = SIZES[size_id]
    config = {
        "version": 1,
        "map_name": "Creative Plane %s" % size_id.upper(),
        "map_path": "babylon",
        "map_file": "creative_plane_%s.dmm" % size_id,
        "comment": "Generated by tools/babylon/gen_creative_plane.py (%dx%d floor). No emergency shuttle dock: "
                   "its round never ends by shuttle (plane.dm refuses calls). No mining level, no space ruins." % (size, size),
        "minetype": "none",
        "space_ruin_levels": 0,
        "allow_custom_shuttles": False,
    }
    return json.dumps(config, indent="\t") + "\n"


def outputs():
    """{path: text} of every generated file."""
    files = {}
    for size_id, size in SIZES.items():
        files[MAPS / ("creative_plane_%s.dmm" % size_id)] = generate(size)
        files[MAPS / ("creative_plane_%s.json" % size_id)] = map_config(size_id)
    return files


def main(arguments):
    files = outputs()
    if "--check" in arguments:
        stale = [str(path.relative_to(ROOT)) for path, text in files.items()
                 if not path.is_file() or path.read_text(encoding="utf-8") != text]
        if stale:
            print("Out of date: %s (run tools/babylon/gen_creative_plane.py)" % ", ".join(stale))
            return 1
        return 0
    for path, text in files.items():
        path.write_text(text, encoding="utf-8")
        print("wrote %s" % path.relative_to(ROOT))
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import render_map_previews
    render_map_previews.main({"creative_plane_" + size_id for size_id in SIZES})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
