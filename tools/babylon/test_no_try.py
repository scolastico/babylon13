"""Guards the "no try" rule of the tutorial and creative modules (task-I common rules): in DM an
uncaught runtime or stack_trace() ends only the proc it happens in, while a try unwinds every proc
between the error and itself. A try around a delete, a turf change, a settings restore or a whole
area operation therefore leaves it half done on the first deep stack_trace(). Steps that may fail
are procs of their own that return TRUE at their end (see babylon_area_delete in area_tools.dm).
Tests (testing_*.dm) may still catch, to report a failure as a result.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULES = ["modular_babylon/code/tutorial", "modular_babylon/code/creative"]
TRY = re.compile(r"^\s*try\s*(//.*)?$")


class NoTryTest(unittest.TestCase):
    def test_no_try_outside_tests(self):
        found = []
        for module in MODULES:
            for path in sorted((ROOT / module).glob("*.dm")):
                if path.name.startswith("testing_"):
                    continue
                for number, line in enumerate(path.read_text().splitlines(), 1):
                    if TRY.match(line):
                        found.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
