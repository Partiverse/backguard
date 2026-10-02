#!/usr/bin/env python3
"""bg_semantic 的单元测试（stdlib unittest）。

运行：python3 -m unittest test_bg_semantic -v
"""

from __future__ import annotations

import contextlib
import hashlib
import io
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

    def test_parse_iso_offset_variants(self):
        # 回归：launchd 环境 PATH 解析到系统 python3（3.9），其 fromisoformat
        # 拒绝 date +%z 产出的 +0800——四种 RFC3339 变体必须等价可解析
        self.assertEqual(
            bg.parse_iso("2026-09-30T09:48:20+0800"),
            bg.parse_iso("2026-09-30T01:48:20+00:00"),
        )
        for s in ("2026-09-30T09:48:20Z", "2026-09-30T09:48:20-0500",
                  "2026-09-30T09:48:20.337098+0800"):
            self.assertIsNotNone(bg.parse_iso(s), s)

    def test_parse_iso_fraction_digits(self):
        # restic 的 time/mtime 走 Go 的 RFC3339Nano：末尾零被削掉，所以小数位是 1/4/7/9 位
        # 都可能，而 py3.9 的 fromisoformat 只认 3 或 6 位。Windows 侧从**第二次**备份起
        # 才带 --parent-time（有上一份归档时才有），所以这条在「每轮新建仓库只跑首备」的
        # CI 上永远不露头（10-02 windows 集成段就是这么炸的）
        self.assertEqual(bg.parse_iso("2026-10-02T06:31:11.447503458+00:00"),
                         bg.parse_iso("2026-10-02T06:31:11.447503+00:00"))
        self.assertEqual(bg.parse_iso("2026-10-02T06:31:11.4"),
                         bg.parse_iso("2026-10-02T06:31:11.400000"))
        self.assertEqual(bg.parse_iso("2026-10-02T06:31:11.1234567+08:00").utcoffset().total_seconds(),
                         8 * 3600)
        # 没有小数秒 / 只有 3 位的原样不动
        self.assertEqual(bg.parse_iso("2026-10-02T06:31:11+00:00"),
                         bg.parse_iso("2026-10-02T06:31:11.000+00:00"))

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

    def test_key_ext_stays_credentials_even_in_documents_dir(self):
        # .key 同时命中 credentials 与 documents 扩展名表：规则顺序让凭据赢，
        # 且方向刻意保守——误判成凭据只是多隐去名称，反向会把私钥文件名写进明文层
        self.assertEqual(bg.classify("Documents/提案.key"), "credentials")
        self.assertEqual(bg.classify("ssl/server.key"), "credentials")


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

    def test_photo_cluster_never_counts_modified_as_added(self):
        # 真机 10-01 的 STORY 写「新增约 103 张照片」，实际新增 8 张、改动 95 张：
        # n 数的是同类成员（含修改），modified_count 数的却是整簇，两个口径混用
        d = bg.DiffResult()
        d.added = [E(f"Pictures/IMG_{i:03d}.jpg", 3_000_000) for i in range(8)]
        d.modified = [(E(f"Pictures/OLD_{i:03d}.jpg", 3_000_000),
                       E(f"Pictures/OLD_{i:03d}.jpg", 3_100_000)) for i in range(95)]
        cs = bg.cluster_changes(d)
        story = bg.build_story({"time": "2026-09-28T21:00:00+08:00", "device": "T"}, {}, cs, streak=2)
        self.assertIn("新增 **8 张照片**、另有 95 张有改动", story)
        self.assertNotIn("103 张照片", story)

    def test_story_counts_never_go_negative(self):
        # 「新增 -2」那类渲染：簇的多数标签是 documents，修改却散在别的标签上，
        # 拿「同类成员数」减「整簇修改数」就减成了负数（09-30 真机 STORY 出现过）
        d = bg.DiffResult()
        d.added = [E(f"work/报告 {i}.pdf", 1_000) for i in range(4)]
        d.modified = (
            [(E(f"work/IMG_{i}.jpg", 3_000_000), E(f"work/IMG_{i}.jpg", 3_100_000))
             for i in range(3)]
            + [(E(f"work/state{i}.db", 10), E(f"work/state{i}.db", 20)) for i in range(3)]
        )
        story = bg.build_story({"time": "2026-09-28T21:00:00+08:00", "device": "T"}, {},
                               bg.cluster_changes(d), streak=2)
        self.assertNotIn("新增 -", story)
        # 修复前这里是「新增 -2 · 修改 6」：文档簇只该报自己那 4 份新增
        self.assertIn("新增了 **4 份文档", story)

    def test_credentials_cluster_hides_name(self):
        d = bg.DiffResult()
        d.modified = [(E(".ssh/id_ed25519", 400), E(".ssh/id_ed25519", 390))]
        cs = bg.cluster_changes(d)
        self.assertEqual(cs[0].tag, "credentials")
        story = bg.build_story({"time": "2026-09-28T21:00:00+08:00", "device": "T"}, {}, cs, streak=2)
        self.assertNotIn(".ssh", story)
        self.assertIn("名称已隐去", story)

    def test_cluster_refuses_second_level_without_dir_evidence(self):
        # 明文层隐私红线：无目录证据时二级回退会把文件名冒充目录名
        #（Pictures/IMG_0001.jpg 只有一级目录证据）——必须退回一级
        d = bg.DiffResult()
        d.added = [E("Pictures/IMG_0001.jpg", 3_000_000)]
        self.assertEqual(bg.cluster_changes(d)[0].name, "Pictures")
        story = bg.build_story({"time": "2026-09-28T21:00:00+08:00", "device": "T"},
                               {}, bg.cluster_changes(d), streak=1)
        self.assertNotIn("IMG_0001", story)
        # 有目录证据时两级细化照常生效（不得把修复做成「永远只写一级」）
        deep = bg.DiffResult()
        deep.added = [E("Pictures/2026夏/IMG_0001.jpg", 3_000_000)]
        self.assertEqual(bg.cluster_changes(deep, known_dirs={"Pictures/2026夏"})[0].name,
                         "Pictures/2026夏")

    def test_demo_known_dirs_use_archive_style_separators(self):
        # run JSON 的 known_dirs 与 cluster 展示名一律用 "/" 拼（归档内路径口径）。
        # 取父目录若走 Path，Windows 上会产出 Documents\\2026-09 报销 这类 OS 原生
        # 分隔符——本机跑不出来，故这里用 PureWindowsPath 顶掉 Path 复现 Windows。
        import pathlib
        orig = bg.Path
        try:
            bg.Path = pathlib.PureWindowsPath
            kd = bg.make_demo_run()["known_dirs"]
        finally:
            bg.Path = orig
        self.assertTrue(kd, "demo run 应带目录证据")
        bad = [d for d in kd if "\\" in d]
        self.assertFalse(bad, f"known_dirs 混入 OS 原生分隔符: {bad}")


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

    def test_story_gap_warning_after_48h(self):
        # 断档 >48h：STORY 置顶提醒（research/08 T1.5）；时间均 naive，跨时区确定
        run = bg.make_demo_run()
        run["time"] = "2026-10-02T21:00:00"  # 距 parent 5 天
        out = bg.render_snapshot(run)
        self.assertIn("断档", out["STORY.md"])
        self.assertIn("5 天", out["STORY.md"])
        # 正常间隔：无提醒
        normal = bg.render_snapshot(bg.make_demo_run())["STORY.md"]
        self.assertNotIn("断档", normal)

    def test_story_first_snapshot_case(self):
        run = self.run
        run.pop("parent_time")
        for cls in run["classes"].values():
            cls["prev_entries"] = []
        out = bg.render_snapshot(run)
        self.assertIn("第一份快照", out["STORY.md"])

    def test_story_separates_prune_baseline_from_last_backup(self):
        # 两个口径（10-01 真机实测缺陷）：parent_time 是引擎里尚未被 prune 裁掉的上一份
        # 归档，prev_run_time 是时间轴上的上一份快照。prune 把当天几次备份裁成 1 次后
        # 两者能差一天，增量数字会「冻住」重复——STORY 必须把差异说出来。
        run = bg.make_demo_run()
        run["prev_run_time"] = "2026-09-28T02:34:00"   # 今晨那次（已被裁，不在引擎里）
        s = bg.render_snapshot(run)["STORY.md"]
        self.assertIn("口径说明", s)
        self.assertIn("上一次备份是 2026-09-28 02:34", s)
        self.assertIn("能回到的上一份归档是 2026-09-27 22:10", s)
        # MANIFEST 卡片用「上一次备份」口径
        self.assertIn("上一次备份: 2026-09-28 02:34", bg.render_snapshot(run)["MANIFEST.txt"])
        # 两者一致（正常夜间节奏）时不打扰用户
        same = bg.make_demo_run()
        same["prev_run_time"] = same["parent_time"]
        self.assertNotIn("口径说明", bg.render_snapshot(same)["STORY.md"])
        # 缺 prev_run_time（老 run.json、Windows 侧还没接）→ 退化回单口径，不报错
        self.assertNotIn("口径说明", bg.render_snapshot(bg.make_demo_run())["STORY.md"])

    def test_story_gap_not_fabricated_by_prune(self):
        # 断档提醒量的是「上一次备份」：parent 是 5 天前但昨天刚备份过，就不算断档。
        # 若仍以 parent 为准，保留策略裁掉中间归档会伪造出停摆告警。
        run = bg.make_demo_run()
        run["time"] = "2026-10-02T21:00:00"
        self.assertIn("断档", bg.render_snapshot(run)["STORY.md"])
        run["prev_run_time"] = "2026-10-01T21:00:00"
        self.assertNotIn("断档", bg.render_snapshot(run)["STORY.md"])


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


