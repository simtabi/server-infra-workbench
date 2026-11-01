import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

from vps_server_workbench import cli
from vps_server_workbench.plan_finder import ApiClient, Config, PlanFinderError, PloiDoPlanFinder

PROVIDERS = [
    {
        "id": 7,
        "label": "DO main",
        "provider": {
            "name": "DigitalOcean",
            "plans": [{"id": "s-1vcpu-1gb"}, {"id": "s-2vcpu-4gb"}],
            "regions": [{"id": "nyc3", "name": "New York 3"}, {"id": "atl1", "name": "Atlanta 1"}],
        },
    }
]
SIZES = [
    {
        "slug": "s-1vcpu-1gb",
        "available": True,
        "vcpus": 1,
        "memory": 1024,
        "disk": 25,
        "transfer": 1,
        "price_monthly": 6,
        "description": "Basic",
        "regions": ["nyc3", "atl1", "sfo3"],
    },
    {
        "slug": "s-2vcpu-4gb",
        "available": True,
        "vcpus": 2,
        "memory": 4096,
        "disk": 80,
        "transfer": 4,
        "price_monthly": 24,
        "description": "Basic",
        "regions": ["nyc3"],
    },
    {
        "slug": "c-4",
        "available": True,
        "vcpus": 4,
        "memory": 8192,
        "disk": 50,
        "transfer": 5,
        "price_monthly": 84,
        "description": "CPU",
        "regions": ["nyc3"],
    },
]
REGIONS = {"nyc3": {"slug": "nyc3", "name": "New York 3"}, "atl1": {"slug": "atl1", "name": "Atlanta 1"}}


class PlanFinderTest(unittest.TestCase):
    def test_only_pairs_both_apis_agree_on(self):
        r = PloiDoPlanFinder().load(PROVIDERS, SIZES, REGIONS).results()
        self.assertEqual(
            {(o.region, o.plan) for o in r},
            {("nyc3", "s-1vcpu-1gb"), ("atl1", "s-1vcpu-1gb"), ("nyc3", "s-2vcpu-4gb")},
        )

    def test_filters_and_render(self):
        f = PloiDoPlanFinder().in_regions("nyc3").min_memory(2048).load(PROVIDERS, SIZES, REGIONS)
        self.assertEqual([o.plan for o in f.results()], ["s-2vcpu-4gb"])
        self.assertIn("| s-2vcpu-4gb | 2 | 4GB |", f.render("markdown"))
        self.assertIn('"plan": "s-2vcpu-4gb"', f.render("json"))

    def test_bad_sort_and_missing_tokens(self):
        with self.assertRaises(PlanFinderError):
            PloiDoPlanFinder().sort_by("nope")
        with self.assertRaises(PlanFinderError):
            PloiDoPlanFinder().fetch()

    def test_env_file_and_flag_precedence(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as fh:
            fh.write("REGIONS=atl1\nMIN_VCPUS=2   # comment\nSORT_BY='memory'\n")
        try:
            c = Config.from_sources(["--env-file", fh.name, "--regions", "nyc3"])
            self.assertEqual(c.list("REGIONS"), ["nyc3"])
            self.assertEqual(c["MIN_VCPUS"], 2)
            self.assertEqual(c["SORT_BY"], "memory")
        finally:
            os.unlink(fh.name)

    def test_api_client_refuses_non_https_before_sending_the_token(self):
        # raised before any request is built, so nothing touches the network
        tok = "t-" + os.urandom(4).hex()
        with self.assertRaisesRegex(PlanFinderError, "non-HTTPS"):
            ApiClient("https://api.example.test/v1", tok).get("http://api.example.test/v1/sizes?page=2")
        with self.assertRaisesRegex(PlanFinderError, "non-HTTPS"):
            ApiClient("http://api.example.test", tok).get("sizes")

    def test_cli_routes_plans_without_tokens_to_an_error(self):
        env = {k: os.environ.pop(k) for k in ("PLOI_API_TOKEN", "DO_API_TOKEN") if k in os.environ}
        try:
            err = io.StringIO()
            with redirect_stderr(err), redirect_stdout(io.StringIO()):
                rc = cli.main(["plans", "--env-file", "/nonexistent.env"])
            self.assertEqual(rc, 1)
            self.assertIn("Both a Ploi and a DigitalOcean API token are required", err.getvalue())
        finally:
            os.environ.update(env)


if __name__ == "__main__":
    unittest.main()
