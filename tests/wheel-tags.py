from pathlib import Path
import runpy
import unittest


class WheelTags(unittest.TestCase):
    def test_prefilter(self):
        cases = [
            ("cp313-cp313-win_amd64", "3.13.18", True),
            ("cp311-abi3-win_amd64", "3.14.6", True),
            ("cp314-abi3-win_amd64", "3.13.18", False),
            ("cp313-cp313t-win_amd64", "3.13.18", False),
            ("py2.py3-none-any", "3.11.9", True),
            ("py312-none-any", "3.11.9", False),
            ("py3-none-win32.win_amd64", "3.12.10", True),
            ("cp313-cp313-win_arm64", "3.13.18", False),
            ("cp313-cp313-manylinux_2_28_x86_64", "3.13.18", False),
            ("cp315-cp315-win_amd64", "3.15.2", True),
            ("cp315-cp315t-win_amd64", "3.15.2", False),
            ("cp311-abi3-win_amd64", "3.15.2", True),
            ("cp314-cp314-win_amd64", "3.15.2", False),
        ]
        match = runpy.run_path(str(Path(__file__).resolve().parents[1] / "preloaded" / "prepare.py"))["compatible_wheel"]
        for tags, version, expected in cases:
            with self.subTest(tags=tags, version=version):
                self.assertEqual(match(f"example-1.0-{tags}.whl", version), expected)


if __name__ == "__main__":
    unittest.main()
