"""The lobby uses in-page dialogs only: no BYOND system dialogs, no browser popups."""
from pathlib import Path
import re
import unittest

LOBBY = Path(__file__).resolve().parents[2] / "modular_babylon" / "lobby"


class NoNativeDialogs(unittest.TestCase):
    def test_lobby_dm_has_no_alert_or_input(self):
        source = (LOBBY / "lobby.dm").read_text(encoding="utf-8")
        found = [match.group(0) for match in re.finditer(r"\b(alert|input)\s*\(", source)]
        self.assertEqual(found, [], "lobby.dm must use the page's dialogs (lobby.js), not BYOND alert()/input()")

    def test_lobby_scripts_have_no_browser_popups(self):
        for name in ("lobby.js", "loading.js"):
            source = (LOBBY / name).read_text(encoding="utf-8")
            found = [match.group(0) for match in re.finditer(r"\b(alert|confirm|prompt)\s*\(", source)]
            self.assertEqual(found, [], "%s must not open browser popups" % name)


if __name__ == "__main__":
    unittest.main()