class TestManifest(unittest.TestCase):
    """manifest 子命令的纯计算部分（密封由编排层 age 完成）。"""

    def test_manifest_json_structure_and_redline(self):
        run = bg.make_demo_run()
        doc = json.loads(bg.build_manifest_json(run))
        self.assertEqual(doc["format"], "backguard/manifest/1")
        self.assertEqual(doc["device"]["id"], "MacBook-Pro-macOS15")
        files = doc["classes"]["files"]
        self.assertEqual(files["stats"]["count"], len(files["entries"]))
        self.assertGreater(files["stats"]["added"], 0)
        # 全量清单的条目是完整路径（这正是必须加密的原因）
        self.assertTrue(any("日本旅行" in e["path"] for e in files["entries"]))
        # parent 链在
        self.assertEqual(doc["snapshot"]["parent"], "snap_71b0ee")

    def test_manifest_diff_stats(self):
        run = bg.make_demo_run()
        doc = json.loads(bg.build_manifest_json(run))
        s = doc["classes"]["files"]["stats"]
        self.assertEqual(s["added"] + s["modified"] + s["removed"],
                         s["added"] + s["modified"] + 1)


class TestCoverage(unittest.TestCase):
    """覆盖报告（research/08 T2.3/T2.4）：排除清单明示 + 变更告知。"""

    def test_coverage_lists_exclusions(self):
        run = bg.make_demo_run()
        run["time"] = "2026-09-29T21:00:00"
        ex = [{"class": "files", "pattern": "**/node_modules/", "reason": "依赖可重装"},
              {"class": "files", "pattern": "**/*.log"}]
        cov = bg.build_coverage(run, ex, [])
        self.assertIn("不在备份内", cov)
        self.assertIn("**/node_modules/", cov)
        self.assertIn("依赖可重装", cov)
        self.assertIn("files", cov)

    def test_coverage_empty_exclusions(self):
        run = bg.make_demo_run()
        run["time"] = "2026-09-29T21:00:00"
        self.assertIn("未配置排除规则", bg.build_coverage(run, [], []))

    def test_coverage_rule_change_alert(self):
        run = bg.make_demo_run()
        run["time"] = "2026-09-29T21:00:00"
        cur = [{"class": "files", "pattern": "**/new-dir/"}]
        prev = [{"class": "files", "pattern": "**/old-dir/"}]
        cov = bg.build_coverage(run, cur, prev)
        self.assertIn("排除规则发生变化", cov)
        self.assertIn("新增排除", cov)
        self.assertIn("恢复备份", cov)

    def test_load_exclusions(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "exclusions.json"
            p.write_text(json.dumps([{"class": "files", "pattern": "**/x"}]), encoding="utf-8")
            self.assertEqual(bg.load_exclusions(p)[0]["pattern"], "**/x")
            self.assertEqual(bg.load_exclusions(Path(tmp) / "none.json"), [])

    def test_render_includes_coverage(self):
        files = bg.render_snapshot(bg.make_demo_run())
        self.assertIn("COVERAGE.txt", files)
        self.assertIn("覆盖报告", files["COVERAGE.txt"])

    def test_coverage_preflight_findings_t25(self):
        # 预检发现（半真文件等）进覆盖报告（research/08 T2.5）
        import tempfile
        run = bg.make_demo_run()
        run["time"] = "2026-09-29T21:00:00"
        with tempfile.TemporaryDirectory() as tmp:
            pf = Path(tmp) / "preflight-latest.json"
            pf.write_text(json.dumps({"errors": 0, "warnings": 1, "findings": [
                {"level": "warning", "check": "云同步占位文件",
                 "message": "/Users/x/Pictures 扫描 100 项，其中 3+ 个是占位文件"}]}, ensure_ascii=False),
                encoding="utf-8")
            run["preflight_path"] = str(pf)
            files = bg.render_snapshot(run)
        cov = files["COVERAGE.txt"]
        self.assertIn("云同步占位文件", cov)
        self.assertIn("3+ 个", cov)
        # 无预检文件时干净降级
        run["preflight_path"] = "/nonexistent-pf.json"
        cov2 = bg.render_snapshot(run)["COVERAGE.txt"]
        self.assertNotIn("✗", cov2)
        self.assertNotIn("云同步占位文件", cov2)


class TestDrillSample(unittest.TestCase):
    """恢复演练抽样（research/08 T3.4）：跨类别、确定性、非加密用途。"""

    def _manifest(self):
        import tempfile
        p = Path(tempfile.mkdtemp()) / "manifest.json"
        p.write_text(json.dumps({"classes": {
            "files": {"entries": [{"path": f"Users/x/Docs/f{i}.txt", "size": 100 + i,
                                   "mtime": 1700000000} for i in range(20)]},
            "config": {"entries": [{"path": "Users/x/.ssh/id", "size": 5,
                                    "mtime": 1700000000},
                                   {"path": "Users/x/.zero", "size": 0,
                                    "mtime": 1700000000}]},
        }}, ensure_ascii=False), encoding="utf-8")
        return p

    def test_sample_deterministic_and_cross_class(self):
        import io
        import contextlib
        m = self._manifest()
        outs = []
        for _ in range(2):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                bg.main(["sample", "--manifest", str(m), "--count", "5", "--seed", "2026-09-29"])
            outs.append(buf.getvalue())
        self.assertEqual(outs[0], outs[1])  # 同种子可复现
        plan = json.loads(outs[0])
        classes = {s["class"] for s in plan["samples"]}
        self.assertIn("config", classes)  # 小类别也被抽到（至少 1）
        for s in plan["samples"]:
            self.assertIn("path", s)
            self.assertGreater(s["size"], 0)  # 零字节文件不入样

    def test_sample_different_seed_rotates(self):
        import io
        import contextlib
        m = self._manifest()
        seen = set()
        for seed in ("2026-09-29", "2026-10-01"):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                bg.main(["sample", "--manifest", str(m), "--count", "5", "--seed", seed])
            seen.add(buf.getvalue())
        self.assertEqual(len(seen), 2)  # 跨天轮换


class TestDrillContentHash(unittest.TestCase):
    """取回校验的「内容」这一维（research/11 A2b）：备份期给当晚抽中的样本记源文件
    sha256，drill 才有比大小之外的依据。记不上就不记，绝不用 size 冒充内容一致。
    """

    @staticmethod
    def _tree(root: Path, files: dict[str, bytes]) -> None:
        """按归档内路径把源文件落地（size 用真实字节数，别拿字符数冒充）。"""
        for rel, data in files.items():
            p = Path(root, rel)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)

    @staticmethod
    def _sha(data: bytes) -> str:
        return hashlib.sha256(data).hexdigest()

    def _doc(self, entries: list[dict], engine: str = "borg") -> dict:
        return {"engine": engine,
                "classes": {"files": {"entries": entries}}}

    def _entries(self, files: dict[str, bytes]) -> list[dict]:
        return [{"path": rel, "size": len(data), "mtime": 1700000000}
                for rel, data in sorted(files.items())]

    def test_hashed_set_equals_drill_sample_set(self):
        """记哈希的样本必须正好是 drill 取回的那一批：两处共用同一个抽样函数。"""
        root = Path(tempfile.mkdtemp())
        files = {f"Users/x/Docs/f{i}.txt": f"内容{i}".encode() for i in range(12)}
        self._tree(root, files)
        doc = self._doc(self._entries(files))
        n = bg.hash_drill_samples(doc, 5, bg.DRILL_HASH_MAX_BYTES, "2026-10-02", str(root))
        self.assertEqual(n, 5)
        picks = bg.select_drill_samples(doc["classes"], 5, "2026-10-02")
        self.assertEqual(len(picks), 5)
        for p in picks:
            self.assertEqual(p["entry"].get("sha256"), self._sha(files[p["path"]]))

    def test_hash_skips_oversize_missing_and_rewritten(self):
        root = Path(tempfile.mkdtemp())
        # 三种「不记」各有各的闸门，别互相顶掉：上一版把被改过的文件写成 999 B，
        # 它先被超大规则拦下，尺寸校验整段摘掉测试照样绿（变异实验抓出来的）
        self._tree(root, {"Users/x/big.bin": b"x" * 100,
                          "Users/x/rewritten.txt": b"AAAABBB"})
        entries = [
            {"path": "Users/x/big.bin", "size": 100, "mtime": 1},      # 真实尺寸，但超过 max_bytes
            {"path": "Users/x/gone.txt", "size": 3, "mtime": 1},       # 源文件已不在
            {"path": "Users/x/rewritten.txt", "size": 4, "mtime": 1},  # 入库 4 B，之后被写成 7 B
        ]
        doc = self._doc(entries)
        n = bg.hash_drill_samples(doc, 3, 50, "2026-10-02", str(root))
        self.assertEqual(n, 0)  # 超大 / 读不到 / 尺寸不符，三种都不记
        for e in doc["classes"]["files"]["entries"]:
            self.assertNotIn("sha256", e)

    def test_hash_skipped_for_non_borg_engine(self):
        root = Path(tempfile.mkdtemp())
        files = {"Users/x/a.txt": b"hello"}
        self._tree(root, files)
        doc = self._doc(self._entries(files), engine="restic")
        self.assertEqual(
            bg.hash_drill_samples(doc, 1, 1 << 20, "2026-10-02", str(root)), 0)

    def test_sample_passes_sha_through_and_manifest_stays_clean(self):
        root = Path(tempfile.mkdtemp())
        files = {"Users/x/Docs/a.txt": b"alpha", "Users/x/Docs/b.txt": b"beta"}
        self._tree(root, files)
        doc = self._doc(self._entries(files))
        bg.hash_drill_samples(doc, 2, bg.DRILL_HASH_MAX_BYTES, "2026-10-02", str(root))
        mf = Path(root) / "manifest.json"
        mf.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            bg.main(["sample", "--manifest", str(mf), "--count", "2", "--seed", "2026-10-02"])
        plan = json.loads(buf.getvalue())
        self.assertEqual([s["sha256"] for s in plan["samples"]],
                         [self._sha(files["Users/x/Docs/a.txt"]),
                          self._sha(files["Users/x/Docs/b.txt"])])
        # 哈希只进密封清单：明文产物（MANIFEST/STORY/…）一个字节都不带
        hex_a = self._sha(files["Users/x/Docs/a.txt"])
        run = {"engine": "borg", "time": "2026-10-02T02:34:00+08:00", "device": "d",
               "classes": {"files": {"entries": [
                   {"path": "Users/x/Docs/a.txt", "size": 5, "mtime": 1700000000,
                    "sha256": hex_a}]}}}
        for name, text in bg.render_snapshot(run).items():
            self.assertNotIn(hex_a, text,
                             f"{name} 泄露了内容哈希（它只该待在密封清单里）")

    def test_hashing_does_not_pollute_run_json(self):
        """哈希只写进密封清单那一份：run JSON 是明文层的输入，被回灌就等于把完整
        路径+内容指纹一起留给下一个读它的人（而且 Entry(**e) 会因未知字段直接崩）。"""
        root = Path(tempfile.mkdtemp())
        files = {"Users/x/Docs/a.txt": b"alpha"}
        self._tree(root, files)
        run = {"engine": "borg", "time": "2026-10-02T02:34:00+08:00", "device": "d",
               "classes": {"files": {"entries": [
                   {"path": "Docs/a.txt", "raw": "Users/x/Docs/a.txt",
                    "size": 5, "mtime": 1700000000}]}}}
        doc = bg.build_manifest_doc(run)
        self.assertEqual(bg.hash_drill_samples(
            doc, 1, bg.DRILL_HASH_MAX_BYTES, "2026-10-02", str(root)), 1)
        self.assertEqual(doc["classes"]["files"]["entries"][0]["sha256"],
                         self._sha(files["Users/x/Docs/a.txt"]))
        self.assertNotIn("sha256", run["classes"]["files"]["entries"][0])
        # 密封清单里出现额外字段之后，明文层渲染仍不认它（red line §1.1）
        for name, text in bg.render_snapshot(run).items():
            self.assertNotIn(self._sha(files["Users/x/Docs/a.txt"]), text, name)


