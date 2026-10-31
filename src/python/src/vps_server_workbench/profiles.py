"""Profiles: versioned KEY=VALUE files in config/profiles, layered onto _defaults.conf.

A profile never holds secrets. `resolve()` layers defaults < profile < overrides, `validate()` checks
RAM, region, VPC and best-practice rules, and `render_*()` produce the files `configure` writes.
"""

from __future__ import annotations

import ipaddress
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

from vps_server_workbench import envfile

META = ("PROFILE_VERSION", "PROFILE_DESCRIPTION")

# Keys written to /etc/docker-db-server-manager.conf (DB_PRIVATE_IP becomes PRIVATE_IP + EXPECTED_PRIVATE_IP).
DB_KEYS = (
    "APP", "PG_USER", "PG_DB", "ENABLE_POSTGRES", "ENABLE_PGBOUNCER", "ENABLE_MYSQL", "ENABLE_MARIADB",
    "ENABLE_ADMINER", "PG_APP_CREATEDB", "TLS_MODE", "ENVS", "TENANT_ENVS", "PROTECTED_ENVS", "PRD_LOCATION",
    "ENV_MIGRATOR", "RETENTION", "PITR", "OFFSITE", "OFFSITE_ENDPOINT", "OFFSITE_REGION", "OFFSITE_BUCKET",
    "ALERT_EMAIL", "VPC_CIDR",
)
BOOL_KEYS = (
    "ENABLE_POSTGRES", "ENABLE_PGBOUNCER", "ENABLE_MYSQL", "ENABLE_MARIADB", "ENABLE_ADMINER", "PG_APP_CREATEDB",
    "ENV_MIGRATOR", "LOAD_BALANCER", "WIREGUARD", "STRICT", "HARDEN", "DO_ALERTS", "UPTIME_CHECKS", "GOTENBERG",
)
INT_KEYS = ("DB_DROPLET_MB", "WEB_DROPLET_MB", "DEDICATED_DROPLET_MB", "WEB_NODES", "MIN_DB_MB")
ENUMS = {
    "DB_MODE": ("self", "managed", "replica"),
    "TLS_MODE": ("off", "require"),
    "PRD_LOCATION": ("local", "droplet", "managed"),
    "PITR": ("off", "pgbackrest"),
    "OFFSITE": ("none", "s3"),
    "GOTENBERG_ROLE": ("web", "db", "dedicated"),
    "STORAGE": ("none", "spaces", "garage", "seaweedfs", "rustfs"),
    "STORAGE_ROLE": ("web", "db", "dedicated"),
}
DO_REGIONS = (
    "nyc1", "nyc2", "nyc3", "sfo1", "sfo2", "sfo3", "ams2", "ams3", "sgp1", "lon1", "fra1", "tor1", "blr1",
    "syd1", "atl1", "ric1",
)
SPACES_REGIONS = ("nyc3", "sfo2", "sfo3", "ams3", "sgp1", "lon1", "fra1", "tor1", "blr1", "syd1", "atl1")
ENV_NAMES = ("tst", "dev", "trn", "stg", "prd")

# RAM planning estimates in MB. Engines mirror engine_ram_mb() in docker-db-server-manager.sh.
RAM_OS = 512
RAM_ENGINE = {"ENABLE_POSTGRES": 1024, "ENABLE_PGBOUNCER": 64, "ENABLE_MYSQL": 1024, "ENABLE_MARIADB": 768,
              "ENABLE_ADMINER": 64}
RAM_PITR = 128
RAM_WEB_APP = 1024  # nginx + PHP-FPM + queue worker + scheduler on a small Ploi node
RAM_ADDON = {"gotenberg": 1024, "garage": 256, "seaweedfs": 512, "rustfs": 512}
SIZES = ((1024, "s-1vcpu-1gb"), (2048, "s-1vcpu-2gb"), (4096, "s-2vcpu-4gb"), (8192, "s-4vcpu-8gb"),
         (16384, "s-8vcpu-16gb"))
