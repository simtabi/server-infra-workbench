"""Spinner, bar, ETA and elapsed time on stderr, so stdout (tables, JSON) stays parseable.

Same switches as the shell tools (src/shell/lib/progress.sh) and the PHP core (Console\\Progress):
VSW_PROGRESS=auto|tty|plain|off (auto animates on a terminal, prints plain lines otherwise), VSW_QUIET=1, NO_COLOR.

    progress = Progress.detect()
    with progress.task("DigitalOcean sizes"):
        sizes = client.get("sizes")
    for i, row in enumerate(rows, 1):
        progress.bar(i, len(rows), "rows")
"""

from __future__ import annotations

import os
import sys
import threading
import time
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from typing import TextIO

TTY, PLAIN, OFF = "tty", "plain", "off"
_FRAMES = "|/-\\"


def duration(seconds: float) -> str:
    """m:ss, or h:mm:ss from an hour."""
    s = max(0, int(seconds))
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


def eta(elapsed: float, done: int, total: int) -> int | None:
    """Remaining seconds at the average rate so far; None before the first item or after the last."""
    return int(elapsed * (total - done) // done) if 0 < done < total else None


class Progress:
    def __init__(self, stream: TextIO, mode: str, color: bool = False, clock: Callable[[], float] = time.monotonic) -> None:
        if mode not in (TTY, PLAIN, OFF):
            raise ValueError(f"mode must be tty, plain or off, got {mode!r}")
        self.stream, self.mode, self.color, self.clock = stream, mode, color, clock
        self._bar_t0: float | None = None
        self._bar_decile = -1

    @classmethod
    def detect(cls, stream: TextIO | None = None, env: Mapping[str, str] | None = None, isatty: bool | None = None) -> Progress:
        stream = stream or sys.stderr
        env = os.environ if env is None else env
        tty = stream.isatty() if isatty is None else isatty
        if env.get("VSW_QUIET") == "1":
            mode = OFF
        elif env.get("VSW_PROGRESS") in (TTY, PLAIN, OFF):
            mode = env["VSW_PROGRESS"]
        else:
            mode = TTY if tty and env.get("TERM", "dumb") != "dumb" else PLAIN
        return cls(stream, mode, color=mode == TTY and not env.get("NO_COLOR"))

    @classmethod
    def off(cls) -> Progress:
        return cls(sys.stderr, OFF)

    def _w(self, text: str) -> None:
        self.stream.write(text)
        self.stream.flush()

    def _paint(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.color else text

    def finished(self, label: str, seconds: float, ok: bool = True) -> None:
        if self.mode == OFF:
            return
        word = self._paint("32", "done") if ok else self._paint("31", "FAIL")
        self._w(("\r\033[K" if self.mode == TTY else "") + f"  {word}  {label}  ({duration(seconds)})\n")

    @contextmanager
    def task(self, label: str) -> Iterator[None]:
        """Spinner + elapsed around a block (a thread animates it on a terminal); FAIL and re-raise on error."""
        t0, stop = self.clock(), threading.Event()
        spinner: threading.Thread | None = None
        if self.mode == PLAIN:
            self._w(f"  ..    {label}\n")
        elif self.mode == TTY:
            def spin() -> None:
                i = 0
                while not stop.wait(0.2 if i else 0):
                    self._w(f"\r  {_FRAMES[i % 4]} {label}  {duration(self.clock() - t0)} ")
                    i += 1
            spinner = threading.Thread(target=spin, daemon=True)
            spinner.start()
        try:
            yield
        except BaseException:
            stop.set()
            if spinner:
                spinner.join()
            self.finished(label, self.clock() - t0, ok=False)
            raise
        stop.set()
        if spinner:
            spinner.join()
        self.finished(label, self.clock() - t0)

    def bar(self, done: int, total: int, label: str = "") -> None:
        if self.mode == OFF or total <= 0:
            return
        now = self.clock()
        if self._bar_t0 is None or done == 0:
            self._bar_t0, self._bar_decile = now, -1
        done = min(max(0, done), total)
        pct, el = done * 100 // total, now - self._bar_t0
        left = eta(el, done, total)
        tail = f"{pct:3d}% {done}/{total} {label}  {duration(el)}" + ("" if left is None else f" eta {duration(left)}")
        if self.mode == TTY:
            fill = done * 24 // total
            self._w(f"\r  [{'#' * fill}{'-' * (24 - fill)}] {tail}\033[K" + ("\n" if done == total else ""))
        elif pct // 10 != self._bar_decile:
            self._bar_decile = pct // 10
            self._w(f"  {tail}\n")
