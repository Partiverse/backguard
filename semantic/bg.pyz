#!/usr/bin/env python3
"""bg_semantic —— backguard 语义层原型（research/06 章 L1/L2 的可运行验证）。

从 borg/restic 导出的快照清单（或通用 run JSON）生成每个快照的可读目录：

    timeline/YYYY/MM/DD/HHMM-<标签>/
      MANIFEST.txt   明文摘要清单（L1，裸文件管理器可读）
      STORY.md       自然语言变更叙事（L2，规则模板生成，无 AI、无幻觉）
      restore.md     本快照的恢复指引（明文）

设计红线（research/06 §2.3/§4.3）：明文层只放统计摘要级信息——
完整文件名与路径只进加密清单（manifest.json.enc，本原型不生成）；
凭据类目录一律只写数量不写名字。

用法：
  python3 bg_semantic.py demo --out demo_output
  python3 bg_semantic.py generate --run run.json --out timeline
  python3 bg_semantic.py convert --engine restic --class files=ls.jsonl --out run.json
  python3 bg_semantic.py convert --engine borg   --class files=list.jsonl --out run.json

仅依赖 Python 3.10+ 标准库。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random  # 仅用于演练抽样（可复现性需求，非加密用途；加密随机一律用 secrets）
import re
import shutil
import sys
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

__version__ = "0.2.0"
RUN_FORMAT = "backguard/semantic-run/1"
MANIFEST_FORMAT = "backguard/manifest/1"
WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
CLASS_CAPTIONS = {
    "config": "丢了很痛的配置与密钥",
    "files": "你自己创造的文档、照片、视频",
    "system": "重建系统用的图纸",
}

# ---------------------------------------------------------------- 基础工具


def display_width(s: str) -> int:
    """终端显示宽度（CJK 全角按 2 列）。"""
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s: str, w: int) -> str:
    return s + " " * max(0, w - display_width(s))


def truncate_width(s: str, w: int) -> str:
    if display_width(s) <= w:
        return s
    out = ""
    for c in s:
        if display_width(out) + display_width(c) > w - 1:
            return out + "…"
        out += c
    return out


def human_bytes(n: int) -> str:
    for unit, div in (("TB", 1024**4), ("GB", 1024**3), ("MB", 1024**2), ("KB", 1024)):
        if n >= div:
            return f"{n / div:.1f} {unit}"
    return f"{n} B"


def parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def sanitize_component(s: str) -> str:
    """路径段安全化：[a-z0-9-]（research/06 §2.1 跨平台规则）。点转连字符保留可读性。"""
    s = s.strip().lower()
    s = re.sub(r"[\s_.]+", "-", s)
    s = re.sub(r"[^a-z0-9-]", "", s)
    return re.sub(r"-+", "-", s).strip("-") or "unknown"


def derive_snapshot_id(classes: dict[str, list["Entry"]]) -> str:
    """由清单内容确定性派生短 ID（原型用；正式版由引擎快照 ID 接管）。"""
    h = hashlib.sha256()
    for cls in sorted(classes):
        for e in sorted(classes[cls], key=lambda x: x.path):
            h.update(f"{cls}\0{e.path}\0{e.size}\0{e.mtime}\0".encode())
    return "snap_" + h.hexdigest()[:8]


# ---------------------------------------------------------------- 数据模型


@dataclass(frozen=True)
class Entry:
    path: str          # 显示/明文层用路径（auto-strip 后）
    size: int
    mtime: float
    raw: str | None = None  # 归档内原始路径（strip 前）——drill 取回用；明文层不消费


@dataclass
class DiffResult:
    added: list[Entry] = field(default_factory=list)
    removed: list[Entry] = field(default_factory=list)
    modified: list[tuple[Entry, Entry]] = field(default_factory=list)  # (新, 旧)

    @property
    def is_empty(self) -> bool:
        return not (self.added or self.removed or self.modified)

    @property
    def added_bytes(self) -> int:
        return sum(e.size for e in self.added)

    @property
    def churn_bytes(self) -> int:
        return sum(new.size for new, _ in self.modified)


@dataclass
class Cluster:
    tag: str  # 语义标签键（photos/documents/credentials/...）
    cls: str  # 所属档案类别（config/files/system）
    name: str  # 展示目录名（明文层允许的最深形态；"" 表示不显示名称）
    members: list[Entry] = field(default_factory=list)
    modified_count: int = 0
    bytes: int = 0
    raw_count: int = 0  # 照片簇内 RAW 计数


def _read_text(path: Path) -> str:
    # utf-8-sig：容忍 PowerShell 5.1 重定向产出的 BOM
    return path.read_text(encoding="utf-8-sig")


def common_prefix_depth(paths: list[str]) -> int:
    """全部路径的公共前缀段数（每条路径至少保留 1 段）。"""
    if not paths:
        return 0
    splits = [p.split("/") for p in paths]
    n = 0
    for i in range(min(len(s) for s in splits)):
        c = splits[0][i]
        if all(s[i] == c for s in splits) and all(len(s) > i + 1 for s in splits):
            n += 1
        else:
            break
    return n


def strip_entries(entries: list[Entry], n: int) -> list[Entry]:
    if n <= 0:
        return entries
    return [Entry(_norm_path(e.path, n), e.size, e.mtime) for e in entries]


# ---------------------------------------------------------------- 引擎清单解析


def _norm_path(p: str, strip: int) -> str:
    p = p.replace("\\", "/").strip("/")
    if p.endswith("/"):
        p = p[:-1]
    parts = p.split("/") if p else []
    if len(parts) > 1 and re.fullmatch(r"[A-Za-z]:", parts[0]):
        parts = parts[1:]  # Windows 盘符段不属于内容路径
    if strip:
        parts = parts[strip:]
    return "/".join(parts)


def parse_restic_ls(text: str, strip: int = 0,
                    dirs: set[str] | None = None) -> list[Entry]:
    """`restic ls --json <snap>` 的输出（JSON Lines，struct_type=node）。

    restic ≥0.19 每行含完整 `path`（绝对路径）与 `name`（basename）——
    目录结构必须取 path；旧版无 path 时退回 name。
    dir 条目不进清单，但收集进 dirs（供聚类二级细化校验「是真实目录」）。
    """
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("struct_type") not in (None, "node"):
            continue
        raw = obj.get("path") or obj.get("name") or ""
        if obj.get("type") == "dir":
            if dirs is not None:
                d = _norm_path(raw, strip)
                if d:
                    dirs.add(d)
            continue
        p = _norm_path(raw, strip)
        if not p:
            continue
        mt = parse_iso(obj.get("mtime"))
        out.append(Entry(p, int(obj.get("size") or 0), mt.timestamp() if mt else 0.0))
    return out


def _mtime_to_epoch(v) -> float:
    """mtime 兼容层：epoch 数字（restic 部分版本）与 ISO 字符串（borg 1.x）都接受。"""
    if v is None:
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(v)
    except (TypeError, ValueError):
        dt = parse_iso(str(v))
        return dt.timestamp() if dt else 0.0


def parse_borg_ls(text: str, strip: int = 0,
                  dirs: set[str] | None = None) -> list[Entry]:
    """`borg list --json-lines repo::archive` 的输出。

    borg 1.x 的 mtime 是 ISO 8601 字符串（如 2026-09-29T00:39:53.337098），
    部分版本/字段为 epoch——用 _mtime_to_epoch 兼容两种形态。
    dir 条目（mode 以 d 开头）收集进 dirs，不进清单。
    """
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        mode = obj.get("mode", "")
        if mode.startswith("d") or str(obj.get("path", "")).endswith("/"):
            if dirs is not None:
                d = _norm_path(obj.get("path", ""), strip)
                if d:
                    dirs.add(d)
            continue
        p = _norm_path(obj.get("path", ""), strip)
        if not p:
            continue
        out.append(Entry(p, int(obj.get("size") or 0), _mtime_to_epoch(obj.get("mtime"))))
    return out


def parse_generic(text: str) -> list[Entry]:
    """run JSON 的 classes.<k>.entries 切片。"""
    obj = json.loads(text)
    items = obj if isinstance(obj, list) else obj.get("entries", [])
    return [Entry(i["path"], int(i.get("size", 0)), float(i.get("mtime", 0))) for i in items]


def meta_from_restic_snapshots(text: str, snap_id: str | None) -> dict:
    """`restic snapshots --json` → {device, time, snapshot_id}。"""
    snaps = json.loads(text)
    snaps.sort(key=lambda s: s.get("time", ""))
    pick = None
    if snap_id:
        pick = next((s for s in snaps if s.get("id", "").startswith(snap_id) or s.get("short_id") == snap_id), None)
    if pick is None:
        pick = snaps[-1] if snaps else {}
    return {
        "device": pick.get("hostname") or "unknown",
        "time": pick.get("time"),
        "snapshot_id": pick.get("short_id") or (pick.get("id") or "")[:12] or None,
        "tags": pick.get("tags") or [],
    }


def meta_from_borg_info(text: str) -> dict:
    """`borg info --json repo::archive` → {device, time, snapshot_id}。"""
    obj = json.loads(text)
    arch = obj.get("archive") or (obj.get("archives") or [{}])[-1]
    return {
        "device": arch.get("hostname") or "unknown",
        "time": arch.get("start") or arch.get("end"),
        "snapshot_id": (arch.get("id") or "")[:12] or None,
    }


# ---------------------------------------------------------------- 语义分类


# (标签, 目录提示, 扩展名集合) —— 顺序即优先级，凭据类永远最先判定
SEMANTIC_RULES: list[tuple[str, list[str], set[str]]] = [
    ("credentials",
     ["credential", ".ssh", ".gnupg", "keychain", "keychains", "kdbx", ".aws", ".kube",
      "密钥", "凭据", "password"],
     {"pem", "key", "kdbx", "ovpn", "p12", "pfx", "pub", "gpg", "asc"}),
    ("photos",
     ["pictures", "photos", "dcim", "照片", "图片", "截图", "screenshots", "camera"],
     {"jpg", "jpeg", "heic", "heif", "png", "gif", "tiff", "tif", "webp",
      "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "rw2"}),
    ("video",
     ["movies", "videos", "视频", "影片"],
     {"mp4", "mov", "mkv", "avi", "webm", "m4v"}),
    ("audio",
     ["music", "audio", "音乐"],
     {"mp3", "flac", "wav", "aiff", "m4a", "ogg"}),
    ("code",
     [".git", "src", "node_modules", "代码", "project", "projects"],
     {"py", "rs", "ts", "tsx", "js", "jsx", "go", "java", "c", "h", "cpp", "hpp",
      "swift", "kt", "rb", "php", "sh", "toml", "lock"}),
    ("documents",
     ["documents", "docs", "文档", "报销", "合同"],
     {"pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "md", "txt", "pages",
      "numbers", "key", "csv"}),
    ("archive",
     [],
     {"zip", "tar", "gz", "xz", "7z", "rar", "dmg", "iso", "tgz"}),
]

RAW_EXTS = {"cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "rw2"}

TAG_INFO = {
    # 标签: (中文名, emoji, 显著性权重)
    "credentials": ("凭据与密钥", "🔑", 3.0),
    "photos": ("照片", "📷", 1.6),
    "documents": ("文档", "📄", 1.3),
    "code": ("代码", "💻", 1.2),
    "video": ("视频", "🎬", 1.1),
    "audio": ("音频", "🎵", 0.9),
    "archive": ("压缩包", "🗜", 0.8),
    "other": ("文件", "📦", 0.7),
}


def classify(path: str) -> str:
    low = path.lower()
    stem = low.rsplit(".", 1)
    ext = stem[1] if len(stem) == 2 else ""
    for tag, hints, exts in SEMANTIC_RULES:
        if any(h in low for h in hints):
            return tag
        if ext and ext in exts:
            return tag
    return "other"


def diff_entries(cur: list[Entry], prev: list[Entry]) -> DiffResult:
    cur_map = {e.path: e for e in cur}
    prev_map = {e.path: e for e in prev}
    d = DiffResult()
    for p, e in cur_map.items():
        if p not in prev_map:
            d.added.append(e)
        else:
            old = prev_map[p]
            if e.size != old.size or e.mtime != old.mtime:
                d.modified.append((e, old))
    d.added.sort(key=lambda e: (-e.size, e.path))
    d.modified.sort(key=lambda x: (-x[0].size, x[0].path))
    d.removed = [e for p, e in prev_map.items() if p not in cur_map]
    return d


def cluster_changes(diff: DiffResult, cls: str = "files",
                    known_dirs: set[str] | None = None) -> list[Cluster]:
    """按顶层目录聚类变更（research/06 §4.2），展示名最深取两级。

    根级散文件（路径无目录段）合并为一簇且不显示名称，避免把文件名
    冒充成目录名写进明文层。二级细化名必须在 known_dirs 中（引擎清单
    的 dir 条目），否则退回一级——纯文件清单无法区分「a/b 是目录」与
    「a 是目录、b 是文件」，没有目录证据就不得写两级名。
    聚类按档案类别分开，叙事才不跨类混淆。
    """
    def _key(path: str) -> str:
        # 聚类键 = 顶层目录；根级散文件（路径无目录段）归入匿名组 ""
        return path.split("/", 1)[0] if "/" in path else ""

    groups: dict[str, list[Entry]] = {}
    for e in diff.added:
        groups.setdefault(_key(e.path), []).append(e)
    mod_keys = {_key(new.path) for new, _ in diff.modified}

    clusters: list[Cluster] = []
    for key in sorted(set(groups) | mod_keys):
        added = groups.get(key, [])
        mod_members = [new for new, _ in diff.modified if _key(new.path) == key]
        all_members = added + mod_members
        tags = [classify(e.path) for e in all_members] or ["other"]
        tag = max(set(tags), key=tags.count)
        if key == "":
            name = ""
        else:
            # 逐级回退细化：单一根载体且路径足够深时先试三级，否则两级。
            # 三级仅当 known_dirs 提供目录证据（纯文件清单的第三段可能是文件名，
            # 2026-09-29 真实 E2E 隐私测试抓到过单文件路径泄入叙事）；
            # 两级在无证据时保守允许，有证据时必须命中。
            firsts = {e.path.split("/", 1)[0] for e in all_members if "/" in e.path}
            candidates = [2]
            if len(firsts) == 1 and all(e.path.count("/") >= 2 for e in added):
                candidates = [3, 2]
            name = key
            for d in candidates:
                tops = [tuple(Path(e.path).parts[:d]) for e in added]
                if not (tops and all(t == tops[0] for t in tops)):
                    continue
                cand = "/".join(tops[0])
                if known_dirs is not None:
                    if cand in known_dirs:
                        name = cand
                        break
                elif d == 2:
                    name = cand
                    break
        clusters.append(Cluster(
            tag=tag,
            cls=cls,
            name=name,
            members=all_members,
            modified_count=len(mod_members),
            bytes=sum(e.size for e in all_members),
            raw_count=sum(1 for e in added if e.path.rsplit(".", 1)[-1].lower() in RAW_EXTS),
        ))
    clusters.sort(key=lambda c: -(c.bytes * TAG_INFO[c.tag][2] + len(c.members) * 1024))
    return clusters


def _topkey(path: str) -> str:
    parts = Path(path).parts
    return parts[0] if parts else path


# ---------------------------------------------------------------- 渲染：STORY.md


def _cluster_label(c: Cluster, privacy: str) -> str:
    """明文层允许的簇名：凭据类只写数量；strict 模式全部隐名（06 §4.3）。"""
    if privacy == "strict" or c.tag == "credentials":
        return ""
    return c.name


def local_naive(dt: datetime | None) -> datetime | None:
    """aware → 本地 naive 统一显示口径（borg info 返回 UTC ISO 字符串）。"""
    if dt is None:
        return None
    if dt.tzinfo is not None:
        return dt.astimezone().replace(tzinfo=None)
    return dt


def build_story(run: dict, per_class: dict[str, DiffResult], clusters: list[Cluster],
                streak: int) -> str:
    t = local_naive(parse_iso(run["time"]))
    parent_t = local_naive(parse_iso(run.get("parent_time")))
    privacy = run.get("privacy", "standard")
    label = run.get("label", "")
    head = f"# {t.strftime('%Y-%m-%d %H:%M')} · {label}".rstrip(" ·") + "\n\n"

    if run.get("parent_time"):
        intro = f"这次备份相比 {parent_t.strftime('%Y-%m-%d %H:%M')}：\n\n"
    elif run.get("has_prev"):
        intro = "这次备份相比上一份快照：\n\n"
    else:
        intro = "这是这个仓库的第一份快照：\n\n"

    # 断档提醒（research/08 T1.5）：距上次备份 >48h 时置顶提示，
    # 对抗「默默停摆」——让异常空窗在恢复的第一时间被看见
    if parent_t and t:
        gap_h = (t - parent_t).total_seconds() / 3600
        if gap_h > 48:
            intro += (f"> ⚠️ 距上次备份已约 {gap_h / 24:.0f} 天——中间出现了断档，"
                      f"请留意定时任务是否正常。\n\n")

    def tag_members(c: Cluster, tag: str) -> list[Entry]:
        return [m for m in c.members if classify(m.path) == tag]

    bullets: list[str] = []
    for c in clusters[:3]:
        loc = _cluster_label(c, privacy)
        loc_part = f"，集中在 `{loc}/`" if loc else ""
        # 叙事计数只统计同类成员：簇按多数打标签，但混入的少量异类文件不应算数
        own = tag_members(c, c.tag) or c.members
        n = len(own)
        size = human_bytes(sum(e.size for e in own))
        if c.tag == "photos":
            raw = sum(1 for e in own if e.path.rsplit(".", 1)[-1].lower() in RAW_EXTS)
            raw_part = f"（其中 RAW {raw} 张）" if raw else ""
            bullets.append(f"- 📷 新增约 **{n} 张照片 / {size}**{loc_part}{raw_part}；")
        elif c.tag == "documents":
            n_add, n_mod = n - c.modified_count, c.modified_count
            if n_add and n_mod:
                bullets.append(f"- 📄 文档有变化：新增 {n_add} · 修改 {n_mod} 份（{size}）{loc_part}；")
            elif n_mod:
                bullets.append(f"- 📄 修改了 **{n_mod} 份文档**（{size}）{loc_part}；")
            else:
                bullets.append(f"- 📄 新增了 **{n_add} 份文档 / {size}**{loc_part}；")
        elif c.tag == "credentials":
            # 凭据类一律不出现名称（06 §4.3）
            bullets.append(f"- 🔑 凭据与密钥有变化：**{n} 个文件**更新（名称已隐去）；")
        elif c.cls == "system":
            bullets.append(f"- 🗂 系统图纸有更新：**{n} 个文件**（包清单/系统配置），增量 {size}；")
        elif c.tag == "code":
            bullets.append(f"- 💻 代码有变更：`{loc or '代码目录'}`（新增 {len(c.members) - c.modified_count} · 修改 {c.modified_count}）；")
        elif c.tag == "video":
            bullets.append(f"- 🎬 新增 **{n} 段视频 / {size}**{loc_part}；")
        else:
            zh, emoji, _ = TAG_INFO[c.tag]
            bullets.append(f"- {emoji} `{loc or zh}`：新增 {n - c.modified_count} · 修改 {c.modified_count}（{size}）；")

    total_add = sum(d.added_bytes for d in per_class.values())
    total_churn = sum(d.churn_bytes for d in per_class.values())
    n_add = sum(len(d.added) for d in per_class.values())
    n_mod = sum(len(d.modified) for d in per_class.values())
    n_del = sum(len(d.removed) for d in per_class.values())

    if clusters:
        footer = f"\n总增量 {human_bytes(total_add)}（新增 {n_add} · 修改 {n_mod} · 删除 {n_del}）。\n"
    elif parent_t and t and (t - parent_t).total_seconds() > 48 * 3600:
        footer = "与上次相比没有文件级变化。备份已恢复运行。\n"
    else:
        footer = (f"与上次相比没有文件级变化（{n_mod} 个文件时间戳被触碰）——"
                  f"备份在按时运行，一切正常。\n")
    if total_churn:
        footer = footer  # churn 已含在修改计数里，避免重复口径
    if streak > 1:
        footer += f"至此你已连续备份 {streak} 天。\n"
    footer += f"/device: {run.get('device', 'unknown')}\n"

    return head + intro + ("\n".join(bullets) + "\n" if bullets else "") + footer


# ---------------------------------------------------------------- 渲染：MANIFEST.txt


def _class_stat_block(cls: str, entries: list[Entry], d: DiffResult, privacy: str) -> list[str]:
    cap = CLASS_CAPTIONS.get(cls, "")
    lines = [f"{cls} — {cap}"]
    if cls == "system" and len(entries) <= 12:
        lines.append(f"  系统图纸: {len(entries)} 个文件已采集（{human_bytes(sum(e.size for e in entries))}）")
        return lines
    n_mod = len(d.modified)
    delta = f"（新增 {len(d.added)} · 变更 {n_mod} · 删除 {len(d.removed)}）" if d else ""
    lines.append(f"  {len(entries):,} 个文件 · {human_bytes(sum(e.size for e in entries))} {delta}")
    if privacy == "strict":
        lines.append("    目录名已隐去（隐私模式）")
        return lines
    tops: dict[str, list[Entry]] = {}
    for e in entries:
        tops.setdefault(_topkey(e.path), []).append(e)
    ranked = sorted(tops.items(), key=lambda kv: -sum(e.size for e in kv[1]))
    for top, es in ranked[:3]:
        lines.append(f"    {top}/  {human_bytes(sum(e.size for e in es))} · {len(es):,} 文件")
    if not ranked:
        lines.append(f"    （{len(entries):,} 个散文件）")
    return lines


def build_manifest(run: dict, per_class: dict[str, tuple[list[Entry], DiffResult]]) -> str:
    t = local_naive(parse_iso(run["time"]))
    privacy = run.get("privacy", "standard")
    date_line = f"{t.strftime('%Y-%m-%d')}（{WEEKDAYS[t.weekday()]}）{t.strftime('%H:%M')}"
    classes_line = "+".join(per_class.keys())

    content: list[str] = []
    content.append(f"backguard 快照 · {run.get('device', 'unknown')}")
    sub = f"{date_line}"
    if run.get("label"):
        sub += f" · 标签: {run['label']}"
    content.append(sub)
    sid = run.get("snapshot_id") or "(未指定)"
    line = f"快照 ID: {sid}"
    if run.get("parent_time"):
        pt = local_naive(parse_iso(run["parent_time"]))
        line += f" · 上一次: {pt.strftime('%Y-%m-%d %H:%M')}"
    content.append(line)
    content.append(f"类别: {classes_line}" + (" · 隐私模式: 严格" if privacy == "strict" else ""))
    content.append("SEP")
    for cls, (entries, d) in per_class.items():
        content.extend(_class_stat_block(cls, entries, d, privacy))
        content.append("")
    while content and content[-1] == "":
        content.pop()
    content.append("SEP")
    content.append("完整文件清单已加密存放于 manifest.json.enc（本原型未生成）")
    content.append("如何恢复 → 见本目录 restore.md")

    W = min(max(display_width(l) for l in content if l != "SEP"), 96)
    W = max(W, 40)
    bar = "═" * (W + 2)
    out = [f"╔{bar}╗"]
    for l in content:
        if l == "SEP":
            out.append(f"╠{bar}╣")
        else:
            out.append(f"║ {pad(truncate_width(l, W), W)} ║")
    out.append(f"╚{bar}╝")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- 渲染：restore.md


def build_restore(run: dict) -> str:
    t = parse_iso(run["time"])
    engine = run.get("engine", "generic")
    sid = run.get("snapshot_id") or "<快照ID>"
    device = run.get("device", "unknown")
    cmds = []
    if engine in ("borg", "generic"):
        cmds.append(
            "# borg：先列出再提取\n"
            "  borg list <仓库路径>::\n"
            "  borg extract --list <仓库路径>::<归档名>  <要恢复的子路径>"
        )
    if engine in ("restic", "generic"):
        cmds.append(
            "# restic：restore 到目标目录\n"
            "  export RESTIC_PASSWORD=<仓库口令>\n"
            "  restic -r <仓库路径> restore <快照ID> --target <恢复目标目录>"
        )
    joined = "\n\n".join(cmds)
    return f"""# 如何从这份快照恢复数据