class TestPreflight(unittest.TestCase):
    """预检（research/08 T2.2）：纯文件系统检查项。"""

    def _run_pf(self, *argv: str):
        """跑 preflight 并捕获退出码（SystemExit 携带级别）。"""
        import io
        import contextlib
        code = 0
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            try:
                bg.main(["preflight", "--json", *argv])
            except SystemExit as e:
                code = e.code or 0
        return code, json.loads(buf.getvalue())

    def test_placeholder_scan_icloud(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "docs").mkdir()
            (root / "docs" / "real.txt").write_text("x")
            (root / "docs" / "photo.jpg.icloud").write_text("placeholder")
            seen, found = bg._scan_placeholders(root)
            self.assertEqual(len(found), 1)
            self.assertTrue(found[0].endswith("photo.jpg.icloud"))
            self.assertEqual(seen, 3)  # docs 目录 + 2 个文件

    def test_preflight_missing_include_is_error(self):
        code, out = self._run_pf("--include", "/nonexistent-bg-path-xyz")
        self.assertEqual(code, 2)
        self.assertEqual(out["errors"], 1)
        self.assertIn("不存在", out["findings"][0]["message"])

    def test_preflight_legacy_string_format(self):
        # 旧版模板 bug：整串空格路径当单个 include——明确指向重新生成
        code, out = self._run_pf("--include", "/Users/x/.config/ /Users/x/.ssh/")
        self.assertEqual(code, 2)
        self.assertIn("旧版单字符串格式", out["findings"][0]["message"])

    def test_preflight_include_with_space_in_path_is_ok(self):
        # 回归：家目录含空格（/Users/John Smith、外置卷）是合法 include，
        # 曾被「含空格即旧版单字符串」判成 error → backup.sh 中止整个备份
        with tempfile.TemporaryDirectory() as tmp:
            inc = str(Path(tmp) / "John Smith" / "Documents")
            Path(inc).mkdir(parents=True)
            (Path(inc) / "a.txt").write_text("x")
            code, out = self._run_pf("--include", inc)
            self.assertEqual((code, out["errors"], out["warnings"]), (0, 0, 0))

    def test_preflight_clean_dir_exit_0(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            code, out = self._run_pf("--include", tmp)
            self.assertEqual(code, 0)
            self.assertEqual(out["errors"] + out["warnings"], 0)

    def test_preflight_git_excluded_warning(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".git").mkdir()
            code, out = self._run_pf("--include", tmp, "--excludes", "**/.git/", "x")
            self.assertEqual(code, 1)
            self.assertEqual(out["warnings"], 1)
            self.assertIn(".git", out["findings"][0]["message"])

    def test_preflight_low_disk_warning(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            code, out = self._run_pf("--check-disk", tmp, "--min-free-gb", "99999999")
            self.assertEqual(code, 1)
            self.assertIn("磁盘", out["findings"][0]["check"])


class TestE2E(unittest.TestCase):
    def test_demo_writes_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "demo_output"
            rc = bg.main(["demo", "--out", str(out)])
            self.assertIsNone(rc)
            # 快照直接落时间树：--out 那个目录（本地=timeline 根，云端=<SYSTEM_ID>/timeline）
            # 下就是 YYYY/MM/DD/HHMM-标签。设备名曾在这里多叠一层，而本地根与云端目标
            # 各自都已带设备名，云端于是长成 <sys>/timeline/<sys>/2026/…（10-01 真机）。
            demo = bg.make_demo_run()
            target = bg.snapshot_target(demo, out)
            self.assertEqual(4, len(target.relative_to(out).parts),
                             f"快照目录应为 YYYY/MM/DD/HHMM-标签 四层: {target.relative_to(out)}")
            for name in ("MANIFEST.txt", "STORY.md", "restore.md"):
                self.assertTrue((target / name).exists(), f"缺少 {name}")
            self.assertEqual([], sorted(p.name for p in out.iterdir()
                                        if p.is_dir() and not p.name.isdigit()),
                             "时间树根下出现非年份目录（设备层又回来了？）")

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
