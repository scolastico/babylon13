"""Guards against changing a shared list through an alias.

A variable that is assigned a shared list (a `var/static/list` or a `GLOB` list) and then changed
in place (+=, -=, |=, &=, Add, Cut, Remove, Insert, Swap, Splice, an index assignment or a LAZY*
list macro) by the same proc, the same type or a subtype, or through another object
(other.allowed |= ...), changes the list for every other user too. Assign a `.Copy()`
instead. The scan is a heuristic over the whole tree (code/ and every modular_* folder): the cases
it finds that are intended are allowed below with their reason.
"""
from collections import defaultdict
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Marks a change through another object of the type that follows.
THROUGH = "through:"
# The LAZY* macros that change their list argument in place.
LAZY_CHANGE = r"\bLAZY(?:ADD|OR|REMOVE|SET|INSERT|ADDASSOC|ADDASSOCLIST|REMOVEASSOC|CLEARLIST|DISTINCTADD|ORASSOCLIST)\("
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
    ("code/game/objects/items/stacks/stack_recipe.dm", "recipes"): "assigns New()'s argument, not a shared list",
}

# (file, variable) of changes through another object that are reviewed: they never reach a shared list.
ALLOWED_THROUGH = {
    ("code/modules/mod/mod_theme.dm", "allowed"): "a MOD chestplate's own allowed list (no type aliases one for MOD parts)",
    ("code/modules/mod/modules/modules_security.dm", "allowed"): "a MOD chestplate's own allowed list (no type aliases one for MOD parts)",
}


def scan():
    """(alias file, alias line, variable, source, change file, change line) of every candidate."""
    statics = set()
    procs = []
    header_line = {}
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
                    header_line[(relative, header.group(2), header.group(1))] = line
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
        arguments = header_line.get((relative, name, type_path), "")
        arguments = arguments[arguments.find("(") + 1:]
        typed_names = {declared: "/" + declared_type for declared_type, declared
                       in re.findall(r"/?((?:obj|mob|datum|atom|turf|area)(?:/\w+)*)/(\w+)", arguments)}
        for number, line in body:
            for declared_type, declared in re.findall(r"\bvar/((?:obj|mob|datum|atom|turf|area)/[\w/]+)/(\w+)", line):
                typed_names[declared] = "/" + declared_type
            match = re.match(r"\s*(var/(?:list/)?|src\.)?(\w+)\s*=\s*(GLOB\.\w+|\w+)\s*(//.*)?$", line)
            if match and (match.group(3).startswith("GLOB.") or match.group(3) in statics):
                # A proc's own variable: only that proc can change it.
                if match.group(1) and match.group(1).startswith("var/"):
                    locals_here.add(match.group(2))
                aliases.append((local_owner if match.group(2) in locals_here else owner, match.group(2), match.group(3), relative, number))
            changed = []
            match = re.match(r"\s*(?:src\.)?(\w+)\s*(?:%s)" % MUTATION, line)
            if match:
                changed.append(match.group(1))
            changed += re.findall(LAZY_CHANGE + r"\s*(?:src\.)?(\w+)\s*[,)]", line)
            for variable in changed:
                changes[variable].append((local_owner if variable in locals_here else owner, relative, number))
            # Through another object (other.allowed |= ...): counted for that object's declared type
            # (a typed local or argument of this proc); an untyped receiver cannot be resolved.
            for receiver, variable in re.findall(r"\b(\w+)\.(\w+)\s*(?:\+=|-=|\|=|&=)", line) + \
                    re.findall(r"\b(\w+)\.(\w+)\.(?:Add|Cut|Remove|Insert|Swap|Splice)\(", line) + \
                    re.findall(LAZY_CHANGE + r"\s*(\w+)\.(\w+)\s*[,)]", line):
                receiver_type = typed_names.get(receiver)
                if receiver_type:
                    changes[variable].append((THROUGH + receiver_type, relative, number))
    found = set()
    for type_path, variable, source, relative, number in aliases:
        for changed_type, changed_file, changed_line in changes.get(variable, []):
            if changed_type.startswith(THROUGH):
                # A proc's own variable is never reached through an object. The receiver may be
                # the aliasing type, a subtype, or a parent type holding one.
                receiver_type = changed_type[len(THROUGH):]
                if ":" in type_path or not (receiver_type == type_path or receiver_type.startswith(type_path + "/")
                                            or type_path.startswith(receiver_type + "/")):
                    continue
                if (changed_file, variable) not in ALLOWED_THROUGH:
                    found.add((relative, number, variable, source, changed_file, changed_line))
            elif changed_type == type_path or changed_type.startswith(type_path + "/"):
                found.add((relative, number, variable, source, changed_file, changed_line))
    return sorted(found)


class SharedListAliasTest(unittest.TestCase):
    def test_no_shared_list_is_changed_through_an_alias(self):
        unexpected = [entry for entry in scan() if (entry[0], entry[2]) not in ALLOWED]
        self.assertEqual(unexpected, [], "assign a .Copy() of the shared list (see the module docstring)")

    def test_the_scan_sees_lazy_macros_and_changes_through_objects(self):
        import tempfile
        global ROOT
        with tempfile.TemporaryDirectory() as temp:
            code = Path(temp) / "code"
            code.mkdir()
            (code / "x.dm").write_text(
                "/obj/thing/Initialize()\n\tallowed = GLOB.shared_allowed\n\tfoo = GLOB.shared_foo\n"
                "/obj/thing/sub/Initialize()\n\tLAZYADD(foo, 1)\n"
                "/proc/poke(obj/thing/other)\n\tother.allowed |= list(1)\n")
            real, ROOT = ROOT, Path(temp)
            try:
                found = {(entry[2], entry[4]) for entry in scan()}
            finally:
                ROOT = real
        self.assertEqual(found, {("foo", "code/x.dm"), ("allowed", "code/x.dm")})

    def test_every_allowed_case_still_exists(self):
        """An allowed case that is gone (fixed or moved) is removed from ALLOWED."""
        present = {(entry[0], entry[2]) for entry in scan()}
        self.assertEqual(sorted(set(ALLOWED) - present), [])


if __name__ == "__main__":
    unittest.main()
