#!/usr/bin/env python3
"""Exercise fleet output and exit codes without network or device collectors."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

FLEET = Path(__file__).resolve().parents[1] / "scripts/fleet-smoke.sh"


def smoke(status="ok", record_status="pass"):
    return {
        "schema_version": 1,
        "status": status,
        "failures": int(record_status == "fail"),
        "warnings": int(record_status == "warn"),
        "records": [{"status": record_status, "msg": "original check"}],
    }


class FleetResultsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="fleet-results-")
        cls.bin = Path(cls.tmp.name) / "bin"
        cls.bin.mkdir()
        cls.install_stub(
            "curl",
            """#!/usr/bin/env python3
import json
print(json.dumps({"result": {"server": {"host": {"name": "server"}, "groups": [
    {"clients": [
        {"id": "client", "connected": True, "host": {"name": "client", "os": "Debian GNU/Linux"}},
        {"id": "phone", "connected": True, "host": {"name": "phone", "os": "iOS"}}
    ]}
]}}}))
""",
        )
        cls.install_stub(
            "ssh",
            """#!/usr/bin/env python3
import json
import os
import subprocess
import sys

host = sys.argv[-2].split("@")[-1]
assert host in ("server", "client"), "unexpected SSH target"
payload = sys.stdin.read()
env = os.environ.copy()
if host != env.get("TARGET_HOST", "server"):
    env["RAW_SMOKE"] = env["PASS_SMOKE"]
    env["SMOKE_RC"] = "0"
    env["NO_VERSION"] = ""
    env["NO_SCRIPT"] = ""
elif env.get("BROKEN_ENVELOPE"):
    print("not a remote JSON envelope")
    sys.exit(0)

# Run only the actual smoke capture/encoding tail. Never run the version
# readers or collectors: sudo is a function returning synthetic stdout/rc.
marker = 'if [ -n "$smoke_script" ]; then'
assert marker in payload
tail = marker + payload.split(marker, 1)[1]
prefix = '''
sudo() { printf '%s' "$RAW_SMOKE"; return "$SMOKE_RC"; }
smoke_script=/synthetic/device-smoke.sh
[ -z "${NO_SCRIPT:-}" ] || smoke_script=""
srv_build=v0.8.5 cli_build="" srv_release=v0.8.5 cli_release=""
if [ -n "${NO_VERSION:-}" ]; then srv_build=""; srv_release=""; fi
'''
result = subprocess.run([env.get("FLEET_TEST_BASH", "bash"), "-c", prefix + tail],
                        env=env, capture_output=True, text=True, check=False)
sys.stdout.write("Synthetic login banner\\n" + result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
""",
        )
        for name in ("timeout", "gtimeout"):
            cls.install_stub(name, '#!/usr/bin/env bash\nshift\nexec "$@"\n')

    @classmethod
    def install_stub(cls, name, content):
        path = cls.bin / name
        path.write_text(content)
        path.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_fleet(self, raw, rc=0, text=False, **extra):
        env = os.environ.copy()
        env.update(
            PATH=f"{self.bin}{os.pathsep}{env['PATH']}",
            RAW_SMOKE=raw,
            SMOKE_RC=str(rc),
            PASS_SMOKE=json.dumps(smoke()),
        )
        env.pop("__FLEET_SMOKE_LIB_ONLY", None)
        env.update(extra)
        args = [env.get("FLEET_TEST_BASH", "bash"), str(FLEET), "--server", "server"]
        if not text:
            args.append("--json")
        result = subprocess.run(
            args, env=env, capture_output=True, text=True, timeout=20, check=False
        )
        if text:
            return result
        data = json.loads(result.stdout)
        self.assertEqual(len(data["hosts"]), 2)
        self.assertEqual(data["connected_non_snapmulti_clients"][0]["name"], "phone")
        target = next(
            h for h in data["hosts"] if h["host"] == extra.get("TARGET_HOST", "server")
        )
        return result, target

    def test_invalid_results_fail_instead_of_pass_or_skip(self):
        invalid = [
            "",
            "{}",
            "not-json",
            '{"schema_version":',
            "null",
            "[]",
            json.dumps({**smoke(), "records": []}),
            json.dumps({**smoke(), "schema_version": 999}),
            json.dumps({**smoke(), "records": "wrong type"}),
            json.dumps({**smoke(), "records": [{"status": "unknown"}]}),
            json.dumps({**smoke(), "status": "unknown"}),
            json.dumps({**smoke(), "status": "fail"}),
            json.dumps({**smoke(), "failures": 1}),
            json.dumps(smoke()) + "\n{}",
        ]
        for raw in invalid:
            with self.subTest(raw=raw):
                result, host = self.run_fleet(raw)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse(host.get("non_snapmulti", False))
                self.assertEqual(host["error"], "smoke-invalid")
                self.assertEqual(host["versions"]["server"], "v0.8.5")
                self.assertEqual(host["smoke_exit_code"], 0)
                self.assertTrue(
                    any(r["status"] == "fail" for r in host["smoke"]["records"])
                )

    def test_valid_failure_keeps_original_records(self):
        failed = smoke("fail", "fail")
        result, host = self.run_fleet(json.dumps(failed), rc=1)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(host["smoke"], failed)
        self.assertEqual(host["smoke_exit_code"], 1)

    def test_pass_and_warning_remain_successful(self):
        for status, record in (("ok", "pass"), ("warn", "warn")):
            with self.subTest(status=status):
                document = smoke(status, record)
                result, host = self.run_fleet(json.dumps(document))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(host["smoke"], document)

    def test_process_failure_cannot_pass_with_valid_pass_json(self):
        for rc in (1, 2, 137):
            with self.subTest(rc=rc):
                result, host = self.run_fleet(json.dumps(smoke()), rc=rc)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(host["error"], "smoke-exit-error")
                self.assertEqual(host["smoke_exit_code"], rc)

    def test_missing_script_and_unknown_version_cannot_skip_target(self):
        for target in ("server", "client"):
            with self.subTest(target=target):
                result, host = self.run_fleet(
                    "", NO_SCRIPT="1", NO_VERSION="1", TARGET_HOST=target
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(host["error"], "smoke-invalid")
                self.assertEqual(host["smoke_exit_code"], 127)
                self.assertFalse(host.get("non_snapmulti", False))

    def test_broken_remote_envelope_fails(self):
        result, host = self.run_fleet("", BROKEN_ENVELOPE="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(host["error"], "smoke-invalid")

    def test_text_verdict_matches_json(self):
        result = self.run_fleet("{}", text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Overall: FAIL", result.stdout)
        self.assertIn("smoke-invalid", result.stdout)
        self.assertIn("1/2 reachable", result.stdout)
        self.assertIn("phone", result.stdout)


if __name__ == "__main__":
    unittest.main()
