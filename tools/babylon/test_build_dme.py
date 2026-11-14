"""build_dme.py recognises the BYOND 516.1686 slot quirk in DreamMaker output."""
import unittest

import build_dme


class QuirkHint(unittest.TestCase):
    def test_signatures(self):
        output = "\n".join([
            "loading babylon-test.dme",
            "code/modules/antagonists/cult/cult_structure_altar.dm:41:error: altar_items: invalid variable",
            "code/modules/forensics/forensics_helpers.dm:40:warning (unused_var): suspect_gloves: variable defined but not used",
            "babylon-test.dmb - 1 error, 1 warning",
        ])
        self.assertEqual(len(build_dme.quirk_lines(output)), 2)

    def test_clean_build(self):
        self.assertEqual(build_dme.quirk_lines("babylon.dmb - 0 errors, 0 warnings"), [])

    def test_recipe_warns_of_miscompiles_and_real_unused_locals(self):
        self.assertIn("MISCOMPILED", build_dme.RECIPE)
        self.assertIn("really is never read", build_dme.RECIPE)

    def test_undecodable_output_does_not_fail_the_build(self):
        from unittest.mock import patch
        import subprocess
        def fake_run(command, **kwargs):
            self.assertEqual(kwargs.get("errors"), "replace")
            return subprocess.CompletedProcess(command, 0, b"ok \xff".decode("utf-8", "replace"), "")
        with patch("build_dme.subprocess.run", fake_run), patch("sys.stdout"):
            self.assertEqual(build_dme.main(["x.dme"]), 0)

    def test_other_errors_are_not_the_quirk(self):
        self.assertEqual(build_dme.quirk_lines("x.dm:3:error: foo: undefined var"), [])


if __name__ == "__main__":
    unittest.main()