这份快照属于设备 **{device}**，创建于 {t.strftime('%Y-%m-%d %H:%M')}（标签: {run.get('label', '') or '无'}）。
快照 ID: `{sid}` · 引擎: {engine}

## 常规恢复（本机装有引擎时）

```
{joined}
```

## 逃生恢复（backguard 软件本身不可用时）

1. 阅读仓库根目录的 `README.md`（明文）——它解释目录结构与仓库格式；
2. `MANIFEST.txt` 是明文摘要；完整文件清单在 `manifest.json.enc`
   （age X25519 加密，双恢复路径任选其一，格式 schema 版本化）；
3. 内容块按内容寻址存放于类别内容池（config/files/system），按清单逐文件重建路径。

### manifest.json.enc 的两条解密路径

```bash
# 路径 A（日常）：本机主身份
age -d -i identity.txt -o manifest.json manifest.json.enc

# 路径 B（救援）：只有恢复码时，先解开救援身份（终端会提示输入恢复码）
age -d -o recovery-identity.txt recovery-identity.enc
age -d -i recovery-identity.txt -o manifest.json manifest.json.enc
rm recovery-identity.txt   # 用完即删
```

> 本段为原型占位文本。正式版由仓库根 `README.md` 与单文件救援器
> （research/06 §6「逃生恢复」）接替，并每年自动演练一次。
"""


# ---------------------------------------------------------------- 全量清单（research/06 §3.2 / 03 §6）
#
# manifest.json.enc 的加密由编排层（semantic.sh/ps1 调 age）完成——
# bg 只负责产出明文清单 JSON（完整文件名只存在这份密文账本里，永不进明文层文件）。
# 密钥体系（双 X25519 recipient：主身份 + 恢复码包裹的救援身份）见 semantic.sh 注释。


def build_manifest_json(run: dict) -> bytes:
    """加密全量清单（明文形态由调用方密封）：完整文件名/路径只存在这里。"""
    classes = {}
    for cls, spec in run["classes"].items():
        cur = list(spec.get("entries", []))
        prev = spec.get("prev_entries", [])
        d = diff_entries([Entry(**e) for e in cur], [Entry(**e) for e in prev])
        classes[cls] = {
            "entries": cur,
            "stats": {
                "count": len(cur), "bytes": sum(e["size"] for e in cur),
                "added": len(d.added), "modified": len(d.modified),
                "removed": len(d.removed),
            },
        }
    doc = {
        "format": MANIFEST_FORMAT,
        "snapshot": {"id": run.get("snapshot_id"), "parent": run.get("parent_id"),
                     "time": run.get("time"), "parent_time": run.get("parent_time"),
                     "label": run.get("label")},
        "device": {"id": run.get("device"), "os": run.get("os")},
        "engine": run.get("engine"),
        "classes": classes,
    }
    return json.dumps(doc, ensure_ascii=False, indent=1).encode("utf-8")


def load_exclusions(path: str | Path) -> list[dict]:
    """读取 exclusions.json（编排层导出，扁平格式 "class|pattern" 字符串数组）。"""
    p = Path(path)
    if not p.exists():
        return []
    try:
        data = json.loads(_read_text(p))
    except (ValueError, OSError):
        return []
    items = data.get("exclusions", []) if isinstance(data, dict) else data
    out = []
    for e in items:
        if isinstance(e, str) and "|" in e:
            cls, _, pat = e.partition("|")
            out.append({"class": cls, "pattern": pat})
        elif isinstance(e, dict):
            out.append(e)
    return out


def build_coverage(run: dict, exclusions: list[dict],
                   prev_exclusions: list[dict]) -> str:
    """覆盖报告（research/08 T2.3）：每次备份必产——「什么没被备份」。

    对位 Backblaze 2026 信任危机的核心产物：排除清单明示 + 规则变更
    主动告知（research/02 §八.1 / PRD FR-C2/FR-C3）。
    """
    t = local_naive(parse_iso(run["time"]))
    out: list[str] = []
    out.append("╔══════════════════════════════════════════════════════════╗")
    out.append(f"║ 覆盖报告 · {t.strftime('%Y-%m-%d %H:%M')} · {run.get('device', '?')}")
    out.append("╠══════════════════════════════════════════════════════════╣")
    if not exclusions:
        out.append("║ 本次备份未配置排除规则（备份范围内无主动排除）")
    else:
        out.append(f"║ 以下内容不在备份内（{len(exclusions)} 条规则）：")
        out.append("╠══════════════════════════════════════════════════════════╣")
        for e in exclusions[:8]:
            tail = f"  ← {e['reason']}" if e.get("reason") else ""
            out.append(f"║ [{e.get('class', '?')}] {truncate_width(str(e.get('pattern', '?')), 42)}{tail}")
        if len(exclusions) > 8:
            out.append(f"║ …另有 {len(exclusions) - 8} 条（见 exclusions.json）")

    # 规则变更主动告知（research/08 T2.4）
    if prev_exclusions:
        cur_set = {(e.get("class"), e.get("pattern")) for e in exclusions}
        prev_set = {(e.get("class"), e.get("pattern")) for e in prev_exclusions}
        added, removed = cur_set - prev_set, prev_set - cur_set
        if added or removed:
            out.append("╠══════════════════════════════════════════════════════════╣")
            out.append("║ ⚠ 本次备份的排除规则发生变化：")
            for c, p in sorted(added)[:5]:
                out.append(f"║   + 新增排除 [{c}] {truncate_width(str(p), 38)}")
            for c, p in sorted(removed)[:5]:
                out.append(f"║   - 恢复备份 [{c}] {truncate_width(str(p), 38)}")
    out.append("╚══════════════════════════════════════════════════════════╝")
    return "\n".join(out) + "\n"


def cmd_manifest(args: argparse.Namespace) -> None:
    run = _load_run(Path(args.run))
    sys.stdout.buffer.write(build_manifest_json(run))


# ---------------------------------------------------------------- 预检（research/08 T2.2 / 02 §八.1）
#
# 对位 Backblaze 2026 信任危机：备份前把「什么不会被有效备份」说清楚。
# bg 只做纯文件系统检查（占位文件 / .git 排除 / 磁盘空间）；
# 引擎版本与凭据链（rbw 等 PASSCOMMAND）检查在编排层（semantic.sh/ps1 的 preflight 引擎检查）。
# 级别：error（数据必然缺失）→ exit 2；warning（值得知道）→ exit 1。

ICLOUD_PLACEHOLDER_SUFFIX = ".icloud"       # macOS iCloud Drive 未下载占位
WIN_RECALL_FLAG = 0x400000                  # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
PLACEHOLDER_LIMIT = 50                      # 报告上限（计数另报）


def _scan_placeholders(root: Path, max_depth: int = 3,
                       max_files: int = 20000) -> tuple[int, list[str]]:
    """浅扫云同步占位文件（iCloud .icloud / Windows OneDrive recall 位）。"""
    found: list[str] = []
    seen = 0
    base_depth = len(root.parts)

    def _walk(d: Path) -> None:
        nonlocal seen
        if len(found) >= PLACEHOLDER_LIMIT or seen > max_files:
            return
        try:
            entries = sorted(d.iterdir())
        except OSError:
            return
        for e in entries:
            seen += 1
            if seen > max_files or len(found) >= PLACEHOLDER_LIMIT:
                return
            try:
                if e.is_symlink():
                    continue
                if e.is_dir():
                    if len(e.parts) - base_depth < max_depth:
                        _walk(e)
                    continue
                if e.name.endswith(ICLOUD_PLACEHOLDER_SUFFIX):
                    found.append(str(e))
                    continue
                st = e.stat()
                if hasattr(st, "st_file_attributes") and (
                        st.st_file_attributes & WIN_RECALL_FLAG):
                    found.append(str(e))
            except OSError:
                continue

    if root.is_dir():
        _walk(root)
    return seen, found


def cmd_preflight(args: argparse.Namespace) -> None:
    findings: list[tuple[str, str, str]] = []  # (级别, 检查项, 消息)

    # 1. include 路径与云同步占位文件
    for inc in args.include or []:
        if " " in inc.strip():
            findings.append((
                "error", "include 路径",
                f"「{inc.strip()[:60]}…」含空格——疑似旧版单字符串格式（旧模板 bug），"
                "请重跑 init.sh 重新生成 config.sh（新版为每路径一个元素的数组）"))
            continue
        p = Path(inc).expanduser()
        if not p.exists():
            findings.append(("error", "include 路径", f"{p} 不存在——将备份不到任何内容"))
            continue
        scanned, ph = _scan_placeholders(p)
        if ph:
            findings.append((
                "warning", "云同步占位文件",
                f"{p} 扫描 {scanned} 项，其中 {len(ph)}+ 个是未真正落盘的占位文件"
                f"（如 {Path(ph[0]).name}）——只会备份到空壳，请先在云同步客户端下载原图"))

    # 2. .git 静默排除检测（Backblaze 信任危机对位）
    if args.excludes and any(".git" in e for e in args.excludes):
        hits = [i for i in (args.include or [])
                if (Path(i).expanduser() / ".git").exists()]
        if hits:
            findings.append((
                "warning", ".git 被排除",
                f"排除规则含 .git，且 {hits[0]} 下存在 git 仓库——版本历史将不在备份内"
                "（如属有意，可忽略本条）"))

    # 3. 磁盘空间
    for t in args.check_disk or []:
        tp = Path(t).expanduser()
        if not tp.exists():
            continue
        free_gb = shutil.disk_usage(tp).free / 2**30
        if free_gb < args.min_free_gb:
            findings.append(("warning", "磁盘空间",
                             f"{t} 仅剩 {free_gb:.0f} GB（< {args.min_free_gb} GB）"))

    n_err = sum(1 for f in findings if f[0] == "error")
    n_warn = len(findings) - n_err
    if args.json:
        print(json.dumps({"errors": n_err, "warnings": n_warn,
                          "findings": [{"level": lv, "check": ck, "message": msg}
                                       for lv, ck, msg in findings]}, ensure_ascii=False))
    else:
        if not findings:
            print("preflight: 全部检查通过（无占位文件 / 磁盘充足 / include 有效）")
        for lv, ck, msg in findings:
            mark = "✗" if lv == "error" else "⚠"
            print(f"{mark} [{ck}] {msg}")
        print(f"preflight: {n_err} 个错误, {n_warn} 个警告")
    raise SystemExit(2 if n_err else (1 if n_warn else 0))


# ---------------------------------------------------------------- 恢复演练抽样（research/08 T3.4）
#
# drill 的进程调用（age 解封 / borg 取回）在编排层（semantic.sh run_drill）——
# bg 只做纯计算：从密封清单的明文形态抽「跨类别确定性样本」并给出期望值。


def cmd_sample(args: argparse.Namespace) -> None:
    manifest = json.loads(_read_text(Path(args.manifest)))
    by_cls: dict[str, list[dict]] = {}
    for cls, spec in manifest.get("classes", {}).items():
        by_cls[cls] = [e for e in spec.get("entries", []) if e.get("size", 0) > 0]

    # seed=当天日期：同一天演练抽同一组（可复现），跨天自然轮换防盲区
    seed = args.seed or datetime.now().date().isoformat()
    rng = random.Random(f"bg-drill/{seed}")
    n = max(args.count, len(by_cls) or 1)
    picked: list[dict] = []
    total = sum(len(v) for v in by_cls.values()) or 1
    for cls in sorted(by_cls):
        pool = sorted(by_cls[cls], key=lambda e: e["path"])  # 排序保证确定性
        k = max(1, round(n * len(pool) / total))
        for e in rng.sample(pool, min(k, len(pool))):
            # path 用归档内原始路径（raw）——drill 要拿它向 borg 取回
            picked.append({"class": cls, "path": e.get("raw") or e["path"],
                           "size": e["size"], "mtime": e.get("mtime", 0)})
    picked.sort(key=lambda e: (e["class"], e["path"]))
    print(json.dumps({"date": seed, "samples": picked,
                      "total_files": total}, ensure_ascii=False))


# ---------------------------------------------------------------- 汇总流程


def streak_days(history: list[str], ref: datetime) -> int:
    days = {d[:10] for d in history}
    n, d = 0, ref
    while d.strftime("%Y-%m-%d") in days:
        n += 1
        d -= timedelta(days=1)
    return n


def compute_run(run: dict) -> dict:
    """对 run JSON 做全部语义计算，返回渲染输入。"""
    per_class_diff: dict[str, DiffResult] = {}
    per_class: dict[str, tuple[list[Entry], DiffResult]] = {}
    for cls, spec in run["classes"].items():
        cur = [Entry(**e) for e in spec.get("entries", [])]
        prev = [Entry(**e) for e in spec.get("prev_entries", [])]
        d = diff_entries(cur, prev)
        per_class_diff[cls] = d
        per_class[cls] = (cur, d)

    known_dirs = set(run.get("known_dirs", [])) or None
    clusters: list[Cluster] = []
    for cls, d in per_class_diff.items():
        clusters.extend(cluster_changes(d, cls, known_dirs))
    clusters.sort(key=lambda c: -(c.bytes * TAG_INFO[c.tag][2] + len(c.members) * 1024))
    streak = streak_days(run.get("history", []), parse_iso(run["time"]))
    return {
        "per_class": per_class,
        "clusters": clusters,
        "streak": streak,
    }


def render_snapshot(run: dict, snapshot_dir: Path | None = None) -> dict[str, str]:
    computed = compute_run(run)
    per_class = computed["per_class"]
    per_class_diff = {k: d for k, (_, d) in per_class.items()}
    files = {
        "MANIFEST.txt": build_manifest(run, per_class),
        "STORY.md": build_story(run, per_class_diff,
                                computed["clusters"], computed["streak"]),
        "restore.md": build_restore(run),
    }
    # 覆盖报告（research/08 T2.3/T2.4）：本代 exclusions vs 上一代（变更检测）
    cur = load_exclusions(run.get("exclusions_path", "")) if run.get("exclusions_path") else []
    prev = load_exclusions(run["prev_exclusions_path"]) if run.get("prev_exclusions_path") else []
    files["COVERAGE.txt"] = build_coverage(run, cur, prev)
    return files


def snapshot_dirname(run: dict) -> Path:
    t = parse_iso(run["time"])
    label = sanitize_component(run.get("label", "snapshot"))
    return Path(f"{t.strftime('%Y')}/{t.strftime('%m')}/{t.strftime('%d')}/"
                f"{t.strftime('%H%M')}-{label}")


def write_outputs(run: dict, out_root: Path, files: dict[str, str]) -> Path:
    device = sanitize_component(run.get("device", "unknown"))
    # 设备目录下直接是时间树（2026/09/29/...）——早期版本的额外 timeline 层已去除，
    # 避免与外层收集目录名（timeline/）叠成「timeline/<设备>/timeline/」
    target = out_root / device / snapshot_dirname(run)
    target.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (target / name).write_text(text, encoding="utf-8")
    return target


# ---------------------------------------------------------------- 子命令


def _load_run(path: Path) -> dict:
    run = json.loads(path.read_text(encoding="utf-8"))
    if run.get("format") not in (None, RUN_FORMAT):
        raise SystemExit(f"run JSON format 不支持: {run.get('format')}")
    if "classes" not in run:
        raise SystemExit("run JSON 缺少 classes 字段")
    return run


def cmd_generate(args: argparse.Namespace) -> None:
    run = _load_run(Path(args.run))
    run["privacy"] = args.privacy
    if args.label:
        run["label"] = args.label
    if not run.get("snapshot_id"):
        run["snapshot_id"] = derive_snapshot_id(
            {k: [Entry(**{kk: e[kk] for kk in ("path", "size", "mtime") if kk in e})
                 for e in v.get("entries", [])]
             for k, v in run["classes"].items()})
    # 覆盖报告读本代/上代 exclusions.json（编排层导出，research/08 T2.1）
    if args.exclusions:
        run["exclusions_path"] = args.exclusions
    if args.prev_exclusions:
        run["prev_exclusions_path"] = args.prev_exclusions
    target_dir = (Path(args.out) / sanitize_component(run.get("device", "unknown"))
                 / snapshot_dirname(run))
    files = render_snapshot(run, target_dir)
    target = write_outputs(run, Path(args.out), files)
    print(f"已生成快照目录: {target}")
    for name in files:
        print(f"  - {name}")


def _split_kv(specs: list[str]) -> dict[str, Path]:
    out = {}
    for s in specs:
        k, _, v = s.partition("=")
        if not v:
            raise SystemExit(f"--class/--prev 参数应为 类别=文件 路径 形式，得到: {s}")
        out[k] = Path(v)
    return out


def cmd_convert(args: argparse.Namespace) -> None:
    classes = _split_kv(args.class_spec)
    prevs = _split_kv(args.prev or [])
    has_prev = bool(prevs)
    parser = {"restic": parse_restic_ls, "borg": parse_borg_ls, "generic": parse_generic}[args.engine]

    def load(spec: dict) -> tuple[list[dict], int]:
        es = parser(spec.read_text(encoding="utf-8-sig"), args.strip, known_dirs)
        n = max(0, common_prefix_depth([e.path for e in es]) - 1) if args.auto_strip else 0
        stripped = strip_entries(es, n)
        out = []
        for orig, e in zip(es, stripped):
            d = {"path": e.path, "size": e.size, "mtime": e.mtime}
            if n > 0:
                # 密封清单专用：归档内原始路径（drill 取回用）——明文层不消费此字段
                d["raw"] = orig.path
            out.append(d)
        return out, n

    known_dirs: set[str] = set()
    strip_depths: list[int] = []

    run: dict = {"format": RUN_FORMAT, "engine": args.engine, "classes": {}}
    if args.device:
        run["device"] = args.device
    if args.time:
        run["time"] = args.time
    if args.label:
        run["label"] = args.label
    if args.parent_time:
        run["parent_time"] = args.parent_time
    elif has_prev:
        run["has_prev"] = True  # 有上一代但时间未知：叙事退化为「相比上一份快照」
    meta_path = Path(args.meta) if args.meta else None
    if meta_path:
        text = _read_text(meta_path)
        meta = (meta_from_restic_snapshots(text, args.snap_id) if args.engine == "restic"
                else meta_from_borg_info(text))
        run.update({k: v for k, v in meta.items() if v and k not in run})
    for cls, p in classes.items():
        entries, n = load(p)
        spec: dict = {"entries": entries}
        if cls in prevs:
            spec["prev_entries"] = load(prevs[cls])[0]
        run["classes"][cls] = spec
        strip_depths.append(n)
    if known_dirs:
        # dirs 与 entries 在同一 strip 空间：按各类最大剥离段数统一剥前缀，
        # 否则二级细化校验永远失配、真实仓库的簇名会退化到一级
        nmax = max(strip_depths) if strip_depths else 0
        run["known_dirs"] = sorted(
            "/".join(d.split("/")[nmax:]) for d in known_dirs
            if len(d.split("/")) > nmax)
    if not run.get("time"):
        raise SystemExit("缺少快照时间：请用 --time 或 --meta 提供")
    out = Path(args.out)
    out.write_text(json.dumps(run, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"已写出 run JSON: {out}（类别: {', '.join(sorted(classes))}）")


def cmd_demo(args: argparse.Namespace) -> None:
    run = make_demo_run()
    run["privacy"] = args.privacy
    files = render_snapshot(run)
    target = write_outputs(run, Path(args.out), files)
    print(f"演示输出: {target}")
    for name in files:
        print(f"  - {name}")
    print("\n== MANIFEST.txt ==")
    print(files["MANIFEST.txt"])
    print("== STORY.md ==")
    print(files["STORY.md"])


def make_demo_run() -> dict:
    """合成「日本旅行回来那晚」的两代快照（research/06 §4.2 的示例场景）。

    时间用 naive 本地时间：渲染口径是「用户时钟」，跨时区确定性输出。
    """
    cur_t = datetime(2026, 9, 28, 21, 0)
    prev_t = datetime(2026, 9, 27, 22, 10)

    def old_photos() -> list[Entry]:
        return [Entry(f"Pictures/日本旅行-0926/IMG_00{i:02d}.jpg", 3_000_000 + i,
                      prev_t.timestamp()) for i in range(10)]

    cur = old_photos() + [
        *[Entry(f"Pictures/日本旅行-0926/IMG_01{i:03d}.jpg", 3_200_000 + i,
                cur_t.timestamp()) for i in range(176)],
        *[Entry(f"Pictures/日本旅行-0926/DSC_{i:04d}.NEF", 24_000_000 + i,
                cur_t.timestamp()) for i in range(38)],
        Entry("Pictures/2025-日常/IMG_8888.jpg", 2_500_000, prev_t.timestamp()),
        Entry("Movies/剪映导出-0920.mp4", 1_200_000_000, prev_t.timestamp()),
        Entry("Documents/2026-09 报销/发票-0901.pdf", 231_144, prev_t.timestamp()),
        Entry("Documents/2026-09 报销/发票-0912.pdf", 231_144, cur_t.timestamp()),
        Entry("Documents/2026-09 报销/行程单.pdf", 88_212, cur_t.timestamp()),
        Entry("Documents/工作/季度汇报.pptx", 18_400_000, prev_t.timestamp()),
        Entry(".ssh/authorized_keys", 612, cur_t.timestamp()),
        Entry(".gitconfig", 220, prev_t.timestamp()),
    ]
    prev = old_photos() + [
        Entry("Pictures/2025-日常/IMG_8888.jpg", 2_500_000, prev_t.timestamp()),
        Entry("Movies/剪映导出-0920.mp4", 1_200_000_000, prev_t.timestamp()),
        Entry("Documents/2026-09 报销/发票-0901.pdf", 231_144, prev_t.timestamp()),
        Entry("Documents/2026-09 报销/发票-0912.pdf", 180_000, prev_t.timestamp()),
        Entry("Documents/工作/季度汇报.pptx", 18_400_000, prev_t.timestamp()),
        Entry(".ssh/authorized_keys", 590, prev_t.timestamp()),
        Entry(".gitconfig", 220, prev_t.timestamp()),
        Entry("Documents/已删除草稿.txt", 4_000, prev_t.timestamp()),
    ]

    config_cur = [
        Entry("Keychains/login.keychain-db", 480_000, cur_t.timestamp()),
        Entry("Preferences/com.apple.finder.plist", 24_000, prev_t.timestamp()),
        Entry(".gnupg/pubring.kbx", 61_000, prev_t.timestamp()),
    ]
    config_prev = [
        Entry("Keychains/login.keychain-db", 470_000, prev_t.timestamp()),
        Entry("Preferences/com.apple.finder.plist", 24_000, prev_t.timestamp()),
        Entry(".gnupg/pubring.kbx", 61_000, prev_t.timestamp()),
    ]
    system_cur = [
        Entry("brew-list.txt", 22_000, cur_t.timestamp()),
        Entry("system-meta.json", 8_000, cur_t.timestamp()),
        Entry("disk-partitions.txt", 2_100, cur_t.timestamp()),
        Entry("network-setup.txt", 1_400, cur_t.timestamp()),
        Entry("launchd-user.plist", 3_200, cur_t.timestamp()),
        Entry("defaults-export.txt", 12_000, cur_t.timestamp()),
    ]

    history = [(cur_t - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(46)]
    return {
        "format": RUN_FORMAT,
        "engine": "borg",
        "device": "MacBook-Pro-macOS15",
        "os": "macOS 15",
        "time": cur_t.isoformat(),
        "label": "evening",
        "snapshot_id": "snap_9f3a2c",
        "parent_id": "snap_71b0ee",
        "parent_time": prev_t.isoformat(),
        "history": history,
        "classes": {
            "files": {"entries": [e.__dict__ for e in cur],
                      "prev_entries": [e.__dict__ for e in prev]},
            "config": {"entries": [e.__dict__ for e in config_cur],
                       "prev_entries": [e.__dict__ for e in config_prev]},
            "system": {"entries": [e.__dict__ for e in system_cur],
                       "prev_entries": [e.__dict__ for e in system_cur if e.path != "defaults-export.txt"]},
        },
    }


def main(argv: list[str] | None = None) -> None:
    # Windows 控制台默认 cp1252，中文输出会 UnicodeEncodeError（CI 实测教训）
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"bg_semantic {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_demo = sub.add_parser("demo", help="零依赖演示：合成两代快照并渲染")
    p_demo.add_argument("--out", default="demo_output")
    p_demo.add_argument("--privacy", choices=["standard", "strict"], default="standard")
    p_demo.set_defaults(func=cmd_demo)

    p_gen = sub.add_parser("generate", help="从 run JSON 渲染快照可读目录")
    p_gen.add_argument("--run", required=True)
    p_gen.add_argument("--out", default="timeline")
    p_gen.add_argument("--privacy", choices=["standard", "strict"], default="standard")
    p_gen.add_argument("--label", help="覆盖 run 中的语义标签")
    p_gen.add_argument("--exclusions", help="本代 exclusions.json 路径（覆盖报告数据源）")
    p_gen.add_argument("--prev-exclusions", help="上一代 exclusions.json 路径（变更检测）")
    p_gen.set_defaults(func=cmd_generate)

    p_conv = sub.add_parser("convert", help="把 borg/restic 导出清单转换为 run JSON")
    p_conv.add_argument("--engine", choices=["restic", "borg", "generic"], required=True)
    p_conv.add_argument("--class", action="append", required=True, dest="class_spec",
                        metavar="类别=路径",
                        help="如 files=ls.jsonl（restic ls --json / borg list --json-lines 的输出）")
    p_conv.add_argument("--prev", action="append", default=[], metavar="类别=路径",
                        help="上一代同类清单（可选，用于 diff）")
    p_conv.add_argument("--meta", help="restic snapshots --json 或 borg info --json 的输出")
    p_conv.add_argument("--snap-id", help="restic 快照 ID（--meta 时选用）")
    p_conv.add_argument("--strip", type=int, default=0, help="剥离路径前缀段数（如 /Users/name/ 为 2）")
    p_conv.add_argument("--auto-strip", action="store_true",
                        help="自动剥离公共路径前缀（推荐：borg/restic 绝对路径无需数段数）")
    p_conv.add_argument("--device", help="设备标识（缺省由 --meta 或 derive 提供）")
    p_conv.add_argument("--time", help="快照时间（ISO 8601；建议本地时间）")
    p_conv.add_argument("--parent-time", help="上一代快照时间（ISO 8601，可选）")
    p_conv.add_argument("--label")
    p_conv.add_argument("--out", default="run.json")
    p_conv.set_defaults(func=cmd_convert)

    p_man = sub.add_parser("manifest", help="输出明文全量清单 JSON（供 age 密封为 manifest.json.enc）")
    p_man.add_argument("--run", required=True)
    p_man.set_defaults(func=cmd_manifest)

    p_pf = sub.add_parser("preflight", help="备份前预检：占位文件 / .git 排除 / 磁盘 / 引擎 / 凭据链")
    p_pf.add_argument("--include", action="append", help="备份 include 路径（可多次）")
    p_pf.add_argument("--excludes", nargs="*", default=[], help="排除模式列表")
    p_pf.add_argument("--check-disk", action="append", help="检查剩余空间的路径（可多次）")
    p_pf.add_argument("--min-free-gb", type=int, default=5)
    p_pf.add_argument("--engine", choices=["borg", "restic"], help="引擎版本检查（不传则跳过）")
    p_pf.add_argument("--json", action="store_true", help="机器可读输出")
    p_pf.set_defaults(func=cmd_preflight)

    p_smp = sub.add_parser("sample", help="恢复演练抽样：从密封清单明文跨类别确定性抽样")
    p_smp.add_argument("--manifest", required=True, help="解封后的 manifest.json")
    p_smp.add_argument("--count", type=int, default=5, help="抽样总数（跨类别按占比分配）")
    p_smp.add_argument("--seed", help="抽样种子（默认当天日期，可复现）")
    p_smp.set_defaults(func=cmd_sample)

    args = ap.parse_args(argv)
    try:
        args.func(args)
    except KeyboardInterrupt:
        print("已中断", file=sys.stderr)
        raise SystemExit(130)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as e:
        # 运行期错误兜底：给用户可读信息而非 traceback（编程错误仍完整抛出）
        print(f"错误: {e}", file=sys.stderr)
        print("提示: 检查输入 JSON 格式与文件路径是否正确", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
