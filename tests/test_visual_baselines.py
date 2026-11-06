import importlib.util
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "validate_visual_baselines",
    ROOT / "tools" / "validate_visual_baselines.py",
)
visual = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(visual)


def _chunk(kind: bytes, payload: bytes) -> bytes:
    import binascii

    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


def _write_rgb_png(path: Path, width: int, height: int, rows: list[list[tuple[int, int, int]]]):
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for r, g, b in row:
            raw.extend([r, g, b])
    data = (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + _chunk(b"IDAT", zlib.compress(bytes(raw)))
        + _chunk(b"IEND", b"")
    )
    path.write_bytes(data)


class VisualBaselineTest(unittest.TestCase):
    def test_png_reader_and_metrics_accept_palette_image(self):
        with tempfile.TemporaryDirectory() as td:
            shot_dir = Path(td) / "shots"
            target = shot_dir / "ableton-dark"
            target.mkdir(parents=True)
            cyan = (47, 198, 212)
            bg = (23, 25, 27)
            rows = [[cyan, bg, bg, bg], [bg, bg, cyan, bg]]
            _write_rgb_png(target / "arrange.png", 4, 2, rows)

            ok, report = visual.validate_baselines(
                screenshots_dir=shot_dir,
                surfaces=["arrange"],
                allow_missing=True,
                min_palette_hit_ratio=0.20,
                max_stock_leak_ratio=1.00,
                min_accent_ratio=0.10,
                tolerance=30.0,
                max_samples=100,
            )

        self.assertTrue(ok, report)
        ableton = [e for e in report["entries"] if e["slug"] == "ableton-dark"][0]
        self.assertFalse(ableton["missing"])
        self.assertGreaterEqual(ableton["accentRatio"], 0.10)
        self.assertEqual(ableton["stockLeakRatio"], 0.0)

    def test_missing_baselines_fail_without_allow_missing(self):
        with tempfile.TemporaryDirectory() as td:
            ok, report = visual.validate_baselines(
                screenshots_dir=Path(td) / "missing",
                surfaces=["arrange"],
                allow_missing=False,
                min_palette_hit_ratio=0.20,
                max_stock_leak_ratio=0.50,
                min_accent_ratio=0.0,
                tolerance=30.0,
                max_samples=100,
            )

        self.assertFalse(ok)
        self.assertTrue(report["failures"])

    def test_invalid_png_is_reported_without_crashing(self):
        with tempfile.TemporaryDirectory() as td:
            shot_dir = Path(td) / "shots"
            target = shot_dir / "ableton-dark"
            target.mkdir(parents=True)
            (target / "arrange.png").write_bytes(b"not a png")

            ok, report = visual.validate_baselines(
                screenshots_dir=shot_dir,
                surfaces=["arrange"],
                allow_missing=True,
                min_palette_hit_ratio=0.20,
                max_stock_leak_ratio=0.50,
                min_accent_ratio=0.0,
                tolerance=30.0,
                max_samples=100,
            )

        self.assertFalse(ok)
        invalid = [e for e in report["entries"] if e.get("invalid")]
        self.assertEqual(len(invalid), 1)
        self.assertIn("unreadable screenshot", report["failures"][0])

    def test_empty_surface_list_fails(self):
        with tempfile.TemporaryDirectory() as td:
            ok, report = visual.validate_baselines(
                screenshots_dir=Path(td),
                surfaces=[],
                allow_missing=True,
                min_palette_hit_ratio=0.20,
                max_stock_leak_ratio=0.50,
                min_accent_ratio=0.0,
                tolerance=30.0,
                max_samples=100,
            )
        self.assertFalse(ok)
        self.assertIn("at least one screenshot surface is required", report["failures"])

    def test_slug_filter_does_not_require_unrequested_presets(self):
        with tempfile.TemporaryDirectory() as td:
            shot_dir = Path(td) / "shots"
            target = shot_dir / "ableton-dark"
            target.mkdir(parents=True)
            cyan = (47, 198, 212)
            bg = (23, 25, 27)
            _write_rgb_png(target / "arrange.png", 2, 2, [[cyan, bg], [bg, cyan]])
            ok, report = visual.validate_baselines(
                screenshots_dir=shot_dir,
                surfaces=["arrange"],
                allow_missing=False,
                min_palette_hit_ratio=0.20,
                max_stock_leak_ratio=0.50,
                min_accent_ratio=0.10,
                tolerance=30.0,
                max_samples=100,
                slugs={"ableton-dark"},
            )
        self.assertTrue(ok, report)
        self.assertEqual({entry["slug"] for entry in report["entries"]}, {"ableton-dark"})

    def test_empty_slug_filter_fails(self):
        with tempfile.TemporaryDirectory() as td:
            ok, report = visual.validate_baselines(
                screenshots_dir=Path(td),
                surfaces=["arrange"],
                allow_missing=True,
                min_palette_hit_ratio=0.20,
                max_stock_leak_ratio=0.50,
                min_accent_ratio=0.0,
                tolerance=30.0,
                max_samples=100,
                slugs=set(),
            )
        self.assertFalse(ok)
        self.assertIn("at least one preset slug is required", report["failures"])

    def test_library_region_rejects_stock_yellow_or_neon_green(self):
        with tempfile.TemporaryDirectory() as td:
            shot_dir = Path(td) / "shots"
            target = shot_dir / "ableton-dark"
            target.mkdir(parents=True)
            cyan = (47, 198, 212)
            yellow = (220, 190, 20)
            rows = [[yellow, cyan, cyan, cyan] for _ in range(4)]
            _write_rgb_png(target / "library.png", 4, 4, rows)
            ok, report = visual.validate_baselines(
                screenshots_dir=shot_dir,
                surfaces=["library"],
                allow_missing=True,
                min_palette_hit_ratio=0.20,
                max_stock_leak_ratio=1.00,
                min_accent_ratio=0.0,
                tolerance=30.0,
                max_samples=100,
                slugs={"ableton-dark"},
            )
        self.assertFalse(ok)
        self.assertTrue(any("stock-yellow leak" in failure for failure in report["failures"]))

    def test_cli_default_requires_all_contract_surfaces(self):
        self.assertEqual(
            visual.DEFAULT_SURFACES,
            ("arrange", "mixer", "library", "new-track", "editor"),
        )

    def test_new_track_region_requires_a_visible_selected_state_accent(self):
        with tempfile.TemporaryDirectory() as td:
            shot_dir = Path(td) / "shots"
            target = shot_dir / "ableton-dark"
            target.mkdir(parents=True)
            bg = (23, 25, 27)
            _write_rgb_png(target / "new-track.png", 4, 4, [[bg] * 4 for _ in range(4)])
            ok, report = visual.validate_baselines(
                screenshots_dir=shot_dir,
                surfaces=["new-track"],
                allow_missing=True,
                min_palette_hit_ratio=0.20,
                max_stock_leak_ratio=1.00,
                min_accent_ratio=0.0,
                tolerance=30.0,
                max_samples=100,
                slugs={"ableton-dark"},
            )
        self.assertFalse(ok)
        self.assertTrue(any("selected-state-accent too low" in failure for failure in report["failures"]))


if __name__ == "__main__":
    unittest.main()
