#!/usr/bin/env python3
"""Exercise the production installer in temporary folders with injected tool failures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = (Path(__file__).resolve().parent.parent / "Resources/install-update.sh").read_text()


class InstallerTests(unittest.TestCase):
    def exercise(self, failure="", parent_running=False):
        with tempfile.TemporaryDirectory(prefix="orbit update '") as temporary:
            root = Path(temporary)
            app = root / "Orbit's Space.app"
            stage = root / ".Orbit-update-fixture"
            app.mkdir()
            (app / "version").write_text("old")
            (stage / "Orbit.app").mkdir(parents=True)
            (stage / "Orbit.app/version").write_text("new")
            move = root / "move"
            move.write_text('''#!/bin/sh
case "$FAILURE:$1" in
  backup:*Space.app|replace:*/Orbit.app|restore:*/Orbit.app|restore:*/previous.app) exit 1 ;;
esac
exec /bin/mv "$@"
''')
            launch = root / "launch"
            launch.write_text('''#!/bin/sh
if [ "$FAILURE" = launch ] && [ "$(/bin/cat "$1/version")" = new ]; then exit 1; fi
/bin/cat "$1/version" >> "$LAUNCH_LOG"
''')
            move.chmod(0o700)
            launch.chmod(0o700)
            script = root / "installer.sh"
            # Inject tools only in this test copy; installation logic stays verbatim.
            script.write_text(INSTALLER.replace("/bin/mv", '"$MOVE_TOOL"')
                              .replace("/usr/bin/open", '"$LAUNCH_TOOL"')
                              .replace("/bin/sleep 1", ":"))
            environment = dict(os.environ, FAILURE=failure, MOVE_TOOL=str(move),
                               LAUNCH_TOOL=str(launch), LAUNCH_LOG=str(root / "launch.log"))
            result = subprocess.run(["/bin/sh", str(script), str(os.getpid() if parent_running else 99999999),
                                     str(app), str(stage)], env=environment, capture_output=True, text=True, timeout=10)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(len(events), 1, result.stderr)
            self.assertEqual(events[0]["action"]["outcome"], "failure" if failure or parent_running else "success")
            if failure == "restore":
                self.assertEqual((stage / "previous.app/version").read_text(), "old")
                self.assertFalse(app.exists())
            else:
                self.assertEqual((app / "version").read_text(), "old" if failure or parent_running else "new")
                self.assertFalse(stage.exists())
            if not parent_running and failure != "restore":
                self.assertEqual((root / "launch.log").read_text(), "old" if failure else "new")

    def test_success(self):
        self.exercise()

    def test_backup_failure_preserves_app(self):
        self.exercise("backup")

    def test_replacement_failure_restores_app(self):
        self.exercise("replace")

    def test_launch_failure_restores_app(self):
        self.exercise("launch")

    def test_failed_restore_preserves_backup(self):
        self.exercise("restore")

    def test_cancelled_termination_preserves_running_app(self):
        self.exercise(parent_running=True)


if __name__ == "__main__":
    unittest.main()