SELF_HOSTED_STORAGE = ("garage", "seaweedfs", "rustfs")
_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
_APP = re.compile(r"^[a-z][a-z0-9_]{1,30}$")
_UNSAFE = re.compile(r"[\"'`$\\\n\r]")
_RET = re.compile(r"^(daily|weekly|monthly|yearly)=[0-9]{1,3}$")
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def repo_root() -> Path:
    env = os.environ.get("VSW_ROOT")
    return Path(env) if env else Path(__file__).resolve().parents[4]


def profiles_dir(root: Path | None = None) -> Path:
    return (root or repo_root()) / "config" / "profiles"


def available(root: Path | None = None) -> list[str]:
    return sorted(p.stem for p in profiles_dir(root).glob("*.conf") if not p.name.startswith("_"))


def load(name: str, root: Path | None = None) -> dict[str, str]:
    if not _NAME.match(name):
        raise ValueError(f"bad profile name {name!r}")
    path = profiles_dir(root) / f"{name}.conf"
    if not path.is_file():
        raise ValueError(f"no profile {name!r} (have: {', '.join(available(root))})")
    return envfile.load(path)


def defaults(root: Path | None = None) -> dict[str, str]:
    return envfile.load(profiles_dir(root) / "_defaults.conf")


@dataclass
class Resolved:
    profile: str
    version: str
    values: dict[str, str]
    source: dict[str, str] = field(default_factory=dict)  # key -> defaults | profile | override | derived


def resolve(name: str, overrides: dict[str, str] | None = None, root: Path | None = None) -> Resolved:
    base, prof = defaults(root), load(name, root)
    unknown = [k for k in prof if k not in base]
    if unknown:
        raise ValueError(f"profile {name}: unknown keys {', '.join(sorted(unknown))}")
    values, source = dict(base), dict.fromkeys(base, "defaults")
    for k, v in prof.items():
        values[k], source[k] = v, "profile"
    for k, v in (overrides or {}).items():
        if k not in base and k != "CLIENT":
            raise ValueError(f"unknown key {k} (see docs/reference/profiles.md)")
        if k in META:
            raise ValueError(f"{k} comes from the profile and cannot be overridden")
        values[k], source[k] = v, "override"
    if values.get("OFFSITE") == "s3" and not values.get("OFFSITE_ENDPOINT"):
        values["OFFSITE_ENDPOINT"] = f"https://{values.get('REGION', 'nyc3')}.digitaloceanspaces.com"
        source["OFFSITE_ENDPOINT"] = "derived"
    return Resolved(name, prof.get("PROFILE_VERSION", "?"), values, source)


def diff(a: dict[str, str], b: dict[str, str]) -> list[tuple[str, str, str]]:
    keys = [k for k in dict.fromkeys([*a, *b]) if k not in META]
    return [(k, a.get(k, ""), b.get(k, "")) for k in keys if a.get(k, "") != b.get(k, "")]


def size_for(mb: int) -> str:
    for cap, slug in SIZES:
        if mb <= cap:
            return slug
    return SIZES[-1][1]


def ram_plan(v: dict[str, str]) -> dict[str, tuple[int, int, list[str]]]:
    """Per node role: (needed MB, droplet MB, what runs there)."""
    on = lambda k: v.get(k) == "1"  # noqa: E731
    nodes: dict[str, tuple[int, int, list[str]]] = {}
    if v["DB_MODE"] != "managed":
        need, items = RAM_OS, ["os"]
        for k, mb in RAM_ENGINE.items():
            if on(k):
                need += mb
                items.append(k.removeprefix("ENABLE_").lower())
        if v["PITR"] == "pgbackrest":
            need += RAM_PITR
            items.append("pgbackrest")
        nodes["db"] = (need, int(v["DB_DROPLET_MB"]), items)
    nodes["web"] = (RAM_OS + RAM_WEB_APP, int(v["WEB_DROPLET_MB"]), ["os", "php/nginx/workers"])
    for addon, role in addons_placed(v):
        if role not in nodes:
            nodes[role] = (RAM_OS, int(v["DEDICATED_DROPLET_MB"]), ["os"])
        need, mb, items = nodes[role]
        nodes[role] = (need + RAM_ADDON[addon], mb, [*items, addon])
    return nodes


