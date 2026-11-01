import io
import json
import os
import socket
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

from server_infra_workbench.cli import main
from server_infra_workbench.probe import tcp_probe, validate


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen()
        self.port = self.server.getsockname()[1]

    def tearDown(self):
        self.server.close()

    def closed_port(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def test_open_and_closed(self):
        self.assertTrue(tcp_probe("127.0.0.1", self.port, 1).open)
        self.assertFalse(tcp_probe("127.0.0.1", self.closed_port(), 1).open)

    def test_validation(self):
        for host, port in [("", 1), ("a b", 1), ("h;rm", 1), ("h", 0), ("h", 70000), ("h", "x")]:
            with self.assertRaises(ValueError):
                validate(host, port)

    def test_cli_reads_env_file_and_prints_json(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as fh:
            fh.write(f"DB_HOST=127.0.0.1\nDB_PORT={self.port}\n")
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                rc = main(["ping", "--env", fh.name, "--json", "--timeout", "1"])
            self.assertEqual(rc, 0)
            self.assertTrue(json.loads(out.getvalue())["open"])
        finally:
            os.unlink(fh.name)

    def test_cli_rejects_bad_input(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(main(["ping", "bad host", "1"]), 2)
            self.assertEqual(main(["ping"]), 2)
            self.assertEqual(main(["ping", "127.0.0.1", "1", "--timeout", "0"]), 2)


if __name__ == "__main__":
    unittest.main()
