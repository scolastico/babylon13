"""Compiles DM environments with DreamMaker and explains the BYOND 516.1686 slot quirk if it shows.

Usage: python3 tools/babylon/build_dme.py babylon.dme [babylon-station.dme ...]

Runs `DreamMaker -DCBT <dme>` for each environment in turn, passes its output through and stops at
the first one that fails. When the output has the signature of the compiler quirk documented in
modular_babylon/UPSTREAM_HOOKS.md ("BYOND 516.1686 slot quirk"): a proc's static variable that is
"invalid", or an "unused_var" warning, it prints the recipe for it.
"""
import re
import subprocess
import sys

QUIRK = re.compile(r"error: \w+: invalid variable|warning \(unused_var\)")
RECIPE = """
Babylon: this may be the BYOND 516.1686 slot quirk. First check the reported variable: a local
that really is never read is an ordinary warning to fix in the code, not the quirk. If it is
plainly used (or a static is "invalid"), it is the quirk: the compiler mishandles whichever
variable lands on one particular slot, and any change that adds or removes a variable can move
it. Treat such a build as possibly MISCOMPILED, not as noise: the same slot is used for code
generation, and a variable that lands on it without a diagnostic can be broken silently. Do not
ship or bisect with it. Add or remove one padding global (babylon_byond_1686_slot_pad_*) in
modular_babylon/code/world_flags.dm for the affected build and compile all four builds again.
See modular_babylon/UPSTREAM_HOOKS.md, "BYOND 516.1686 slot quirk".
"""


def quirk_lines(output):
    """The lines of DreamMaker output that carry the quirk's signature."""
    return [line for line in output.splitlines() if QUIRK.search(line)]


def main(environments):
    status = 0
    for environment in environments:
        # DreamMaker output is not always UTF-8; never fail a build over how its log decodes.
        result = subprocess.run(["DreamMaker", "-DCBT", environment], capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
        output = result.stdout + result.stderr
        sys.stdout.write(output)
        if quirk_lines(output):
            sys.stdout.write(RECIPE)
        if result.returncode:
            status = result.returncode
            break
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
