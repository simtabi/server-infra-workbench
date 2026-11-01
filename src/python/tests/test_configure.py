import contextlib
import io
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vps_server_workbench import configure
from vps_server_workbench import profiles as P

BASE = {"CLIENT": "acme", "APP": "demo"}


def run(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = configure.main(argv)
    return rc, out.getvalue(), err.getvalue()


def errors(name, **over):
    r = P.resolve(name, {**BASE, **over})
    return [m for level, m in P.validate(r) if level == "error"]


class ProfilesTest(unittest.TestCase):
    def test_all_seven_profiles_exist_versioned_and_valid(self):
        names = P.available()
        self.assertEqual(
            set(names),
            {
                "dev-budget",
                "staging",
                "production-single",
                "production-ha",
                "mysql-app",
                "multi-engine",
                "cross-region-wireguard",
            },
        )
        for name in names:
            prof = P.load(name)
            self.assertTrue(prof["PROFILE_VERSION"].isdigit(), name)
            self.assertTrue(prof["PROFILE_DESCRIPTION"], name)
            self.assertEqual(errors(name, ALERT_EMAIL="ops@example.com"), [], name)

    def test_profiles_hold_no_secret_looking_keys(self):
        for path in P.profiles_dir().glob("*.conf"):
            for key in P.envfile.load(path):
                self.assertNotRegex(key, "PASS|SECRET|TOKEN|_KEY$", path.name)

    def test_layering_and_sources(self):
        r = P.resolve("dev-budget", {"CLIENT": "acme", "RETENTION": "daily=3"})
        self.assertEqual(r.source["ENABLE_POSTGRES"], "defaults")
        self.assertEqual(r.source["ENVS"], "profile")
        self.assertEqual(r.source["RETENTION"], "override")
        self.assertEqual(r.values["OFFSITE_ENDPOINT"], "https://nyc3.digitaloceanspaces.com")
        self.assertEqual(r.source["OFFSITE_ENDPOINT"], "derived")

    def test_unknown_override_and_meta_refused(self):
        with self.assertRaises(ValueError):
            P.resolve("dev-budget", {"NOPE": "1"})
        with self.assertRaises(ValueError):
            P.resolve("dev-budget", {"PROFILE_VERSION": "9"})
        with self.assertRaises(ValueError):
            P.load("../etc/passwd")

    def test_dev_budget_is_postgres_only_on_2gb(self):
        v = P.resolve("dev-budget", BASE).values
        self.assertEqual(
            (v["ENABLE_POSTGRES"], v["ENABLE_PGBOUNCER"], v["ENABLE_MYSQL"], v["ENABLE_MARIADB"]),
            ("1", "1", "0", "0"),
        )
        self.assertEqual((v["DB_DROPLET_MB"], v["OFFSITE"], v["STORAGE"]), ("2048", "s3", "spaces"))

    def test_ram_check(self):
        self.assertTrue(
            any("db node needs" in m for m in errors("dev-budget", ENABLE_MYSQL="1", ENABLE_MARIADB="1"))
        )
        self.assertTrue(any("s-2vcpu-4gb" in m for m in errors("dev-budget", GOTENBERG="1")))
        self.assertEqual(errors("dev-budget", GOTENBERG="1", WEB_DROPLET_MB="4096"), [])
        self.assertTrue(
            any(
                "below this profile's minimum" in m
                for m in errors("production-single", DB_DROPLET_MB="2048", ALERT_EMAIL="a@b.co")
            )
        )

    def test_storage_on_small_web_node_warns_and_strict_errors(self):
        r = P.resolve("dev-budget", {**BASE, "STORAGE": "garage", "STORAGE_ROLE": "web"})
        self.assertTrue(any(lv == "warn" and "competes with PHP" in m for lv, m in P.validate(r)))
        self.assertTrue(
            any(
                "competes with PHP" in m
                for m in errors("dev-budget", STORAGE="garage", STORAGE_ROLE="web", STRICT="1")
            )
        )

    def test_region_vpc_and_ip(self):
        self.assertTrue(errors("dev-budget", REGION="mars1"))
        self.assertTrue(errors("dev-budget", VPC_CIDR="8.8.8.0/24"))
        self.assertTrue(
            any(
                "outside VPC_CIDR" in m
                for m in errors("dev-budget", VPC_CIDR="10.10.0.0/16", DB_PRIVATE_IP="10.20.0.5")
            )
        )
        self.assertEqual(errors("dev-budget", VPC_CIDR="10.10.0.0/16", DB_PRIVATE_IP="10.10.0.5"), [])

    def test_wireguard_rules(self):
        self.assertTrue(any("PEER_REGION" in m for m in errors("cross-region-wireguard", PEER_REGION="nyc3")))
        self.assertTrue(any("needs WireGuard" in m for m in errors("dev-budget", PEER_REGION="ams3")))
        self.assertTrue(
            any("WIREGUARD_CIDR" in m for m in errors("cross-region-wireguard", VPC_CIDR="10.10.0.0/16"))
        )

    def test_production_guard_rails(self):
        self.assertTrue(any("ALERT_EMAIL" in m for m in errors("production-single")))
        self.assertTrue(
            any("PITR" in m for m in errors("production-single", PITR="off", ALERT_EMAIL="a@b.co"))
        )
        self.assertTrue(
            any(
                "shares the DB droplet" in m
                for m in errors("production-single", ENVS="stg prd", ALERT_EMAIL="a@b.co")
            )
        )
        self.assertTrue(
            any(
                "PROTECTED_ENVS" in m
                for m in errors("dev-budget", ENVS="dev prd", PRD_LOCATION="local", PROTECTED_ENVS="stg")
            )
        )
        self.assertTrue(
            any("rustfs" in m for m in errors("production-single", STORAGE="rustfs", ALERT_EMAIL="a@b.co"))
        )

    def test_ha_rules(self):
        self.assertTrue(
            any("local disk" in m for m in errors("production-ha", STORAGE="none", ALERT_EMAIL="a@b.co"))
        )
        self.assertTrue(
            any("LOAD_BALANCER" in m for m in errors("dev-budget", WEB_NODES="2", LOAD_BALANCER="0"))
        )
        self.assertTrue(
            any("no DB droplet" in m for m in errors("production-ha", STORAGE="garage", ALERT_EMAIL="a@b.co"))
        )

    def test_engine_dependencies_and_value_safety(self):
        self.assertTrue(any("PGBOUNCER" in m for m in errors("mysql-app", ENABLE_PGBOUNCER="1")))
        self.assertTrue(any("Postgres only" in m for m in errors("mysql-app", PITR="pgbackrest")))
        self.assertTrue(any("sourced by bash" in m for m in errors("dev-budget", OFFSITE_BUCKET="b$(id)")))
        self.assertTrue(any("RETENTION" in m for m in errors("dev-budget", RETENTION="forever")))
        self.assertTrue(any("not in ENVS" in m for m in errors("dev-budget", TENANT_ENVS="prd")))

    def test_render_db_merges_existing(self):
        r = P.resolve("dev-budget", {**BASE, "DB_PRIVATE_IP": "10.10.0.5"})
        old = "# mine\nPG_IMAGE=custom:1\nAPP=old\nAPP=older\n"
        text = P.render_db(r, old, "now")
        self.assertIn("# mine\nPG_IMAGE=custom:1\nAPP=demo\n", text)
        self.assertEqual(text.count("APP="), 1)
        self.assertIn("EXPECTED_PRIVATE_IP=10.10.0.5", text)
        self.assertNotIn("STORAGE", text)

    def test_monitoring_placement_and_validation(self):
        r = P.resolve("dev-budget", {**BASE, "MONITOR_STACKS": "beszel,kuma"})
        self.assertEqual(P.monitor_placed(r.values), {"db": "agent", "web": "both"})
        self.assertEqual(P.monitor_placed(P.resolve("dev-budget", BASE).values), {})
        self.assertTrue(
            any("unknown stack 'zabbix'" in m for m in errors("dev-budget", MONITOR_STACKS="beszel,zabbix"))
        )
        self.assertTrue(
            any("'none' cannot be combined" in m for m in errors("dev-budget", MONITOR_STACKS="none,kuma"))
        )
        # heavy hub next to the DB on 2 GB is refused, like monitor.sh's RAM gate
        heavy = errors("dev-budget", MONITOR_STACKS="prometheus", MONITOR_HUB="db")
        self.assertTrue(any("next to the database" in m for m in heavy))
        self.assertFalse(
            any("next to the database" in m for m in errors("dev-budget", MONITOR_STACKS="prometheus"))
        )
        self.assertFalse(
            any(
                "next to the database" in m
                for m in errors(
                    "dev-budget", MONITOR_STACKS="prometheus", MONITOR_HUB="db", MONITOR_ALLOW_TIGHT="1"
                )
            )
        )
        self.assertTrue(any("netdata" in m for m in errors("dev-budget", MONITOR_STACKS="netdata")))
        self.assertTrue(
            any(
                "MONITOR_HUB=db" in m for m in errors("production-ha", ALERT_EMAIL="a@b.co", MONITOR_HUB="db")
            )
        )
        self.assertTrue(
            any(
                "not an http(s) URL" in m
                for m in errors("dev-budget", MONITOR_STACKS="kuma", MONITOR_PROBE_URLS="ftp://x")
            )
        )

    def test_monitoring_ram_and_render(self):
        r = P.resolve(
            "dev-budget", {**BASE, "MONITOR_STACKS": "beszel,prometheus", "DB_PRIVATE_IP": "10.10.0.5"}
        )
        plan = P.ram_plan(r.values)
        self.assertIn("beszel-agent", plan["db"][2])
        self.assertIn("prometheus-agent", plan["db"][2])
        self.assertIn("prometheus", plan["web"][2])
        hub = P.render_monitor(r, "web", "now")
        self.assertIn("MONITOR_ROLE=both", hub)
        self.assertIn("MONITOR_TARGETS=db=10.10.0.5", hub)
        self.assertIn("MONITOR_PG_TARGETS=db", hub)
        agent = P.render_monitor(r, "db", "now")
        self.assertIn("MONITOR_ROLE=agent", agent)
        self.assertIn("MONITOR_AGENT_BIND=10.10.0.5", agent)
        self.assertIn("MONITOR_BESZEL_KEY_FILE=", agent)
        self.assertNotRegex(hub + agent, r"(?m)^[A-Z_]*(PASSWORD|SECRET|TOKEN)[A-Z_]*=")

    def test_reference_doc_table_is_current(self):
        doc = (P.repo_root() / "docs" / "reference" / "profiles.md").read_text()
        self.assertIn(P.markdown_table(), doc, "regenerate with: bin/workbench profile table")
        for key in P.defaults():
            if key not in P.META:
                self.assertIn(f"`{key}`", doc, key)

    def test_diff(self):
        rows = dict(
            (k, (a, b))
            for k, a, b in P.diff(P.resolve("dev-budget").values, P.resolve("production-single").values)
        )
        self.assertEqual(rows["PITR"], ("off", "pgbackrest"))
        self.assertNotIn("PROFILE_VERSION", rows)


class ConfigureCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "acme"
        self.argv = [
            "configure",
            "--non-interactive",
            "--profile",
            "dev-budget",
            "--client",
            "acme",
            "--set",
            "APP=demo",
            "--out-dir",
            str(self.out),
        ]

    def tearDown(self):
        self.tmp.cleanup()

    def test_writes_600_files_and_next_commands_end_with_upgrade_dry_run(self):
        rc, out, _ = run(
            [*self.argv, "--set", "STORAGE=garage", "--set", "GOTENBERG=1", "--set", "WEB_DROPLET_MB=4096"]
        )
        self.assertEqual(rc, 0)
        for name in ("workbench.conf", "db-server.conf", "addons-db.conf", "addons-web.conf"):
            mode = stat.S_IMODE(os.stat(self.out / name).st_mode)
            self.assertEqual(mode, 0o600, name)
        nxt = out.split("\nnext:\n", 1)[1].strip().splitlines()
        self.assertIn("/root/docker-db-server-manager.sh upgrade --dry-run", nxt[-1])
        self.assertIn("addon.sh plan garage", out)
        self.assertIn("ADDON_ROLE=web", (self.out / "addons-web.conf").read_text())

    def test_dry_run_writes_nothing(self):
        rc, out, _ = run([*self.argv, "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("--dry-run: nothing written", out)
        self.assertFalse(self.out.exists())

    def test_validation_error_writes_nothing(self):
        rc, _, err = run([*self.argv, "--set", "ENABLE_MYSQL=1", "--set", "ENABLE_MARIADB=1"])
        self.assertEqual(rc, 1)
        self.assertIn("nothing written", err)
        self.assertFalse(self.out.exists())

    def test_rerun_needs_yes_and_keeps_backup(self):
        self.assertEqual(run(self.argv)[0], 0)
        rc, out, _ = run(self.argv)
        self.assertEqual(rc, 0)
        self.assertIn("nothing to write", out)
        rc, _, err = run([*self.argv, "--set", "RETENTION=daily=3"])
        self.assertEqual(rc, 1)
        self.assertIn("--yes", err)
        rc, out, _ = run([*self.argv, "--set", "RETENTION=daily=3", "--yes"])
        self.assertEqual(rc, 0)
        self.assertTrue(list(self.out.glob("db-server.conf.bak.*")))
        self.assertIn("RETENTION=daily=3", (self.out / "db-server.conf").read_text())

    def test_keep_reapplies_earlier_overrides(self):
        run([*self.argv, "--set", "RETENTION=daily=3"])
        rc, out, _ = run(
            [
                "configure",
                "--non-interactive",
                "--client",
                "acme",
                "--out-dir",
                str(self.out),
                "--keep",
                "--set",
                "OFFSITE_BUCKET=bk",
                "--yes",
            ]
        )
        self.assertEqual(rc, 0, out)
        text = (self.out / "db-server.conf").read_text()
        self.assertIn("RETENTION=daily=3", text)
        self.assertIn("OFFSITE_BUCKET=bk", text)

    def test_engine_turned_off_lists_disable_first(self):
        run([*self.argv, "--set", "ENABLE_ADMINER=1"])
        rc, out, _ = run([*self.argv, "--yes"])
        self.assertEqual(rc, 0, out)
        nxt = out.split("\nnext:\n", 1)[1]
        self.assertIn("engine disable adminer --dry-run", nxt)
        self.assertLess(nxt.index("engine disable adminer"), nxt.index("scp "))

    def test_refuses_tracked_folder_inside_repo(self):
        rc, _, err = run(
            [
                "configure",
                "--non-interactive",
                "--profile",
                "dev-budget",
                "--client",
                "acme",
                "--set",
                "APP=demo",
                "--out-dir",
                str(P.repo_root() / "docs" / "nope"),
                "--dry-run",
            ]
        )
        self.assertEqual(rc, 1)
        self.assertIn("not git-ignored", err)

    def test_managed_db_writes_no_db_conf(self):
        rc, out, _ = run(
            [
                "configure",
                "--non-interactive",
                "--profile",
                "production-ha",
                "--client",
                "acme",
                "--set",
                "APP=demo",
                "--set",
                "ALERT_EMAIL=ops@example.com",
                "--out-dir",
                str(self.out),
            ]
        )
        self.assertEqual(rc, 0, out)
        self.assertFalse((self.out / "db-server.conf").exists())
        self.assertNotIn("upgrade --dry-run", out)

    def test_interactive_wizard(self):
        answers = iter(
            ["dev-budget", "beta", "shop", "", "", "", "", "", "", "", "", "OFFSITE_BUCKET=b1", "", ""]
        )
        with mock.patch("builtins.input", lambda _prompt: next(answers)):
            rc, out, _ = run(["configure", "--out-dir", str(self.out)])
        self.assertEqual(rc, 0, out)
        text = (self.out / "workbench.conf").read_text()
        self.assertIn("CLIENT=beta", text)
        self.assertIn("OFFSITE_BUCKET=b1", text)

    def test_profile_commands(self):
        rc, out, _ = run(["profile", "list"])
        self.assertEqual(rc, 0)
        self.assertIn("production-single", out)
        rc, out, _ = run(["profile", "show", "dev-budget"])
        self.assertIn("* ENVS=tst dev stg", out)
        rc, out, _ = run(["profile", "diff", "dev-budget", "production-single"])
        self.assertIn("PITR", out)
        rc, out, _ = run(["profile", "show", "production-single", "--check"])
        self.assertEqual(rc, 1)
        self.assertEqual(run(["profile", "show", "nope"])[0], 2)


if __name__ == "__main__":
    unittest.main()
