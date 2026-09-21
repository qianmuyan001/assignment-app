"""Keep the Web rule suite in the existing backend unittest/CI entry point."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest


class WebRuleSuiteTests(unittest.TestCase):
    def test_web_rules_with_node(self):
        node = os.environ.get("NODE_EXECUTABLE") or shutil.which("node")
        self.assertIsNotNone(node, "Node.js 18+ is required for the Web rule tests")
        root = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [node, "--test", "backend/tests/web_ui.test.cjs"], cwd=root,
            text=True, capture_output=True, timeout=30, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
