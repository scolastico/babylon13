"""Guards against changing a shared list through an alias.

A variable that is assigned a shared list (a `var/static/list` or a `GLOB` list) and then changed
in place (+=, -=, |=, &=, Add, Cut, Remove, Insert, Swap, Splice, or an index assignment) by the
same proc, the same type or a subtype changes the list for every other user too. Assign a `.Copy()`
instead. The scan is a heuristic over the whole tree (code/ and every modular_* folder): the cases
it finds that are intended are allowed below with their reason.
"""
from collections import defaultdict
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
MUTATION = r"(\+=|-=|\|=|&=|\^=)|\.(Add|Cut|Remove|Insert|Swap|Splice)\(|\[[^\]]+\]\s*=(?!=)"

# (file, variable) => why changing the shared list there is intended or harmless.
ALLOWED = {
    ("code/controllers/subsystem/lighting.dm", "queue"): "processes the subsystem's own queue in place",
    ("code/datums/components/listen_and_repeat.dm", "speaker_sound"): "only the freshly made list is changed",
    ("code/datums/mapgen/CaveGenerator.dm", "weighted_megafauna_spawn_list"): "one Bubblegum per round: removed from the shared list on purpose",
    ("code/datums/mapgen/biomes/_biome.dm", "megafauna_types"): "one Bubblegum per round: removed from the shared list on purpose",
    ("code/game/machinery/telecomms/machines/message_server.dm", "decryptkey"): "text, not a list",
    ("code/modules/admin/verbs/ghost_pool_protection.dm", "new_role_flags"): "a number, not a list",
    ("code/modules/fishing/sources/subtypes/fishing_portal_machine.dm", "fish_table"): "only the freshly made table is changed",
    ("code/modules/modular_computers/file_system/programs/betting.dm", "options"): "the proc's own argument",
    ("code/modules/reagents/chemistry/holder/ui_data.dm", "ui_reaction_index"): "a number, not a list",
    ("code/modules/reagents/chemistry/machinery/chem_dispenser.dm", "dispensable_reagents"): "Initialize replaces it with a sorted copy (sort_list) before anything changes it",
    ("modular_babylon/code/creative/machines.dm", "answers"): "integration tests consume their answer list",
    ("code/_globalvars/lists/reagents.dm", "reaction_lookup"): "builds the global reaction index on purpose",
    ("code/datums/elements/turf_transparency.dm", "pillars_by_z"): "fills the global cache on purpose",
    ("code/modules/mapping/reader.dm", "fields"): "replaced by a new list before it is changed",
    ("code/modules/mod/mod_activation.dm", "updated_slots"): "a number, not a list",
    ("modular_skyrat/modules/admin/code/localsound.dm", "players"): "replaced by a new list before it is changed",
    ("modular_skyrat/modules/clock_cult/code/items/clockwork_slab.dm", "cogs"): "a number, not a list",
}


def scan():
    """(alias file, alias line, variable, source, change file, change line) of every candidate."""
    statics = set()
    procs = []
    folders = [ROOT / "code"] + sorted(path for path in ROOT.glob("modular_*") if path.is_dir())
    for folder in folders:
        for path in folder.rglob("*.dm"):
            relative = path.relative_to(ROOT).as_posix()
            current = None
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").split("\n"), 1):
                match = re.match(r"\s*var/static/list/(\w+)", line)
                if match:
                    statics.add(match.group(1))
                header = re.match(r"^(/[\w/]+?)/(?:proc/|verb/)?(\w+)\(", line)
                if header:
                    current = (header.group(1), relative, [], header.group(2))
                    procs.append(current)
                    continue
                if line and not line[0].isspace() and not line.startswith("//"):
                    current = None
                    continue
                if current is not None:
                    current[2].append((number, line))
    aliases = []
    changes = defaultdict(list)
    for type_path, relative, body, name in procs:
        # A global proc's variables are its own: only that proc can change them.
        owner = "%s/%s:%s" % (type_path, relative, name) if type_path == "/proc" else type_path
        local_owner = "%s/%s:%s" % (type_path, relative, name)
        locals_here = set()
        for number, line in body:
            match = re.match(r"\s*(var/(?:list/)?|src\.)?(\w+)\s*=\s*(GLOB\.\w+|\w+)\s*(//.*)?$", line)
            if match and (match.group(3).startswith("GLOB.") or match.group(3) in statics):
                # A proc's own variable: only that proc can change it.
                if match.group(1) and match.group(1).startswith("var/"):
                    locals_here.add(match.group(2))
                aliases.append((local_owner if match.group(2) in locals_here else owner, match.group(2), match.group(3), relative, number))
            match = re.match(r"\s*(?:src\.)?(\w+)\s*(?:%s)" % MUTATION, line)
            if match:
                changes[match.group(1)].append((local_owner if match.group(1) in locals_here else owner, relative, number))
    found = set()
    for type_path, variable, source, relative, number in aliases:
        for changed_type, changed_file, changed_line in changes.get(variable, []):
            if changed_type == type_path or changed_type.startswith(type_path + "/"):
                found.add((relative, number, variable, source, changed_file, changed_line))
    return sorted(found)


class SharedListAliasTest(unittest.TestCase):
    def test_no_shared_list_is_changed_through_an_alias(self):
        unexpected = [entry for entry in scan() if (entry[0], entry[2]) not in ALLOWED]
        self.assertEqual(unexpected, [], "assign a .Copy() of the shared list (see the module docstring)")

    def test_every_allowed_case_still_exists(self):
        """An allowed case that is gone (fixed or moved) is removed from ALLOWED."""
        present = {(entry[0], entry[2]) for entry in scan()}
        self.assertEqual(sorted(set(ALLOWED) - present), [])


if __name__ == "__main__":
    unittest.main()