def addons_placed(v: dict[str, str]) -> list[tuple[str, str]]:
    out = []
    if v.get("GOTENBERG") == "1":
        out.append(("gotenberg", v["GOTENBERG_ROLE"]))
    if v.get("STORAGE") in SELF_HOSTED_STORAGE:
        out.append((v["STORAGE"], v["STORAGE_ROLE"]))
    return out


def _envs(v: dict[str, str], key: str) -> list[str]:
    return v.get(key, "").split()


def _net(text: str) -> ipaddress.IPv4Network | None:
    try:
        return ipaddress.IPv4Network(text, strict=False)
    except ValueError:
        return None


def validate(r: Resolved) -> list[tuple[str, str]]:
    """Findings as (level, message); level is error, warn or info."""
    v, out = r.values, []
    err = lambda m: out.append(("error", m))  # noqa: E731
    strict = v.get("STRICT") == "1"
    advise = lambda m: out.append(("error" if strict else "warn", m + (" (STRICT=1)" if strict else "")))  # noqa: E731
    warn = lambda m: out.append(("warn", m))  # noqa: E731
    info = lambda m: out.append(("info", m))  # noqa: E731

    for k, val in v.items():
        if _UNSAFE.search(val):
            err(f"{k}: quotes, $, backticks, backslashes and newlines are not allowed (the files are sourced by bash)")
    if v.get("RETENTION") and not all(_RET.match(t) for t in v["RETENTION"].split()):
        err("RETENTION must look like \"daily=7 weekly=4 monthly=12 yearly=2\"")
    if v.get("ALERT_EMAIL") and not _EMAIL.match(v["ALERT_EMAIL"]):
        err(f"ALERT_EMAIL {v['ALERT_EMAIL']!r} is not an email address")
    for k in BOOL_KEYS:
        if v.get(k) not in ("0", "1"):
            err(f"{k} must be 0 or 1 (got {v.get(k)!r})")
    for k in INT_KEYS:
        if not v.get(k, "").isdigit():
            err(f"{k} must be a whole number (got {v.get(k)!r})")
    for k, choices in ENUMS.items():
        if v.get(k) not in choices:
            err(f"{k} must be one of {', '.join(choices)} (got {v.get(k)!r})")
    client = v.get("CLIENT", "")
    if client and not _NAME.match(client):
        err("CLIENT must be lowercase letters, digits and dashes (it names the local/<client>/ folder)")
    if v.get("APP") and not _APP.match(v["APP"]):
        err("APP must start with a letter: lowercase letters, digits, underscore (2-31 chars)")
    if any(level == "error" for level, _ in out):
        return out  # the checks below need well-formed values

    # region and network
    if v["REGION"] not in DO_REGIONS:
        err(f"REGION {v['REGION']!r} is not a DigitalOcean region ({' '.join(DO_REGIONS)})")
    vpc = _net(v["VPC_CIDR"])
    if not vpc or not vpc.is_private:
        err(f"VPC_CIDR {v['VPC_CIDR']!r} must be a private IPv4 network")
    for k in ("DB_PRIVATE_IP", "WEB_PRIVATE_IP"):
        if v.get(k):
            try:
                ip = ipaddress.IPv4Address(v[k])
            except ValueError:
                err(f"{k} {v[k]!r} is not an IPv4 address")
                continue
            if vpc and ip not in vpc and not (k == "WEB_PRIVATE_IP" and v["WIREGUARD"] == "1"):
                err(f"{k} {ip} is outside VPC_CIDR {vpc}")
    if v["WIREGUARD"] == "1":
        wg = _net(v["WIREGUARD_CIDR"])
        if not v["PEER_REGION"] or v["PEER_REGION"] == v["REGION"]:
            err("WIREGUARD=1 needs PEER_REGION, different from REGION")
        elif v["PEER_REGION"] not in DO_REGIONS:
            err(f"PEER_REGION {v['PEER_REGION']!r} is not a DigitalOcean region")
        if not wg or (vpc and not wg.subnet_of(vpc)):
            err(f"WIREGUARD_CIDR {v['WIREGUARD_CIDR']} must lie inside VPC_CIDR {v['VPC_CIDR']} (the DB only accepts VPC_CIDR)")
        info("cross-region: expect extra latency per query (estimate: a few ms to tens of ms by region pair)")
    elif v["PEER_REGION"]:
        err("PEER_REGION is set but WIREGUARD=0: DigitalOcean VPCs are regional, cross-region traffic needs WireGuard")

    # engines and environments
    on = lambda k: v[k] == "1"  # noqa: E731
    if v["DB_MODE"] != "managed":
        if not any(on(k) for k in ("ENABLE_POSTGRES", "ENABLE_MYSQL", "ENABLE_MARIADB")):
            err("no database engine enabled")
        if on("ENABLE_PGBOUNCER") and not on("ENABLE_POSTGRES"):
            err("ENABLE_PGBOUNCER=1 needs ENABLE_POSTGRES=1")
        if v["PITR"] == "pgbackrest" and not on("ENABLE_POSTGRES"):
            err("PITR=pgbackrest is Postgres only")
    envs = _envs(v, "ENVS")
    for k in ("ENVS", "TENANT_ENVS", "PROTECTED_ENVS"):
        bad = [e for e in _envs(v, k) if e not in ENV_NAMES]
        if bad:
            err(f"{k}: unknown env(s) {' '.join(bad)} (use {' '.join(ENV_NAMES)})")
    for k in ("TENANT_ENVS",):
        extra = [e for e in _envs(v, k) if e not in envs]
        if extra:
            err(f"{k} lists {' '.join(extra)}, which are not in ENVS")
    if envs and not v["APP"]:
        err("ENVS needs APP (databases are named <app>_<env>)")
    prd_here = "prd" in envs and v["PRD_LOCATION"] == "local"
    if "prd" in envs and v["PRD_LOCATION"] != "local" and v["DB_MODE"] == "self":
        warn("ENVS has prd but PRD_LOCATION is not local: prd databases will not be created on this DB droplet")
    if prd_here and "prd" not in _envs(v, "PROTECTED_ENVS"):
        err("prd lives on this DB droplet but is not in PROTECTED_ENVS")
    if prd_here and len(envs) > 1:
        advise("prd shares the DB droplet with " + " ".join(e for e in envs if e != "prd") + "; give prd its own droplet")
    if prd_here and v["PITR"] == "off" and v["DB_MODE"] == "self":
        advise("prd without point-in-time recovery: set PITR=pgbackrest")
    if v["OFFSITE"] == "none" and v["DB_MODE"] != "managed":
        advise("backups stay on the DB droplet only (OFFSITE=none); one lost droplet loses them too")
    if v["OFFSITE"] == "s3" and not v["OFFSITE_BUCKET"]:
        info("OFFSITE_BUCKET is empty: create a Spaces bucket and set it before `backup --offsite`")
    if v["OFFSITE_ENDPOINT"].endswith(".digitaloceanspaces.com") and v["REGION"] not in SPACES_REGIONS:
        warn(f"Spaces is not offered in {v['REGION']}; set OFFSITE_ENDPOINT to a nearby Spaces region")
    if (prd_here or v["DB_MODE"] == "managed") and not v["ALERT_EMAIL"]:
        advise("no ALERT_EMAIL: failed backups and doctor problems would go unnoticed")
    if "prd" in envs and v["TLS_MODE"] == "off" and v["DB_MODE"] == "self":
        advise("TLS_MODE=off for prd: traffic inside the VPC is unencrypted")
    if "prd" in envs and v["PG_APP_CREATEDB"] == "1" and "prd" not in _envs(v, "TENANT_ENVS"):
        warn("PG_APP_CREATEDB=1 lets the prd app role create databases; set 0 unless prd has tenants")

    # topology
    if v["DB_MODE"] != "managed" and int(v["DB_DROPLET_MB"]) < int(v["MIN_DB_MB"]):
        err(f"DB_DROPLET_MB {v['DB_DROPLET_MB']} is below this profile's minimum {v['MIN_DB_MB']}")
    if int(v["WEB_NODES"]) < 1:
        err("WEB_NODES must be at least 1")
    if int(v["WEB_NODES"]) > 1 and v["LOAD_BALANCER"] != "1":
        err("WEB_NODES > 1 needs LOAD_BALANCER=1")
    if int(v["WEB_NODES"]) > 1 and v["STORAGE"] == "none":
        err("two or more web nodes cannot keep files on local disk: pick STORAGE (spaces recommended)")
    if v["DB_MODE"] == "replica":
        info("DB_MODE=replica: the replica is set up by hand (docs/high-availability.md)")
    if v["DB_MODE"] == "managed":
        info("DB_MODE=managed: no db-server.conf is written; point DB_HOST at the managed cluster's private host")

    # add-ons
    for addon, role in addons_placed(v):
        if role == "db" and v["DB_MODE"] == "managed":
            err(f"{addon} role db, but DB_MODE=managed has no DB droplet; use web or dedicated")
        if role == "web" and int(v["WEB_NODES"]) > 1 and addon in SELF_HOSTED_STORAGE:
            err(f"{addon} on the web role with {v['WEB_NODES']} web nodes: each node would hold different files")
    if v["STORAGE"] == "rustfs":
        if "prd" in envs or v["STRICT"] == "1":
            err("STORAGE=rustfs is experimental: dev/test only, never with prd or STRICT profiles")
        else:
            warn("STORAGE=rustfs is experimental; install needs --accept-experimental")
    if v["STORAGE"] == "spaces":
        info("STORAGE=spaces: create the bucket and a key scoped to it in the DO control panel")
    if v["STORAGE"] in SELF_HOSTED_STORAGE:
        info(f"{v['STORAGE']} holds data on a droplet: plan an off-node copy (stacks/addons/README.md#backups)")

    # RAM per node
    for role, (need, have, items) in ram_plan(v).items():
        what = ", ".join(items)
        if need > have:
            err(f"{role} node needs ~{need} MB ({what}) but has {have} MB: use {size_for(need)} or move something")
        elif need > have * 0.85:
            warn(f"{role} node is tight: ~{need} of {have} MB ({what})")
        else:
            info(f"{role} node: ~{need} of {have} MB ({what}) (estimate)")
    if v.get("STORAGE") in SELF_HOSTED_STORAGE and v["STORAGE_ROLE"] == "web" and int(v["WEB_DROPLET_MB"]) <= 2048:
        alt = "the db node" if not (on("ENABLE_MYSQL") or on("ENABLE_MARIADB")) else "a dedicated droplet"
        advise(f"{v['STORAGE']} on a {v['WEB_DROPLET_MB']} MB web node competes with PHP; use {alt} (STORAGE_ROLE)")
    return out


