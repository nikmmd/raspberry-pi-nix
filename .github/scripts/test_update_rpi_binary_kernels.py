"""Pure selection boundaries; run with python3 -m unittest discover -s .github/scripts."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "binary_updater", Path(__file__).with_name("update-rpi-binary-kernels.py")
)
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


def metadata(version):
    return {
        "8": f"Linux version {version}-v8+ vendor build\n",
        "_2712": f"Linux version {version}-v8-16k+ vendor build\n",
    }


def candidate(patch, series="6.18"):
    return (f"branch-{patch}", f"{patch:040x}", metadata(f"{series}.{patch}"))


class SelectionBoundaries(unittest.TestCase):
    def test_numeric_order_and_same_series(self):
        older_series = ("oldstable", "f" * 40, {"8": "Linux version 6.12.999-v8+ vendor build"})
        chosen = updater.select_candidate(
            "v6_18", metadata("6.18.9"),
            [candidate(99), older_series, candidate(100), candidate(10)],
        )
        self.assertEqual(chosen, candidate(100))

    def test_no_change_or_downgrade(self):
        for candidates in ([], [candidate(50)], [candidate(49), candidate(9)], [candidate(99, "6.12")]):
            with self.subTest(candidates=candidates):
                self.assertIsNone(updater.select_candidate("v6_18", metadata("6.18.50"), candidates))
        with self.assertRaises(ValueError):
            updater.select_candidate("v6_18", metadata("6.12.50"), [])

    def test_matching_series_bad_metadata_fails_closed(self):
        invalid = [
            {"8": "Linux version 6.18.51-v7+ vendor build", "_2712": metadata("6.18.51")["_2712"]},
            {"8": metadata("6.18.51")["8"], "_2712": "Linux version 6.18.51-v8+ vendor build"},
            {"8": metadata("6.18.51")["8"], "_2712": metadata("6.18.52")["_2712"]},
            {"8": metadata("6.18.51")["8"], "_2712": metadata("6.12.51")["_2712"]},
            {"8": metadata("6.18.51")["8"]},
            {"8": metadata("6.18.51")["8"], "_2712": "malformed metadata"},
            {"8": "malformed metadata", "_2712": metadata("6.18.51")["_2712"]},
        ]
        for broken in invalid:
            with self.subTest(metadata=broken), self.assertRaises(ValueError):
                updater.select_candidate(
                    "v6_18", metadata("6.18.50"),
                    [candidate(100), ("broken", "a" * 40, broken)],
                )


if __name__ == "__main__":
    unittest.main()
