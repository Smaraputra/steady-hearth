import contextlib
import io
import os
import sys
import tempfile
import unittest

import unittest.mock

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tools.bench_layout import check_layout, format_violation, main, parse_layout, render_png


class TestBenchLayout(unittest.TestCase):
    def test_parse_fields_order_and_filtering(self):
        lines = [
            "2026-10-29 11:03:00.000000 | server | 0 | mod perf_bench | PERF_BENCH|setup|status=starting\n",
            "2026-10-29 11:03:10.701655 | server | 0 | mod perf_bench | PERF_BENCH|layout|z1=16|kind=tree|x0=-40|player=map|z0=12|x1=-36|id=t1\n",
            "2026-10-29 11:03:11.000000 | server | 0 | mod perf_bench | PERF_BENCH|kpi|fps=60\n",
            "Unrelated log message\n",
            "PERF_BENCH|layout|kind=building|player=player_1|x0=10|x1=20|z0=10|z1=20\n",
        ]
        map_rect, features = parse_layout(lines)
        self.assertEqual(map_rect["x0"], -256)
        self.assertEqual(map_rect["x1"], 256)
        self.assertEqual(map_rect["z0"], -256)
        self.assertEqual(map_rect["z1"], 256)
        self.assertEqual(len(features), 2)

        f0 = features[0]
        self.assertEqual(f0["kind"], "tree")
        self.assertEqual(f0["player"], "map")
        self.assertEqual(f0["x0"], -40)
        self.assertEqual(f0["x1"], -36)
        self.assertEqual(f0["z0"], 12)
        self.assertEqual(f0["z1"], 16)
        self.assertEqual(f0["id"], "t1")
        self.assertEqual(f0["line"], 2)

        f1 = features[1]
        self.assertEqual(f1["kind"], "building")
        self.assertEqual(f1["player"], "player_1")
        self.assertEqual(f1["x0"], 10)
        self.assertEqual(f1["x1"], 20)
        self.assertEqual(f1["z0"], 10)
        self.assertEqual(f1["z1"], 20)
        self.assertIsNone(f1["id"])
        self.assertEqual(f1["line"], 5)

    def test_default_map_bounds_when_no_map_line(self):
        lines = [
            "PERF_BENCH|layout|kind=tree|player=map|x0=0|x1=4|z0=0|z1=4\n",
        ]
        map_rect, features = parse_layout(lines)
        self.assertEqual(map_rect["kind"], "map")
        self.assertEqual(map_rect["player"], "map")
        self.assertEqual(map_rect["x0"], -256)
        self.assertEqual(map_rect["z0"], -256)
        self.assertEqual(map_rect["x1"], 256)
        self.assertEqual(map_rect["z1"], 256)
        self.assertEqual(len(features), 1)

        custom_map_lines = [
            "PERF_BENCH|layout|kind=map|player=map|x0=-100|x1=100|z0=-120|z1=120\n",
            "PERF_BENCH|layout|kind=tree|player=map|x0=0|x1=4|z0=0|z1=4\n",
        ]
        map_rect_custom, features_custom = parse_layout(custom_map_lines)
        self.assertEqual(map_rect_custom["x0"], -100)
        self.assertEqual(map_rect_custom["x1"], 100)
        self.assertEqual(map_rect_custom["z0"], -120)
        self.assertEqual(map_rect_custom["z1"], 120)

    def test_out_of_bounds_and_exclusive_max(self):
        map_rect = {"kind": "map", "player": "map", "x0": -100, "z0": -100, "x1": 100, "z1": 100, "id": None, "line": 1}
        # Exactly touching map boundaries on exclusive max (x1 == 100, z1 == 100)
        at_boundary = {"kind": "tree", "player": "map", "x0": 90, "x1": 100, "z0": 90, "z1": 100, "id": None, "line": 2}
        violations = check_layout(map_rect, [at_boundary])
        self.assertEqual(violations, [])

        # x1 > map.x1
        oob_x1 = {"kind": "tree", "player": "map", "x0": 90, "x1": 101, "z0": 0, "z1": 10, "id": None, "line": 3}
        violations = check_layout(map_rect, [oob_x1])
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0]["type"], "out_of_bounds")
        self.assertEqual(violations[0]["a"], oob_x1)
        self.assertIsNone(violations[0]["b"])

        # x0 < map.x0
        oob_x0 = {"kind": "tree", "player": "map", "x0": -101, "x1": -90, "z0": 0, "z1": 10, "id": None, "line": 4}
        violations = check_layout(map_rect, [oob_x0])
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0]["type"], "out_of_bounds")

        # z1 > map.z1
        oob_z1 = {"kind": "tree", "player": "map", "x0": 0, "x1": 10, "z0": 90, "z1": 101, "id": None, "line": 5}
        violations = check_layout(map_rect, [oob_z1])
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0]["type"], "out_of_bounds")

        # z0 < map.z0
        oob_z0 = {"kind": "tree", "player": "map", "x0": 0, "x1": 10, "z0": -101, "z1": -90, "id": None, "line": 6}
        violations = check_layout(map_rect, [oob_z0])
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0]["type"], "out_of_bounds")

    def test_touching_rectangles_do_not_overlap(self):
        map_rect = {"kind": "map", "player": "map", "x0": -100, "z0": -100, "x1": 100, "z1": 100, "id": None, "line": 1}
        # a.x1 == b.x0 touches on edge
        a = {"kind": "tree", "player": "map", "x0": 0, "x1": 10, "z0": 0, "z1": 10, "id": None, "line": 2}
        b = {"kind": "tree", "player": "map", "x0": 10, "x1": 20, "z0": 0, "z1": 10, "id": None, "line": 3}
        violations = check_layout(map_rect, [a, b])
        self.assertEqual(violations, [])

        # a.z1 == c.z0 touches on edge
        c = {"kind": "tree", "player": "map", "x0": 0, "x1": 10, "z0": 10, "z1": 20, "id": None, "line": 4}
        violations = check_layout(map_rect, [a, c])
        self.assertEqual(violations, [])

    def test_two_trees_intersect_causes_one_overlap_violation(self):
        map_rect = {"kind": "map", "player": "map", "x0": -100, "z0": -100, "x1": 100, "z1": 100, "id": None, "line": 1}
        t1 = {"kind": "tree", "player": "map", "x0": 0, "x1": 10, "z0": 0, "z1": 10, "id": None, "line": 2}
        t2 = {"kind": "tree", "player": "map", "x0": 5, "x1": 15, "z0": 5, "z1": 15, "id": None, "line": 3}
        violations = check_layout(map_rect, [t1, t2])
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0]["type"], "overlap")
        self.assertIn(violations[0]["a"], (t1, t2))
        self.assertIn(violations[0]["b"], (t1, t2))
        self.assertNotEqual(violations[0]["a"], violations[0]["b"])

    def test_allowed_overlaps(self):
        map_rect = {"kind": "map", "player": "map", "x0": -100, "z0": -100, "x1": 100, "z1": 100, "id": None, "line": 1}
        ridge1 = {"kind": "ridge", "player": "map", "x0": 0, "x1": 50, "z0": 0, "z1": 20, "id": None, "line": 2}
        ridge2 = {"kind": "ridge", "player": "map", "x0": 20, "x1": 30, "z0": -20, "z1": 40, "id": None, "line": 3}
        tree = {"kind": "tree", "player": "map", "x0": 5, "x1": 15, "z0": 5, "z1": 15, "id": None, "line": 4}
        pass_feat = {"kind": "pass", "player": "map", "x0": 22, "x1": 28, "z0": 2, "z1": 18, "id": None, "line": 5}

        # tree on ridge allowed
        self.assertEqual(check_layout(map_rect, [ridge1, tree]), [])
        # pass on ridge allowed
        self.assertEqual(check_layout(map_rect, [ridge1, pass_feat]), [])
        # ridge crossing ridge allowed
        self.assertEqual(check_layout(map_rect, [ridge1, ridge2]), [])

    def test_rabbit_overlapping_building_is_exempt(self):
        map_rect = {"kind": "map", "player": "map", "x0": -100, "z0": -100, "x1": 100, "z1": 100, "id": None, "line": 1}
        rabbit = {"kind": "rabbit", "player": "map", "x0": 10, "x1": 14, "z0": 10, "z1": 14, "id": None, "line": 2}
        bldg = {"kind": "building", "player": "player_1", "x0": 5, "x1": 20, "z0": 5, "z1": 20, "id": None, "line": 3}
        violations = check_layout(map_rect, [rabbit, bldg])
        self.assertEqual(violations, [])

    def test_lake_overlapping_tree_is_violation(self):
        map_rect = {"kind": "map", "player": "map", "x0": -100, "z0": -100, "x1": 100, "z1": 100, "id": None, "line": 1}
        lake = {"kind": "lake", "player": "map", "x0": 0, "x1": 30, "z0": 0, "z1": 30, "id": None, "line": 2}
        tree = {"kind": "tree", "player": "map", "x0": 10, "x1": 14, "z0": 10, "z1": 14, "id": None, "line": 3}
        violations = check_layout(map_rect, [lake, tree])
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0]["type"], "overlap")

    def test_main_cli(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            # 1. Clean run directory
            clean_log = os.path.join(tmp_dir, "stonehearth.log")
            with open(clean_log, "w") as f:
                f.write("2026-10-29 11:03:10.701655 | server | 0 | mod perf_bench | PERF_BENCH|layout|kind=tree|player=map|x0=-40|x1=-36|z0=12|z1=16\n")
                f.write("2026-10-29 11:03:11.701655 | server | 0 | mod perf_bench | PERF_BENCH|layout|kind=building|player=player_1|x0=0|x1=10|z0=0|z1=10\n")

            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = main(["bench_layout.py", tmp_dir, "--no-image"])
            self.assertEqual(code, 0)
            output = out.getvalue()
            self.assertIn("building: 1", output)
            self.assertIn("tree: 1", output)
            self.assertIn("OK", output)

            # 2. Run directory with violation
            with open(clean_log, "a") as f:
                f.write("2026-10-29 11:03:12.701655 | server | 0 | mod perf_bench | PERF_BENCH|layout|kind=tree|player=map|x0=-38|x1=-34|z0=14|z1=18|id=bad_tree\n")

            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = main(["bench_layout.py", clean_log, "--no-image"])
            self.assertEqual(code, 1)
            output = out.getvalue()
            self.assertIn("overlap: ", output)
            self.assertIn("1 violations", output)

            # 3. Log with no layout lines
            empty_log = os.path.join(tmp_dir, "empty.log")
            with open(empty_log, "w") as f:
                f.write("2026-10-29 11:03:10.701655 | server | 0 | mod perf_bench | PERF_BENCH|setup|status=starting\n")

            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = main(["bench_layout.py", empty_log, "--no-image"])
            self.assertEqual(code, 2)

    def test_violation_formatting(self):
        f1 = {"kind": "tree", "player": "map", "x0": -40, "x1": -36, "z0": 12, "z1": 16, "id": None, "line": 812}
        f2 = {"kind": "supply", "player": "player_1", "x0": -38, "x1": -30, "z0": 14, "z1": 20, "id": "sup1", "line": 820}
        overlap_v = {"type": "overlap", "a": f1, "b": f2}
        msg = format_violation(overlap_v)
        self.assertEqual(
            msg,
            "overlap: tree (player=map, x0..x1=-40..-36, z0..z1=12..16, line 812) and supply (id=sup1, player=player_1, x0..x1=-38..-30, z0..z1=14..20, line 820)"
        )

        oob_v = {"type": "out_of_bounds", "a": f1, "b": None}
        self.assertEqual(
            format_violation(oob_v),
            "out_of_bounds: tree (player=map, x0..x1=-40..-36, z0..z1=12..16, line 812)"
        )

    def test_render_png_missing_pillow(self):
        with unittest.mock.patch.dict(sys.modules, {"PIL": None}):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                res = render_png(
                    {"kind": "map", "player": "map", "x0": -256, "z0": -256, "x1": 256, "z1": 256},
                    [],
                    [],
                    "layout.png"
                )
            self.assertFalse(res)
            self.assertIn("Pillow not available, no image written", err.getvalue())

    def test_render_png_success_if_available(self):
        try:
            import PIL  # noqa: F401
            has_pillow = True
        except ImportError:
            has_pillow = False

        if not has_pillow:
            return

        with tempfile.TemporaryDirectory() as tmp_dir:
            png_path = os.path.join(tmp_dir, "layout.png")
            map_rect = {"kind": "map", "player": "map", "x0": -64, "z0": -64, "x1": 64, "z1": 64}
            features = [
                {"kind": "tree", "player": "map", "x0": -10, "x1": 0, "z0": -10, "z1": 0, "id": None, "line": 1},
                {"kind": "unknown_thing", "player": "player_1", "x0": 10, "x1": 20, "z0": 10, "z1": 20, "id": None, "line": 2},
            ]
            violations = [{"type": "out_of_bounds", "a": features[0], "b": None}]
            res = render_png(map_rect, features, violations, png_path)
            self.assertTrue(res)
            self.assertTrue(os.path.exists(png_path))
            self.assertGreater(os.path.getsize(png_path), 0)


if __name__ == "__main__":
    unittest.main()