# ---- rendering ---------------------------------------------------------------------------------
def _q(value: str) -> str:
    return f'"{value}"' if (" " in value or value == "") else value


def render_workbench(r: Resolved, stamp: str) -> str:
    over = [f"{k}={r.values[k]}" for k, s in r.source.items() if s == "override"]
    lines = [
        f"# workbench.conf - written by `bin/workbench configure` on {stamp}",
        f"# profile {r.profile} v{r.version}; overrides: {' '.join(over) or 'none'}",
        "# Resolved settings (no secrets). Re-run configure to change them; edits here are kept only until then.",
        f"PROFILE={r.profile}",
    ]
    for k, val in r.values.items():
        if k in META:
            lines.append(f"{k}={_q(val)}")
            continue
        lines.append(f"{k}={_q(val)}{'' if r.source.get(k) == 'defaults' else '   # ' + r.source.get(k, '')}")
    return "\n".join(lines) + "\n"


def db_values(r: Resolved) -> dict[str, str]:
    v = r.values
    out = {k: v[k] for k in DB_KEYS}
    if v.get("DB_PRIVATE_IP"):
        out["PRIVATE_IP"] = out["EXPECTED_PRIVATE_IP"] = v["DB_PRIVATE_IP"]
    return out


def render_db(r: Resolved, existing: str | None, stamp: str) -> str:
    """Merge managed keys into an existing manager config, keeping its other lines and comments."""
    vals = db_values(r)
    if not existing:
        head = [
            f"# /etc/docker-db-server-manager.conf - written by `bin/workbench configure` ({r.profile} v{r.version}, {stamp})",
            "# No secrets: the manager generates passwords on the server. Keys: config/db-server.env.example",
        ]
        return "\n".join(head + [f"{k}={_q(val)}" for k, val in vals.items()]) + "\n"
    seen, lines = set(), []
    for line in existing.splitlines():
        m = re.match(r"^\s*([A-Z][A-Z0-9_]*)=", line)
        if m and m.group(1) in vals:
            k = m.group(1)
            if k in seen:
                continue
            seen.add(k)
            lines.append(f"{k}={_q(vals[k])}")
        else:
            lines.append(line)
    missing = [k for k in vals if k not in seen]
    if missing:
        lines.append(f"# added by `bin/workbench configure` ({r.profile} v{r.version}, {stamp})")
        lines.extend(f"{k}={_q(vals[k])}" for k in missing)
    return "\n".join(lines) + "\n"


