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

    def test_other_errors_are_not_the_quirk(self):
        self.assertEqual(build_dme.quirk_lines("x.dm:3:error: foo: undefined var"), [])


if __name__ == "__main__":
    unittest.main()
