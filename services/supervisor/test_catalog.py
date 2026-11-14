import json
from pathlib import Path
import tempfile
import unittest

from catalog import CatalogError, load_catalog, public_catalog

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
        self.assertEqual({k for k, v in catalog.items() if v["multiz"]}, {"icebox", "tramstation", "northstar"})

    def test_station_map_jsons_exist(self):
        for entry in load_catalog(SHIPPED).values():
            if entry["build"] == "station" and entry["group"] == "station":
                self.assertTrue((SHIPPED.parents[1] / entry["map_json"]).is_file(), entry["id"])

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
