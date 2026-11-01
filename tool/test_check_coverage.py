"""Exercise fail-closed coverage parsing and the actual command's exit status."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_coverage import line_coverage


class CoverageGateTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.report = Path(self.directory.name) / "lcov.info"

    def test_duplicate_records_merge_hits_without_inflating_lines(self):
        self.report.write_text(
            "SF:lib/app.dart\nDA:1,0\nDA:2,1\nend_of_record\n"
            "SF:lib/app.dart\nDA:1,2\nend_of_record\n", encoding="utf-8")
        self.assertEqual(line_coverage(self.report), (2, 2))

    def test_empty_incomplete_and_invalid_reports_fail(self):
        for text in ("", "SF:lib/app.dart\nDA:1,1\n", "DA:1,1\nend_of_record\n",
                     "SF:lib/app.dart\nDA:1,-1\nend_of_record\n"):
            with self.subTest(text=text):
                self.report.write_text(text, encoding="utf-8")
                with self.assertRaises(ValueError):
                    line_coverage(self.report)

    def test_cli_boundary_failure_and_invalid_threshold(self):
        self.report.write_text("SF:lib/app.dart\nDA:1,1\nDA:2,0\nend_of_record\n", encoding="utf-8")
        script = str(Path(__file__).with_name("check_coverage.py"))
        for threshold, expected in (("50", 0), ("50.01", 1), ("nan", 2), ("101", 2)):
            with self.subTest(threshold=threshold):
                result = subprocess.run([sys.executable, script, str(self.report), "--minimum", threshold],
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
