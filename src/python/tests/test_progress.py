import io
import unittest

from vps_server_workbench.progress import OFF, PLAIN, TTY, Progress, duration, eta


class Clock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


class ProgressTest(unittest.TestCase):
    def test_detect(self):
        s = io.StringIO()
        self.assertEqual(Progress.detect(s, {"VSW_QUIET": "1", "VSW_PROGRESS": "tty"}, True).mode, OFF)
        self.assertEqual(Progress.detect(s, {"VSW_PROGRESS": "plain", "TERM": "xterm"}, True).mode, PLAIN)
        self.assertEqual(Progress.detect(s, {"TERM": "xterm"}, True).mode, TTY)
        self.assertEqual(Progress.detect(s, {"TERM": "dumb"}, True).mode, PLAIN)
        self.assertEqual(Progress.detect(s, {"TERM": "xterm"}, False).mode, PLAIN)
        self.assertFalse(Progress.detect(s, {"TERM": "xterm", "NO_COLOR": "1"}, True).color)
        with self.assertRaises(ValueError):
            Progress(s, "loud")

    def test_duration_eta(self):
        self.assertEqual(duration(125), "2:05")
        self.assertEqual(duration(3601), "1:00:01")
        self.assertEqual(eta(10, 1, 4), 30)
        self.assertIsNone(eta(10, 0, 4))
        self.assertIsNone(eta(10, 4, 4))

    def test_plain_task_and_failure(self):
        s, c = io.StringIO(), Clock()
        p = Progress(s, PLAIN, clock=c)
        with p.task("sizes"):
            c.t += 3
        with self.assertRaises(RuntimeError), p.task("regions"):
            raise RuntimeError("api down")
        out = s.getvalue()
        self.assertIn("  ..    sizes\n", out)
        self.assertIn("done  sizes  (0:03)", out)
        self.assertIn("FAIL  regions", out)
        self.assertNotIn("\r", out)

    def test_tty_task_spins_and_colours(self):
        s = io.StringIO()
        with Progress(s, TTY, color=True).task("fetch"):
            pass
        self.assertIn("\r  | fetch", s.getvalue())
        self.assertIn("\033[32mdone\033[0m  fetch", s.getvalue())

    def test_bars(self):
        s, c = io.StringIO(), Clock()
        p = Progress(s, TTY, clock=c)
        p.bar(0, 4, "x")
        c.t += 10
        p.bar(2, 4, "x")
        self.assertIn("[############------------]  50% 2/4 x  0:10 eta 0:10", s.getvalue())
        s2 = io.StringIO()
        p2 = Progress(s2, PLAIN, clock=c)
        for i in range(41):
            p2.bar(i, 40, "rows")
        self.assertEqual(len(s2.getvalue().splitlines()), 11)

    def test_off_is_silent(self):
        s = io.StringIO()
        p = Progress(s, OFF)
        with p.task("x"):
            p.bar(1, 2)
        self.assertEqual(s.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
