#!/usr/bin/env python3
"""Run the Foundation-only prompt lifecycle/choice guard without devices or real saves.

Usage: python3 dm/ios/tests/test_webdav_conflicts.py
UIKit presentation still needs a simulator/device UI check.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class ConflictPrompts(unittest.TestCase):
    def test_lifecycle_and_exact_version_guard(self):
        with tempfile.TemporaryDirectory(prefix='d2r-conflict-prompts-') as folder:
            executable = str(Path(folder) / 'prompts')
            subprocess.run([
                'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                '-I' + str(ROOT / 'dm/ios/Sources'),
                str(ROOT / 'dm/ios/tests/webdav_conflicts.m'),
                str(ROOT / 'dm/ios/Sources/dm_webdav_conflicts.m'),
                '-framework', 'Foundation', '-o', executable,
            ], check=True)
            subprocess.run([executable], check=True, timeout=5)


if __name__ == '__main__':
    unittest.main()
