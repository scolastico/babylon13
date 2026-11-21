"""JSON or text that reaches a page script goes through lobby_script_json.

json_encode leaves "<", ">" and "&" alone. Embedded raw in an inline <script> (or handed to a
page function), a world name like "</script>" or "<!--<script>" ends or comments out the
script and leaves the page blank. Every DM file under modular_babylon is checked:
- an inline <script> may only interpolate file2text(...) (the shipped scripts) or
  lobby_script_json(...);
- output() to a browser function never carries a bare json_encode(...).
The node test (test_lobby_ui.cjs) checks that the escaping itself survives hostile names.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = re.compile(r"<script[^>]*>(.*?)</script>", re.IGNORECASE)
INTERPOLATION = re.compile(r"\[([^\[\]]*(?:\[[^\[\]]*\][^\[\]]*)*)\]")
ALLOWED = (re.compile(r"^file2text\('[^']+\.js'\)$"), re.compile(r"^lobby_script_json\(.*\)$"))


def problems(source):
    found = []
    for number, line in enumerate(source.splitlines(), 1):
        for block in SCRIPT.finditer(line):
            for value in INTERPOLATION.findall(block.group(1)):
                if not any(rule.match(value) for rule in ALLOWED):
                    found.append("%d: <script> interpolates [%s] without lobby_script_json" % (number, value))
        if re.search(r"\boutput\(", line) and "json_encode(" in line:
            found.append("%d: output() carries json_encode without lobby_script_json" % number)
    return found


class ScriptJson(unittest.TestCase):
    def test_every_script_json_is_escaped(self):
        report = []
        for path in sorted((ROOT / "modular_babylon").rglob("*.dm")):
            for problem in problems(path.read_text(encoding="utf-8", errors="replace")):
                report.append("%s:%s" % (path.relative_to(ROOT), problem))
        self.assertEqual(report, [])

    def test_the_checker_catches_the_old_pattern(self):
        old = 'var/shell = "<script>renderLobby([replacetext(json_encode(json_encode(data)), "</", "<\\\\/")]);</script>"'
        self.assertTrue(problems(old))
        self.assertTrue(problems('src << output(list2params(list(json_encode(data))), "mainwindow.browser:renderLobby")'))
        self.assertFalse(problems('var/x = "<script>renderLobby([lobby_script_json(json_encode(data))]);</script>"'))
        self.assertFalse(problems("<script>[file2text('modular_babylon/lobby/lobby.js')]</script>"))

    def test_helper_escapes_markup_and_line_separators(self):
        source = (ROOT / "modular_babylon/lobby/lobby.dm").read_text(encoding="utf-8")
        helper = source[source.index("/proc/lobby_script_json("):]
        helper = helper[:helper.index("\n/proc/", 1)]
        for escape in ('"<" = "\\\\u003c"', '">" = "\\\\u003e"', '"&" = "\\\\u0026"',
                       'ascii2text(8232)] = "\\\\u2028"', 'ascii2text(8233)] = "\\\\u2029"'):
            self.assertIn(escape, helper)


if __name__ == "__main__":
    unittest.main()
