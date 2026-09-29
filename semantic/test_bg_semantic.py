#!/usr/bin/env python3
"""bg_semantic 的单元测试（stdlib unittest）。

运行：python3 -m unittest test_bg_semantic -v
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import bg_semantic as bg


def E(path: str, size: int = 1000, mtime: float = 1_727_400_000.0) -> bg.Entry:
    return bg.Entry(path, size, mtime)


class TestParsers(unittest.TestCase):
    def test_parse_restic_ls(self):
        text = "\n".join([
            json.dumps({"name": "/Users/neb/Documents", "type": "dir", "size": 0,
                        "struct_type": "node"}),
            json.dumps({"name": "/Users/neb/Documents/a.pdf", "type": "file", "size": 1234,
                        "mtime": "2026-09-28T12:00:00+08:00", "struct_type": "node"}),
        ])
        es = bg.parse_restic_ls(text, strip=2)
        self.assertEqual(len(es), 1)
        self.assertEqual(es[0].path, "Documents/a.pdf")
        self.assertEqual(es[0].size, 1234)

    def test_parse_restic_ls_path_field_wins(self):
        # restic ≥0.19：name 是 basename，path 才是完整路径——目录结构必须来自 path
        text = "\n".join([
            json.dumps({"name": "docs", "type": "dir", "path": "/tmp/src/docs",
                        "struct_type": "node"}),
            json.dumps({"name": "a.txt", "type": "file", "path": "/tmp/src/docs/a.txt",
                        "size": 5, "mtime": "2026-09-29T09:21:39+08:00",
                        "struct_type": "node"}),
        ])
        es = bg.parse_restic_ls(text, strip=0)
        self.assertEqual([e.path for e in es], ["tmp/src/docs/a.txt"])
        # auto-strip 后应保留 docs 顶层目录
        stripped = bg.strip_entries(es, bg.common_prefix_depth([e.path for e in es]) - 1)
        self.assertEqual(stripped[0].path, "docs/a.txt")

    def test_parse_borg_ls(self):
        text = "\n".join([
            json.dumps({"mode": "drwxr-xr-x", "path": "home/neb", "size": 0, "mtime": 0}),
            json.dumps({"mode": "-rw-r--r--", "path": "home/neb/notes.md", "size": 42,
                        "mtime": 1727400000.0}),
        ])
        es = bg.parse_borg_ls(text, strip=2)
        self.assertEqual([(e.path, e.size) for e in es], [("notes.md", 42)])

    def test_parse_borg_ls_iso_mtime(self):
        # borg 1.4 实测：mtime 为 ISO 字符串（无时区，按本地时区解释）
        text = json.dumps({"mode": "-rw-r--r--", "path": "home/neb/a.jpg", "size": 7,
                           "mtime": "2026-09-28T21:00:00.337098"})
        es = bg.parse_borg_ls(text, strip=2)
        self.assertEqual(es[0].path, "a.jpg")
        self.assertEqual(es[0].mtime, bg.parse_iso("2026-09-28T21:00:00.337098").timestamp())

    def test_norm_path_backslash_and_strip(self):
        self.assertEqual(bg._norm_path("C:\\Users\\neb\\a.txt", 2), "a.txt")
        self.assertEqual(bg._norm_path("/Users/neb/a.txt", 0), "Users/neb/a.txt")


class TestDiffAndClassify(unittest.TestCase):
    def test_diff_added_modified_removed(self):
        cur = [E("a.txt", 10, 1.0), E("b.txt", 20, 2.0), E("c.txt", 30, 3.0)]
        prev = [E("a.txt", 10, 1.0), E("b.txt", 99, 2.0), E("z.txt", 5, 1.0)]
        d = bg.diff_entries(cur, prev)
        self.assertEqual([e.path for e in d.added], ["c.txt"])
        self.assertEqual([n.path for n, _ in d.modified], ["b.txt"])
        self.assertEqual([e.path for e in d.removed], ["z.txt"])

    def test_classify(self):
        self.assertEqual(bg.classify("Pictures/日本旅行/IMG_001.jpg"), "photos")
        self.assertEqual(bg.classify("Pictures/日本旅行/DSC_001.NEF"), "photos")
        self.assertEqual(bg.classify("Documents/报销/发票.pdf"), "documents")
        self.assertEqual(bg.classify(".ssh/authorized_keys"), "credentials")
        self.assertEqual(bg.classify("Keychains/login.keychain-db"), "credentials")
        self.assertEqual(bg.classify("src/main.rs"), "code")
        self.assertEqual(bg.classify("Movies/a.mp4"), "video")

    def test_credentials_priority_over_documents(self):
        # .kdbx 在 documents 扩展名表（key）之前判定为凭据
        self.assertEqual(bg.classify("Documents/vault.kdbx"), "credentials")


class TestClusters(unittest.TestCase):
    def _diff(self) -> bg.DiffResult:
        d = bg.DiffResult()
        d.added = [E(f"Pictures/日本旅行-0926/IMG_{i:03d}.jpg", 3_000_000) for i in range(50)]
        d.added += [E("Documents/工作/报告.pdf", 100_000)]
        d.modified = [(E("Keychains/login.keychain-db", 500), E("Keychains/login.keychain-db", 480))]
        return d

    def test_cluster_top_dir_and_significance(self):
        cs = bg.cluster_changes(self._diff())
        self.assertEqual(cs[0].tag, "photos")
        self.assertTrue(cs[0].name.startswith("Pictures"))
        self.assertEqual(cs[0].raw_count, 0)

    def test_cluster_counts_only_own_tag(self):
        # 单一顶层目录下混簇：照片新增 + 凭据修改，照片计数不得混入凭据
        d = bg.DiffResult()
        d.added = [E("src/Pictures/trip/IMG_001.jpg", 3_000_000),
                   E("src/Pictures/trip/IMG_002.jpg", 3_000_000)]
        d.modified = [(E("src/.ssh/authorized_keys", 612), E("src/.ssh/authorized_keys", 590))]
        cs = bg.cluster_changes(d)
        story = bg.build_story({"time": "2026-09-28T21:00:00+08:00", "device": "T",
                                "has_prev": True}, {}, cs, streak=2)
        self.assertIn("2 张照片", story)
        self.assertNotIn("3 张照片", story)
        self.assertIn("相比上一份快照", story)

    def test_credentials_cluster_hides_name(self):
        d = bg.DiffResult()
        d.modified = [(E(".ssh/id_ed25519", 400), E(".ssh/id_ed25519", 390))]
        cs = bg.cluster_changes(d)
        self.assertEqual(cs[0].tag, "credentials")
        story = bg.build_story({"time": "2026-09-28T21:00:00+08:00", "device": "T"}, {}, cs, streak=2)
        self.assertNotIn(".ssh", story)
        self.assertIn("名称已隐去", story)


class TestPrivacy(unittest.TestCase):
    def test_story_never_contains_full_filenames(self):
        run = bg.make_demo_run()
        out = bg.render_snapshot(run)
        for banned in (".pdf", ".pptx", ".NEF", "authorized_keys", "发票", "行程单"):
            self.assertNotIn(banned, out["STORY.md"], f"STORY.md 泄露了文件名: {banned}")

    def test_manifest_standard_shows_top_dirs_only(self):
        run = bg.make_demo_run()
        out = bg.render_snapshot(run)
        self.assertIn("Pictures/", out["MANIFEST.txt"])
        # 明文层不得出现深层文件名
        self.assertNotIn("IMG_010", out["MANIFEST.txt"])
        self.assertNotIn("发票", out["MANIFEST.txt"])

    def test_strict_mode_hides_all_names(self):
        run = bg.make_demo_run()
        run["privacy"] = "strict"
        out = bg.render_snapshot(run)
        self.assertNotIn("Pictures/", out["MANIFEST.txt"])
        self.assertIn("目录名已隐去", out["MANIFEST.txt"])
        self.assertNotIn("`Pictures", out["STORY.md"])


class TestRendering(unittest.TestCase):
    def setUp(self):
        self.run = bg.make_demo_run()
        self.out = bg.render_snapshot(self.run)

    def test_manifest_box_alignment(self):
        lines = self.out["MANIFEST.txt"].splitlines()
        widths = {bg.display_width(l) for l in lines}
        self.assertEqual(len(widths), 1, f"卡片行宽不一致: {widths}")
        self.assertTrue(lines[0].startswith("╔") and lines[-1].startswith("╚"))

    def test_manifest_contains_key_facts(self):
        m = self.out["MANIFEST.txt"]
        self.assertIn("MacBook-Pro-macOS15", m)
        self.assertIn("2026-09-28", m)
        self.assertIn("周一", m)
        self.assertIn("evening", m)
        self.assertIn("snap_9f3a2c", m)
        self.assertIn("21:00", m)

    def test_story_deterministic_and_facts(self):
        self.assertEqual(self.out["STORY.md"], bg.render_snapshot(self.run)["STORY.md"])
        s = self.out["STORY.md"]
        self.assertIn("日本旅行-0926", s)
        self.assertIn("连续备份 46 天", s)
        self.assertIn("/device: MacBook-Pro-macOS15", s)

    def test_story_no_change_case(self):
        run = self.run
        for cls in run["classes"].values():
            cls["prev_entries"] = cls["entries"]
        out = bg.render_snapshot(run)
        self.assertIn("没有文件级变化", out["STORY.md"])

    def test_first_snapshot_case(self):
        run = self.run
        run.pop("parent_time")
        for cls in run["classes"].values():
            cls["prev_entries"] = []
        out = bg.render_snapshot(run)
        self.assertIn("第一份快照", out["STORY.md"])


class TestAutoStrip(unittest.TestCase):
    def test_common_prefix_depth(self):
        paths = ["home/neb/ci-data/docs/a.txt", "home/neb/ci-data/docs/b/c.txt"]
        self.assertEqual(bg.common_prefix_depth(paths), 4)
        self.assertEqual(bg.common_prefix_depth(["Documents/a", "Pictures/b"]), 0)
        self.assertEqual(bg.common_prefix_depth([]), 0)
        # 单条路径：深度 = 可剥离段数（strip 后仍留 1 段），4 段路径深度为 3
        self.assertEqual(bg.common_prefix_depth(["home/neb/docs/a.txt"]), 3)

    def test_strip_entries(self):
        es = [E("home/neb/docs/a.txt", 1)]
        out = bg.strip_entries(es, 2)
        self.assertEqual(out[0].path, "docs/a.txt")


class TestStreakAndId(unittest.TestCase):
    def test_streak(self):
        self.assertEqual(bg.streak_days(["2026-09-28", "2026-09-27", "2026-09-25"],
                                        bg.parse_iso("2026-09-28T21:00:00+08:00")), 2)

    def test_snapshot_id_stable(self):
        run = bg.make_demo_run()
        classes = {k: [bg.Entry(**e) for e in v["entries"]] for k, v in run["classes"].items()}
        self.assertEqual(bg.derive_snapshot_id(classes), bg.derive_snapshot_id(classes))


class TestE2E(unittest.TestCase):
    def test_demo_writes_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "demo_output"
            rc = bg.main(["demo", "--out", str(out)])
            self.assertIsNone(rc)
            target = out / "macbook-pro-macos15" / "timeline" / "2026" / "09" / "28" / "2100-evening"
            for name in ("MANIFEST.txt", "STORY.md", "restore.md"):
                self.assertTrue((target / name).exists(), f"缺少 {name}")

    def test_convert_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            ls = tmp / "ls.jsonl"
            ls.write_text(json.dumps({"name": "/Users/neb/Docs/a.pdf", "type": "file",
                                      "size": 5, "mtime": "2026-09-28T12:00:00+08:00",
                                      "struct_type": "node"}) + "\n")
            snaps = tmp / "snaps.json"
            snaps.write_text(json.dumps([{"id": "abcdef123456", "short_id": "abcdef12",
                                          "time": "2026-09-28T21:00:00+08:00",
                                          "hostname": "NebBook", "tags": ["files"]}]))
            run_path = tmp / "run.json"
            bg.main(["convert", "--engine", "restic", "--class", f"files={ls}",
                     "--meta", str(snaps), "--strip", "2", "--out", str(run_path)])
            run = json.loads(run_path.read_text(encoding="utf-8"))
            self.assertEqual(run["device"], "NebBook")
            self.assertEqual(run["classes"]["files"]["entries"][0]["path"], "Docs/a.pdf")
            out = bg.render_snapshot(run)
            self.assertIn("NebBook", out["MANIFEST.txt"])


if __name__ == "__main__":
    unittest.main()
