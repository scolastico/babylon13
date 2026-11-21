"""Compiles DM environments with DreamMaker and explains the BYOND 516.1686 slot quirk if it shows.

Usage: python3 tools/babylon/build_dme.py babylon.dme [babylon-station.dme ...]

Runs `DreamMaker -DCBT <dme>` for each environment in turn, passes its output through and stops at
the first one that fails. When the output has the signature of the compiler quirk documented in
modular_babylon/UPSTREAM_HOOKS.md ("BYOND 516.1686 slot quirk"): a proc's static variable that is
"invalid", or an "unused_var" warning, it prints the recipe for it and fails (exit 1): such a
build may be miscompiled and must not be shipped. Upstream's own tgstation.dme only gets the hint.
A maintainer who checked that the warning is a real unused local can set
BABYLON_ALLOW_SLOT_QUIRK=1 to let the build pass anyway.
"""
import os
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


# Environments whose quirk signature is only reported: upstream's build is not shipped.
INFORMATIONAL = {"tgstation.dme"}
ALLOW_ENV = "BABYLON_ALLOW_SLOT_QUIRK"


def main(environments, environ=None):
    environ = os.environ if environ is None else environ
    allowed = environ.get(ALLOW_ENV) == "1"
    status = 0
    for environment in environments:
        # DreamMaker output is not always UTF-8; never fail a build over how its log decodes.
        result = subprocess.run(["DreamMaker", "-DCBT", environment], capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
        output = result.stdout + result.stderr
        sys.stdout.write(output)
        if result.returncode:
            if quirk_lines(output):
                sys.stdout.write(RECIPE)
            status = result.returncode
            break
        if quirk_lines(output):
            sys.stdout.write(RECIPE)
            if environment in INFORMATIONAL:
                continue
            if allowed:
                sys.stdout.write("Babylon: %s=1 is set; %s passes despite the quirk's signature.\n"
                                 % (ALLOW_ENV, environment))
                continue
            sys.stdout.write("Babylon: %s failed: the slot quirk's signature means it may be miscompiled "
                             "(set %s=1 only after checking it is a real unused local).\n"
                             % (environment, ALLOW_ENV))
            status = 1
            break
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
