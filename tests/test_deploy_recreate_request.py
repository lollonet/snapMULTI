"""Exercise the generated deploy-only recreation command with isolated stubs."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


DEPLOY = Path(__file__).resolve().parents[1] / "scripts/deploy.sh"


class DeployRecreateRequestTests(unittest.TestCase):
    def test_recreate_order_and_lifecycle(self):
        source = DEPLOY.read_text()
        prefix = "ExecStartPre=/bin/sh -c '"
        line = next(
            line
            for line in source.splitlines()
            if line.startswith(prefix) and "snapmulti-server-recreate" in line
        )
        command = line[len(prefix) : -1]
        self.assertLess(
            source.index("ExecStartPre=/usr/local/sbin/restore-snapmulti-state"),
            source.index(line),
        )
        self.assertLess(
            source.index("touch /run/snapmulti-server-recreate"),
            source.index("if ! systemctl restart snapmulti-server.service"),
        )
        self.assertNotIn("ExecStartPre=-", line)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker = root / "recreate"
            memory = root / "memory"
            docker = root / "docker"
            docker.write_text(
                '#!/bin/sh\n[ "$*" = "compose up -d --force-recreate" ] || exit 99\n'
                '[ "${FAIL_RECREATE:-0}" = 0 ] || exit 42\n'
                f"printf '192M' > '{memory}'\n"
            )
            docker.chmod(0o755)
            command = command.replace("/run/snapmulti-server-recreate", str(marker))
            command = command.replace("/usr/bin/docker", str(docker))
            command = command.replace("/usr/bin/rm", "/bin/rm")

            def run(fail="0"):
                return subprocess.run(
                    ["/bin/sh", "-c", command],
                    env={**os.environ, "FAIL_RECREATE": fail},
                    check=False,
                ).returncode

            memory.write_text("128M")
            self.assertEqual(run(), 0)
            self.assertEqual(memory.read_text(), "128M")
            marker.touch()
            self.assertEqual(run("1"), 42)
            self.assertTrue(marker.exists())
            self.assertEqual(memory.read_text(), "128M")
            self.assertEqual(run(), 0)
            self.assertEqual(memory.read_text(), "192M")
            self.assertFalse(marker.exists())
            # No request: an ordinary restart must not invoke Docker again.
            self.assertEqual(run("1"), 0)


if __name__ == "__main__":
    unittest.main()
