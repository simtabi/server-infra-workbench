import unittest

from vps_server_workbench.envfile import parse


class EnvFileTest(unittest.TestCase):
    def test_parses_plain_quoted_export_and_comments(self):
        text = "# c\nDB_HOST=10.0.0.5\nexport DB_PORT=6432  # pool\nNAME=\"a # b\"\nbad line\n\nE=\n"
        self.assertEqual(parse(text), {"DB_HOST": "10.0.0.5", "DB_PORT": "6432", "NAME": "a # b", "E": ""})

    def test_empty_value_with_inline_comment(self):
        self.assertEqual(parse("A=   # note\nB=x#y\nC=#x\n"), {"A": "", "B": "x#y", "C": "#x"})

    def test_later_keys_win(self):
        self.assertEqual(parse("A=1\nA=2\n"), {"A": "2"})


if __name__ == "__main__":
    unittest.main()