def render_addons(r: Resolved, role: str, stamp: str) -> str:
    v = r.values
    names = [a for a, rl in addons_placed(v) if rl == role]
    envs = _envs(v, "ENVS")
    node_env = "prd" if ("prd" in envs and v["PRD_LOCATION"] == "local") else (envs[-1] if envs else "")
    lines = [
        f"# /etc/vsw-addons.conf for the {role} node - written by `bin/workbench configure` ({r.profile} v{r.version}, {stamp})",
        f"# install: addon.sh install {' / '.join(names)}   (no secrets here; addon.sh generates them on the node)",
        f"ADDON_ROLE={role}",
        f"ADDON_ENV={node_env}",
        f"PROTECTED_ENVS={_q(v['PROTECTED_ENVS'])}",
    ]
    if v["STORAGE"] in SELF_HOSTED_STORAGE and v["STORAGE_ROLE"] == role:
        lines.append(f"STORAGE_BUCKET={v['STORAGE_BUCKET']}")
        if v["STORAGE_DATA_DIR"]:
            lines.append(f"ADDON_DATA_DIR={v['STORAGE_DATA_DIR']}")
    if role == "db" and v.get("DB_PRIVATE_IP"):
        lines.append(f"ADDON_BIND={v['DB_PRIVATE_IP']}")
    return "\n".join(lines) + "\n"


ORDER = ("dev-budget", "staging", "production-single", "production-ha", "mysql-app", "multi-engine",
         "cross-region-wireguard")


def markdown_table(root: Path | None = None) -> str:
    """Profiles vs the settings they change (docs/reference/profiles.md embeds this; a test keeps it in sync)."""
    names = [n for n in ORDER if n in available(root)] + [n for n in available(root) if n not in ORDER]
    base = defaults(root)
    res = {n: resolve(n, root=root) for n in names}
    keys = [k for k in base if k not in META and any(res[n].values.get(k) != base[k] for n in names)]
    rows = ["| Setting | `_defaults` | " + " | ".join(f"`{n}`" for n in names) + " |",
            "|---|---|" + "---|" * len(names)]
    for k in keys:
        cells = [base[k] or "(empty)"]
        for n in names:
            val, src = res[n].values.get(k, ""), res[n].source.get(k)
            cells.append("·" if val == base[k] else ("derived" if src == "derived" else f"**{val or '(empty)'}**"))
        rows.append(f"| `{k}` | " + " | ".join(cells) + " |")
    return "\n".join(rows) + "\n"
