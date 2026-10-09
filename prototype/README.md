# prototype —— backguard 语义层原型（research/06 章 L1/L2 可运行验证）

> 对应调研：[../research/06-语义化备份设计.md](../research/06-语义化备份设计.md) §3（双清单）与 §4（STORY.md）。
> 目的：用最低成本验证「看得懂的备份」是否是真需求——在现有 borg/restic 引擎之上，
> 把每次备份导出的清单变成裸文件管理器可读的 `MANIFEST.txt` + `STORY.md` + `restore.md`，
> 并把完整文件清单密封为 `manifest.json.enc`（age 双恢复路径）。

## 文件

- `bg_semantic.py` — 主 CLI：`demo` / `convert` / `generate` / `manifest`（全量清单 JSON 产出）
- `test_bg_semantic.py` — 27 个测试（解析/diff/聚类/隐私/渲染/auto-strip/manifest/E2E）
- `build.sh` — 全量测试 → `dist/bg.pyz`（zipapp 36KB）→ vendor 到 `../v0/semantic/`

## 快速体验（零依赖）

```bash
python3 bg_semantic.py demo --out demo_output
open demo_output/macbook-pro-macos15/timeline/2026/09/28/2100-evening/STORY.md
```

`demo` 合成「日本旅行回来那晚」的两代快照并渲染快照目录四件套
（MANIFEST.txt / STORY.md / restore.md / manifest.json.enc 需先初始化密钥）。

## manifest.json.enc：全量清单密封（research/03 §6）

完整文件名只进这份 age 加密账本；明文层文件永不出现完整文件名（测试锁定）。
双恢复路径（age 规范：passphrase stanza 独占 → 双 X25519 recipient 实现）：

- `identity.txt` 主身份（本机 600）——日常解密：`age -d -i identity.txt -o manifest.json manifest.json.enc`
- `recovery-identity.enc` 救援身份（恢复码 passphrase 包裹）——救援：先 `age -d -o rec-id.txt recovery-identity.enc`（终端提示输恢复码）再 `-i rec-id.txt` 解清单

密钥初始化由 `v0/semantic/init-keys.exp`（expect）完成：恢复码单一事实源、
包裹后立即闭环验证。真实 E2E 已验证双路径（2026-09-29）。

## 从真实 borg/restic 仓库生成

**第 1 步：导出引擎清单**（v0 的 backup.sh 在每次备份后执行）

```bash
# restic（Windows/Linux/macOS 通用；0.14+ 支持 ls --json）
restic -r "$REPO" snapshots --json > /tmp/snaps.json
restic -r "$REPO" ls --json latest > /tmp/ls-files.jsonl
restic -r "$REPO" ls --json latest-config > /tmp/ls-config.jsonl   # 按实际归档名调整

# borg
borg list --json "$REPO"::"$ARCHIVE" > /tmp/info.json
borg list --json-lines "$REPO"::"$ARCHIVE" > /tmp/list-files.jsonl
```

**第 2 步：转换为 run JSON**（统一中间格式，见 `convert` 输出）

```bash
python3 bg_semantic.py convert --engine restic \
  --class files=/tmp/ls-files.jsonl --class config=/tmp/ls-config.jsonl \
  --meta /tmp/snaps.json --strip 2 --label evening --out run.json
# borg 同理：--engine borg --meta /tmp/info.json
```

`--strip N` 剥离路径前缀段数（如备份绝对路径 `/Users/name/...` 时为 2；
Windows 盘符段自动忽略）。上一代清单用 `--prev files=prev.jsonl` 传入以计算 diff。

**第 3 步：渲染快照可读目录**

```bash
python3 bg_semantic.py generate --run run.json --out ./cloud-staging
# 产出 <out>/<device>/timeline/YYYY/MM/DD/HHMM-<label>/{MANIFEST.txt,STORY.md,restore.md}
```

把 `timeline/` 随内容池一起上传云端即可。隐私严格模式：`--privacy strict`
（MANIFEST/STORY 隐去全部目录名，只留统计）。

## 原型已实现 / 未实现

