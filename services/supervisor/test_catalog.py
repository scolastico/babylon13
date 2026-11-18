import json
from pathlib import Path
import tempfile
import shutil
import unittest

from catalog import CatalogError, load_catalog, public_catalog

PLAYABLE = {
    "biodome": True, "blueshift": True, "boxstation": False, "cardinalstation": False,
    "catwalkstation": True, "deltastation": False, "icebox": True, "kilostation": False,
    "metastation": False, "moonstation": True, "nebulastation": True, "northstar": True,
    "ouroboros": True, "pubbystation": False, "tramstation": True, "voidraptor": False,
}
EXCLUDED = {"babylon13", "runtimestation", "runtimestation_minimal", "multiz_debug", "gateway_test"}

SHIPPED = Path(__file__).resolve().parents[2] / "_maps/babylon/catalog.json"


class Catalog(unittest.TestCase):
    def test_catalog_loads_and_ids_unique(self):
        catalog = load_catalog(SHIPPED)
        raw = json.loads(SHIPPED.read_text())["maps"]
        self.assertEqual(len(raw), len(catalog))
        self.assertEqual(catalog["babylon"]["build"], "babylon")
        self.assertIsNone(catalog["babylon"]["map_json"])
        for size in "sml":
            entry = catalog["creative_plane_" + size]
            self.assertEqual((entry["group"], entry["build"]), ("creative_plane", "station"))
            self.assertEqual(entry["map_json"], "babylon/creative_plane_%s.json" % size)
        for name in ("boxstation", "metastation", "deltastation", "icebox", "tramstation",
                     "kilostation", "northstar", "pubbystation"):
            self.assertEqual(catalog[name]["map_json"], name + ".json")
        self.assertEqual({k for k, v in catalog.items() if v["multiz"]}, {name for name, multiz in PLAYABLE.items() if multiz})

    def test_complete_playable_station_inventory(self):
        catalog = load_catalog(SHIPPED)
        stations = {key: entry for key, entry in catalog.items() if entry["group"] == "station"}
        self.assertEqual(set(stations), set(PLAYABLE))
        # A newly shipped config must be classified, rather than silently omitted.
        self.assertEqual({p.stem for p in SHIPPED.parents[1].glob("*.json")}, set(PLAYABLE) | EXCLUDED)
        self.assertTrue(EXCLUDED.isdisjoint(catalog))
        for name, multiz in PLAYABLE.items():
            with self.subTest(name):
                entry = stations[name]
                self.assertEqual(entry["build"], "station")
                self.assertEqual(entry["map_json"], name + ".json")
                self.assertEqual(entry["multiz"], multiz)
                config = json.loads((SHIPPED.parents[1] / entry["map_json"]).read_text())
                self.assertEqual(len(config.get("traits", [{}])) > 1, multiz)
                files = config["map_file"]
                for filename in files if isinstance(files, list) else [files]:
                    self.assertTrue((SHIPPED.parents[1] / config["map_path"] / filename).is_file())

    def test_station_map_jsons_exist(self):
        for entry in load_catalog(SHIPPED).values():
            if entry["build"] == "station":
                self.assertTrue((SHIPPED.parents[1] / entry["map_json"]).is_file(), entry["id"])

    def test_every_station_prepares_its_exact_config_for_automapper_selection(self):
        from supervisor import Driver, Denied
        driver = Driver({"map_catalog": str(SHIPPED)})
        for name in PLAYABLE:
            with self.subTest(name), tempfile.TemporaryDirectory() as temp:
                entry = driver.catalog_entry(name)
                self.assertEqual(driver.build_of({"map": name}), "station")
                root = Path(temp)
                (root / "_maps").mkdir()
                source = SHIPPED.parents[1] / entry["map_json"]
                shutil.copy2(source, root / "_maps" / entry["map_json"])
                driver.prepare_station({"map": name}, root, entry, None)
                # In particular preserve case-sensitive map_file names and traits.
                # Automapper required_map matching uses these original filenames.
                self.assertEqual((root / "data/next_map.json").read_bytes(), source.read_bytes())
        for name in EXCLUDED:
            with self.subTest(name), self.assertRaises(Denied):
                driver.catalog_entry(name)
        self.assertEqual(driver.build_of({"map": "babylon"}), "babylon")

    def test_public_catalog_hides_paths(self):
        public = public_catalog(load_catalog(SHIPPED))
        self.assertEqual([m["id"] for m in public], list(load_catalog(SHIPPED)))
        for entry in public:
            self.assertNotIn("map_json", entry)
            self.assertEqual(set(entry), {"id", "name", "description", "group", "size", "build", "preview", "multiz"})

    def test_malformed_catalogs_are_rejected(self):
        good = json.loads(SHIPPED.read_text())["maps"]
        station = dict(good[1])
        cases = {
            "not json": "{",
            "no list": json.dumps({"maps": {}}),
            "duplicate": json.dumps({"maps": good + [good[0]]}),
            "no babylon": json.dumps({"maps": good[1:]}),
            "escaping path": json.dumps({"maps": good + [dict(station, id="x", map_json="../x.json")]}),
            "absolute path": json.dumps({"maps": good + [dict(station, id="x", map_json="/etc/x.json")]}),
            "bad build": json.dumps({"maps": good + [dict(station, id="x", build="other")]}),
            "missing key": json.dumps({"maps": good + [{"id": "x"}]}),
            "truthy multiz": json.dumps({"maps": good + [dict(station, id="x", multiz=1)]}),
        }
        for label, text in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "catalog.json"
                path.write_text(text)
                with self.assertRaises(CatalogError):
                    load_catalog(path)
        with self.assertRaises(CatalogError):
            load_catalog(Path("/nonexistent/catalog.json"))


if __name__ == "__main__":
    unittest.main()
