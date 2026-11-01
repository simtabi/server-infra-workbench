"""
Ploi + DigitalOcean plan finder (`bin/workbench plans`).

Lists which droplet plans you can create in each DigitalOcean region through
Ploi. Ploi reports the plans and regions it offers for your DigitalOcean
credentials, and DigitalOcean's /v2/sizes reports which region each size runs
in; only plan/region pairs that both agree on are returned.

Use it as a library, with a fluent interface:

    from vps_server_workbench.plan_finder import PloiDoPlanFinder

    print(
        PloiDoPlanFinder()
        .with_tokens(ploi="...", digitalocean="...")
        .in_regions("atl1", "nyc3")
        .min_memory(2048)
        .max_price(30)
        .sort_by("price")
        .fetch()
        .render("markdown")
    )

Or from the command line. Every setting can come from a .env file, an
environment variable, or a --flag (flags win over env, env wins over .env).
Template: config/ploi-do-plan-finder.env.example (copy it outside the repo):

    bin/workbench plans --env-file ~/.config/vps-server-workbench/plans.env \
        --regions atl1,nyc3 --min-memory-mb 2048 --output-format markdown
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass

from vps_server_workbench.progress import Progress


class PlanFinderError(Exception):
    """Raised for configuration and API errors."""


@dataclass(frozen=True)
class PlanOption:
    ploi_credential: str
    ploi_credential_id: int | None
    region: str
    region_name: str
    plan: str
    vcpus: int
    memory_mb: int
    disk_gb: int
    transfer_tb: float
    price_monthly: float
    description: str

    @property
    def memory_label(self) -> str:
        mb = self.memory_mb
        if mb < 1024:
            return f"{mb}MB"
        return f"{mb // 1024}GB" if mb % 1024 == 0 else f"{mb / 1024:.1f}GB"


class ApiClient:
    """Minimal JSON-over-HTTPS client with bearer auth."""

    def __init__(self, base_url: str, token: str, timeout: int = 30):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def get(self, path_or_url: str) -> dict:
        url = path_or_url if path_or_url.startswith("http") else f"{self.base_url}/{path_or_url.lstrip('/')}"
        # the bearer token goes on every request, including pagination links from the API: HTTPS only
        if urllib.parse.urlsplit(url).scheme != "https":
            raise PlanFinderError(f"Refusing a non-HTTPS URL (the API token would be sent in clear): {url}")
        req = urllib.request.Request(  # noqa: S310 - https only, checked above
            url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:  # noqa: S310 - https checked above
                return json.load(resp)
        except urllib.error.HTTPError as e:
            raise PlanFinderError(
                f"{url} returned HTTP {e.code}: {e.read().decode(errors='replace')[:300]}"
            ) from e
        except urllib.error.URLError as e:
            raise PlanFinderError(f"Could not reach {url}: {e.reason}") from e


class PloiDoPlanFinder:
    SORT_KEYS = {"price": "price_monthly", "memory": "memory_mb", "vcpus": "vcpus", "plan": "plan"}
    FORMATS = ("table", "markdown", "csv", "json")

    def __init__(self):
        self._ploi_token = ""
        self._do_token = ""
        self._ploi_url = "https://ploi.io/api"
        self._do_url = "https://api.digitalocean.com/v2"
        self._timeout = 30
        self._provider = "digitalocean"
        self._credential_id: str = ""
        self._regions: set[str] = set()
        self._excluded: set[str] = set()
        self._plan_filter = ""
        self._min_vcpus = 0
        self._max_vcpus = 0
        self._min_memory = 0
        self._max_memory = 0
        self._max_price = 0.0
        self._sort = "price"
        self._results: list[PlanOption] = []

    # ------------------------------------------------------------ configuration
    def with_tokens(self, ploi: str, digitalocean: str) -> PloiDoPlanFinder:
        self._ploi_token, self._do_token = ploi, digitalocean
        return self

    def with_endpoints(self, ploi: str | None = None, digitalocean: str | None = None) -> PloiDoPlanFinder:
        self._ploi_url = ploi or self._ploi_url
        self._do_url = digitalocean or self._do_url
        return self

    def timeout(self, seconds: int) -> PloiDoPlanFinder:
        self._timeout = seconds
        return self

    def provider(self, name_contains: str) -> PloiDoPlanFinder:
        self._provider = name_contains
        return self

    def credential(self, credential_id: int | str | None) -> PloiDoPlanFinder:
        self._credential_id = str(credential_id or "")
        return self

    def in_regions(self, *slugs: str) -> PloiDoPlanFinder:
        self._regions |= {s.strip() for s in slugs if s and s.strip()}
        return self

    def excluding_regions(self, *slugs: str) -> PloiDoPlanFinder:
        self._excluded |= {s.strip() for s in slugs if s and s.strip()}
        return self

    def plans_matching(self, text: str) -> PloiDoPlanFinder:
        self._plan_filter = text or ""
        return self

    def min_vcpus(self, n: int) -> PloiDoPlanFinder:
        self._min_vcpus = n
        return self

    def max_vcpus(self, n: int) -> PloiDoPlanFinder:
        self._max_vcpus = n
        return self

    def min_memory(self, mb: int) -> PloiDoPlanFinder:
        self._min_memory = mb
        return self

    def max_memory(self, mb: int) -> PloiDoPlanFinder:
        self._max_memory = mb
        return self

    def max_price(self, usd_per_month: float) -> PloiDoPlanFinder:
        self._max_price = usd_per_month
        return self

    def sort_by(self, key: str) -> PloiDoPlanFinder:
        if key not in self.SORT_KEYS:
            raise PlanFinderError(f"sort_by must be one of {', '.join(self.SORT_KEYS)}")
        self._sort = key
        return self

    # ------------------------------------------------------------ fetching
    def fetch(self, progress: Progress | None = None) -> PloiDoPlanFinder:
        if not self._ploi_token or not self._do_token:
            raise PlanFinderError("Both a Ploi and a DigitalOcean API token are required.")
        progress = progress or Progress.off()
        ploi = ApiClient(self._ploi_url, self._ploi_token, self._timeout)
        do = ApiClient(self._do_url, self._do_token, self._timeout)

        with progress.task("Ploi server providers"):
            providers = self._ploi_providers(ploi)
        if not providers:
            raise PlanFinderError(f"No Ploi provider matching '{self._provider}' found.")
        with progress.task("DigitalOcean sizes"):
            sizes = self._do_sizes(do)
        with progress.task("DigitalOcean regions"):
            regions = self._do_regions(do)
        return self.load(providers, sizes, regions)

    def load(self, providers: list[dict], sizes: list[dict], regions: dict[str, dict]) -> PloiDoPlanFinder:
        """Build results from raw API data (handy for tests or cached responses)."""
        self._results = [opt for prov in providers for opt in self._combine(prov, sizes, regions)]
        key = self.SORT_KEYS[self._sort]
        self._results.sort(key=lambda o: (o.region, getattr(o, key), o.plan))
        return self

    def _ploi_providers(self, client: ApiClient) -> list[dict]:
        want = self._provider.lower().replace(" ", "")
        found, url = [], "user/server-providers"
        while url:
            page = client.get(url)
            for p in page.get("data", []):
                name = (p.get("provider", {}).get("name") or p.get("name") or "").lower().replace(" ", "")
                if want in name and (not self._credential_id or str(p.get("id")) == self._credential_id):
                    found.append(p)
            url = (page.get("links") or {}).get("next")
        return found

    @staticmethod
    def _do_sizes(client: ApiClient) -> list[dict]:
        sizes, url = [], "sizes?per_page=200"
        while url:
            page = client.get(url)
            sizes += page.get("sizes", [])
            url = ((page.get("links") or {}).get("pages") or {}).get("next")
        return sizes

    @staticmethod
    def _do_regions(client: ApiClient) -> dict[str, dict]:
        return {r["slug"]: r for r in client.get("regions?per_page=200").get("regions", [])}

    def _size_passes(self, s: dict, ploi_plans: set[str]) -> bool:
        cpu, mem, price = s.get("vcpus", 0), s.get("memory", 0), s.get("price_monthly") or 0
        return (
            s.get("available", False)
            and s["slug"] in ploi_plans
            and (not self._plan_filter or self._plan_filter in s["slug"])
            and cpu >= self._min_vcpus
            and (not self._max_vcpus or cpu <= self._max_vcpus)
            and mem >= self._min_memory
            and (not self._max_memory or mem <= self._max_memory)
            and (not self._max_price or price <= self._max_price)
        )

    def _region_passes(self, slug: str, ploi_regions: dict, regions: dict) -> bool:
        return (
            slug in ploi_regions
            and regions.get(slug, {}).get("available", True)
            and (not self._regions or slug in self._regions)
            and slug not in self._excluded
        )

    def _combine(self, prov: dict, sizes: list[dict], regions: dict) -> list[PlanOption]:
        pdata = prov.get("provider", {})
        plans = {str(p["id"]) for p in pdata.get("plans", [])}
        pregions = {str(r["id"]): r for r in pdata.get("regions", [])}
        out = []
        for s in sizes:
            if not self._size_passes(s, plans):
                continue
            for reg in s.get("regions", []):
                if not self._region_passes(reg, pregions, regions):
                    continue
                out.append(
                    PlanOption(
                        ploi_credential=prov.get("label") or prov.get("name") or "",
                        ploi_credential_id=prov.get("id"),
                        region=reg,
                        region_name=pregions[reg].get("name") or regions.get(reg, {}).get("name", reg),
                        plan=s["slug"],
                        vcpus=s.get("vcpus", 0),
                        memory_mb=s.get("memory", 0),
                        disk_gb=s.get("disk", 0),
                        transfer_tb=s.get("transfer", 0),
                        price_monthly=s.get("price_monthly") or 0,
                        description=s.get("description", ""),
                    )
                )
        return out

    # ------------------------------------------------------------ results
    def results(self) -> list[PlanOption]:
        return list(self._results)

    def by_region(self) -> dict[str, list[PlanOption]]:
        grouped: dict[str, list[PlanOption]] = {}
        for o in self._results:
            grouped.setdefault(o.region, []).append(o)
        return grouped

    def render(self, fmt: str = "table") -> str:
        if fmt not in self.FORMATS:
            raise PlanFinderError(f"Format must be one of {', '.join(self.FORMATS)}")
        if not self._results:
            return "No plan/region combinations match your filters.\n"
        return getattr(self, f"_render_{fmt}")()

    def save(self, path: str, fmt: str = "table") -> PloiDoPlanFinder:
        with open(path, "w", newline="") as f:
            f.write(self.render(fmt))
        return self

    def _render_json(self) -> str:
        return json.dumps([asdict(o) for o in self._results], indent=2) + "\n"

    def _render_csv(self) -> str:
        buf = io.StringIO()
        writer = csv.DictWriter(buf, fieldnames=list(asdict(self._results[0]).keys()))
        writer.writeheader()
        writer.writerows(asdict(o) for o in self._results)
        return buf.getvalue()

    def _render_markdown(self) -> str:
        lines = []
        for region, opts in self.by_region().items():
            lines += [
                f"## {region} ({opts[0].region_name})",
                "",
                "| Plan | vCPU | RAM | Disk | $/mo | Type |",
                "|---|---|---|---|---|---|",
            ]
            lines += [
                f"| {o.plan} | {o.vcpus} | {o.memory_label} | {o.disk_gb}GB | {o.price_monthly:.2f} | {o.description} |"
                for o in opts
            ]
            lines.append("")
        return "\n".join(lines) + "\n"

    def _render_table(self) -> str:
        lines = []
        for region, opts in self.by_region().items():
            lines += [
                f"== {region} ({opts[0].region_name}) ==",
                f"{'Plan':<28}{'vCPU':>5}{'RAM':>9}{'Disk':>8}{'$/mo':>10}  Type",
            ]
            lines += [
                f"{o.plan:<28}{o.vcpus:>5}{o.memory_label:>9}{str(o.disk_gb) + 'GB':>8}{o.price_monthly:>10.2f}  {o.description}"
                for o in opts
            ]
            lines.append("")
        return "\n".join(lines) + "\n"


class Config:
    """Reads settings from defaults, a .env file, the environment, and CLI flags."""

    SETTINGS = {
        "PLOI_API_TOKEN": ("", str, "Ploi API token (read access is enough)"),
        "DO_API_TOKEN": ("", str, "DigitalOcean API token (read scope is enough)"),
        "PLOI_API_URL": ("https://ploi.io/api", str, "Ploi API base URL"),
        "DO_API_URL": ("https://api.digitalocean.com/v2", str, "DigitalOcean API base URL"),
        "PLOI_PROVIDER": ("digitalocean", str, "Match Ploi providers whose name contains this text"),
        "PLOI_CREDENTIAL_ID": ("", str, "Only use this Ploi credential id (blank = all matching)"),
        "REGIONS": ("", str, "Comma-separated region slugs to include, e.g. nyc3,atl1"),
        "EXCLUDE_REGIONS": ("", str, "Comma-separated region slugs to skip"),
        "PLAN_FILTER": ("", str, "Only plans whose slug contains this text, e.g. -intel"),
        "MIN_VCPUS": (0, int, "Minimum vCPUs"),
        "MAX_VCPUS": (0, int, "Maximum vCPUs (0 = no limit)"),
        "MIN_MEMORY_MB": (0, int, "Minimum RAM in MB"),
        "MAX_MEMORY_MB": (0, int, "Maximum RAM in MB (0 = no limit)"),
        "MAX_PRICE": (0.0, float, "Maximum monthly price in USD (0 = no limit)"),
        "SORT_BY": ("price", str, "price, memory, vcpus or plan"),
        "OUTPUT_FORMAT": ("table", str, "table, markdown, csv or json"),
        "OUTPUT_FILE": ("", str, "Write output to this file instead of the screen"),
        "TIMEOUT": (30, int, "HTTP timeout in seconds"),
        "ENV_FILE": (".env", str, "Path to a .env file to load"),
    }

    def __init__(self, values: dict):
        self.values = values

    def __getitem__(self, key: str):
        return self.values[key]

    def list(self, key: str) -> list[str]:
        return [v.strip() for v in str(self.values[key]).split(",") if v.strip()]

    @staticmethod
    def read_env_file(path: str) -> dict[str, str]:
        values: dict[str, str] = {}
        if not path or not os.path.isfile(path):
            return values
        with open(path) as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                val = val.strip()
                if val[:1] in ("'", '"'):
                    val = val[1:].split(val[0], 1)[0]
                elif val.startswith("#"):
                    val = ""
                else:
                    val = val.split(" #", 1)[0].split("\t#", 1)[0].strip()
                values[key.strip().removeprefix("export ").strip()] = val
        return values

    @classmethod
    def from_sources(cls, argv: list[str] | None = None) -> Config:
        parser = argparse.ArgumentParser(
            prog="workbench plans",
            description="List DigitalOcean plans you can create per region through Ploi.",
        )
        for name, (default, typ, help_) in cls.SETTINGS.items():
            parser.add_argument(
                "--" + name.lower().replace("_", "-"),
                dest=name,
                type=typ,
                default=None,
                help=f"{help_} [env {name}, default {default!r}]",
            )
        args = vars(parser.parse_args(argv))
        env_file = cls.read_env_file(args["ENV_FILE"] or os.environ.get("ENV_FILE") or ".env")

        values = {}
        for name, (default, typ, _) in cls.SETTINGS.items():
            raw = args[name] if args[name] is not None else os.environ.get(name, env_file.get(name))
            try:
                values[name] = default if raw in (None, "") else typ(raw)
            except ValueError:
                raise PlanFinderError(f"{name} must be a {typ.__name__}, got {raw!r}") from None
        return cls(values)

    def build_finder(self) -> PloiDoPlanFinder:
        return (
            PloiDoPlanFinder()
            .with_tokens(ploi=self["PLOI_API_TOKEN"], digitalocean=self["DO_API_TOKEN"])
            .with_endpoints(ploi=self["PLOI_API_URL"], digitalocean=self["DO_API_URL"])
            .timeout(self["TIMEOUT"])
            .provider(self["PLOI_PROVIDER"])
            .credential(self["PLOI_CREDENTIAL_ID"])
            .in_regions(*self.list("REGIONS"))
            .excluding_regions(*self.list("EXCLUDE_REGIONS"))
            .plans_matching(self["PLAN_FILTER"])
            .min_vcpus(self["MIN_VCPUS"])
            .max_vcpus(self["MAX_VCPUS"])
            .min_memory(self["MIN_MEMORY_MB"])
            .max_memory(self["MAX_MEMORY_MB"])
            .max_price(self["MAX_PRICE"])
            .sort_by(self["SORT_BY"])
        )


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    quiet = any(a in ("--quiet", "-q") for a in argv)
    argv = [a for a in argv if a not in ("--quiet", "-q")]
    try:
        config = Config.from_sources(argv)
        finder = config.build_finder().fetch(Progress.off() if quiet else Progress.detect())
        if config["OUTPUT_FILE"]:
            finder.save(config["OUTPUT_FILE"], config["OUTPUT_FORMAT"])
            print(f"Wrote {len(finder.results())} configurations to {config['OUTPUT_FILE']}")
        else:
            print(finder.render(config["OUTPUT_FORMAT"]), end="")
        return 0
    except PlanFinderError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
