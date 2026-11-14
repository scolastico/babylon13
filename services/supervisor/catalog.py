"""Map catalog: which maps a world can be created on, and which build runs them."""
import json
from pathlib import Path
import re

BUILDS = ("babylon", "station")
ENTRY_KEYS = ("id", "name", "description", "group", "size", "build", "map_json", "preview", "multiz")
# Fields the lobby may see; map_json is a server-side path.
PUBLIC_KEYS = ("id", "name", "description", "group", "size", "build", "preview", "multiz")


class CatalogError(ValueError):
    pass


def _entry(raw, index):
    where = "map catalog entry %d" % index
    if not isinstance(raw, dict):
        raise CatalogError(where + " must be an object")
    if set(raw) != set(ENTRY_KEYS):
        raise CatalogError("%s must have exactly the keys %s" % (where, ", ".join(ENTRY_KEYS)))
    entry = dict(raw)
    if not isinstance(entry["id"], str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", entry["id"]):
        raise CatalogError(where + " has an invalid id")
    where = "map catalog entry " + entry["id"]
    for key in ("name", "description", "group"):
        if not isinstance(entry[key], str) or not entry[key].strip():
            raise CatalogError("%s needs a nonempty %s" % (where, key))
    for key in ("size", "preview"):
        if entry[key] is not None and (not isinstance(entry[key], str) or not entry[key].strip()):
            raise CatalogError("%s: %s must be a string or null" % (where, key))
    if entry["build"] not in BUILDS:
        raise CatalogError("%s has an unknown build" % where)
    if type(entry["multiz"]) is not bool:
        raise CatalogError(where + ": multiz must be true or false")
    path = entry["map_json"]
    if entry["build"] == "babylon":
        if path is not None:
            raise CatalogError(where + ": a babylon map has no map_json")
    else:
        if not isinstance(path, str) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.json", path) \
                or ".." in Path(path).parts:
            raise CatalogError(where + ": map_json must be a relative .json path inside _maps")
    return entry


def load_catalog(path):
    """Catalog entries by id, in file order. A missing or malformed file raises CatalogError."""
    try:
        document = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CatalogError("Cannot read the map catalog %s: %s" % (path, error)) from None
    if not isinstance(document, dict) or not isinstance(document.get("maps"), list):
        raise CatalogError("The map catalog must be an object with a \"maps\" list")
    catalog = {}
    for index, raw in enumerate(document["maps"]):
        entry = _entry(raw, index)
        if entry["id"] in catalog:
            raise CatalogError("Duplicate map id " + entry["id"])
        catalog[entry["id"]] = entry
    if "babylon" not in catalog:
        raise CatalogError("The map catalog must contain the babylon map")
    return catalog


def public_catalog(catalog):
    return [{key: entry[key] for key in PUBLIC_KEYS} for entry in catalog.values()]