| 06 章设计 | 原型状态 |
|---|---|
| L0 时间轴目录树 `timeline/YYYY/MM/DD/HHMM-标签` | ✅ 写入端已实现 |
| L1 `MANIFEST.txt` 明文摘要（ASCII 卡片、CJK 对齐、千分位、周几） | ✅ |
| L1 `manifest.json.enc` 加密全量清单 | ❌ 未实现（Phase 0 用 age 包一层即可） |
| L2 `STORY.md` 规则模板叙事（聚类→分类→Top3→确定性渲染） | ✅ AI 润色按设计默认关闭 |
| 每快照 `restore.md` | ✅ 占位模板，正式版接仓库根 README 与 rescue 工具 |
| 连续备份天数（对抗「默默停摆」） | ✅ 由 run JSON 的 `history` 日期列表计算 |
| 隐身模式 | ✅ `--privacy strict` |
| 「稀有度」显著性因子 | ⚠️ 简化为 类别权重×字节量，待真实语料校准 |

隐私红线已内置并通过测试锁定：STORY/MANIFEST **永不出现完整文件名**；
凭据类（.ssh/.gnupg/Keychains/kdbx…）目录一律只写数量不写名字。

## 与设计稿的两处偏差（有意为之）

1. **06 §4.2 示例与 §4.3 红线冲突**：§4.2 模板示例里出现了文件名
   （`发票-0912.pdf 等`），§4.3 却规定 STORY 只出现目录名与统计。原型取
   §4.3 严格路线——目录名是「用户自己一眼扫过的路径段」，文件名常含
   人名/账号，泄露面大一个量级。若实测证明目录粒度不够用，再降级。
2. **根级散文件不显示名称**：散文件聚类如果显示「集中在 brew-list.txt/」
   是把文件名冒充目录名，违反同一红线；原型将其合并为无名簇，只报数量。

## 测试

```bash
python3 -m unittest test_bg_semantic -v   # 25 个用例：解析/diff/聚类/隐私/渲染/auto-strip/E2E
./build.sh   # 全量测试 → dist/bg.pyz（zipapp 单文件，36KB）→ vendor 到 ../v0/semantic/
```

## 真实引擎验证记录（2026-09-29）

本机 borg 1.4.5 / restic 0.19.1 合成两代仓库，经 v0 接入层（semantic.sh）全链路验证。
真实数据抓出 4 个 fixture 测不到的 bug（已修复并加回归测试）：

1. **borg 1.4 的 mtime 是 ISO 字符串**（`2026-09-29T00:39:53.337098`）而非 epoch——`_mtime_to_epoch` 兼容两种形态；
2. **restic ≥0.19 `ls --json` 的 `name` 只是 basename**，目录结构必须取 `path` 字段（旧版无 path 时回退 name）；
3. **单文件被两级细化误写成「目录名」**（`docs/b.txt/`）——隐私红线级 bug。修复：解析时收集引擎清单的 dir 条目为 `known_dirs`，簇名细化必须通过目录证据校验，无证据时逐级回退（三级仅在有证据时允许）；
4. **macOS 自带 `/usr/bin/bg`**（job control 工具）与 CLI 裸名撞车——接入层不做 PATH 查找，只用 `$BG` 显式指定或仓库内 vendored 入口。

## v0 集成（已完成，见 ../v0/semantic/）

- `semantic.sh`（borg）/ `semantic.ps1`（restic）：备份成功后自动 导出清单 → convert → generate → timeline 随内容池上传；上一代归档自动定位（diff 的来源）；`--parent-time` 取自上一代归档的真实创建时间；
- backup.sh / backup.ps1 调用点全部**非致命**：语义层任何失败只告警，不影响备份结论；
- run JSON 留档滚动保留 60 份（连续备份天数的数据源）；
- CI（v0/.github/workflows/ci.yml）：`semantic` 三平台矩阵 job（单测+demo+zipapp）+ 三个备份 job 的 timeline 产物断言。

手动跑（不用整个备份流程）：

```bash
borg list --json-lines "$REPO::$ARC" > cur.jsonl    # 当前代
borg list --json-lines "$REPO::$PREV" > prev.jsonl  # 上一代（可选，用于 diff）
python3 bg_semantic.py convert --engine borg --class files=cur.jsonl \
  --prev files=prev.jsonl --device MyMac --time "$(date +%Y-%m-%dT%H:%M:%S)" \
  --auto-strip --out run.json
python3 bg_semantic.py generate --run run.json --out ./timeline
```

## 集成进 v0 的最小改法

backup.sh / backup.ps1 在 borg/restic 成功后追加两步：导出清单 JSON →
`generate` → 与内容池同上传。无需改动现有引擎与仓库格式，云端布局只增不减，
符合 06 §7 的迁移兼容结论。删除本目录不影响 v0 现有任何行为。
