import io
import unittest
from contextlib import redirect_stderr

from server_infra_workbench import compat
from server_infra_workbench.progress import OFF, PLAIN, Progress


class CompatTest(unittest.TestCase):
    """The rename (ADR 0014): SIW_* settings, pre-rename VSW_* names as a fallback with a notice."""

    def test_new_name_wins_old_name_is_the_fallback(self):
        self.assertEqual(compat.get("SIW_ROOT", {"SIW_ROOT": "/n", "VSW_ROOT": "/o"}), "/n")
        self.assertEqual(compat.get("SIW_ROOT", {"VSW_ROOT": "/o"}), "/o")
        self.assertEqual(compat.get("SIW_ROOT", {"SIW_ROOT": "", "VSW_ROOT": "/o"}), "/o")
        self.assertIsNone(compat.get("SIW_ROOT", {}))
        self.assertIsNone(compat.get("HOME", {"VSW_HOME": "/x"}))

    def test_progress_reads_old_names(self):
        s = io.StringIO()
        self.assertEqual(Progress.detect(s, {"VSW_QUIET": "1"}, True).mode, OFF)
        self.assertEqual(
            Progress.detect(s, {"SIW_PROGRESS": "plain", "VSW_PROGRESS": "off", "TERM": "xterm"}, True).mode,
            PLAIN,
        )

    def test_notice_names_each_old_variable(self):
        self.assertEqual(
            compat.legacy_in_use({"VSW_QUIET": "1", "VSW_EMPTY": "", "SIW_X": "1"}), ["VSW_QUIET"]
        )
        self.assertIn("use SIW_QUIET", compat.notices({"VSW_QUIET": "1"})[0])

    def test_cli_prints_the_notice_on_stderr(self):
        from unittest import mock

        from server_infra_workbench.cli import main

        err = io.StringIO()
        with mock.patch.dict("os.environ", {"VSW_QUIET": "1"}), redirect_stderr(err):
            with self.assertRaises(SystemExit):
                main(["--version"])
        self.assertIn("VSW_QUIET is deprecated, use SIW_QUIET", err.getvalue())


if __name__ == "__main__":
    unittest.main()
